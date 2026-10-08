//
//  CCUManager.swift
//  CCUPad
//
//  多台 CCU 的总控：连接管理、派生状态、增益下发、tally 判定、参数发现与导出。
//
//  刻意**没有**标 @MainActor：会话回调已经在主线程上，直接改 @Published 是安全的，
//  而在 Swift 5 语言模式下让 DispatchQueue.main.asyncAfter 里的闭包去调
//  @MainActor 方法反而会编译不过。所以约定是：
//    所有改动 @Published 的代码路径都必须发生在主线程。
//

import Foundation
import Combine

final class CCUManager: ObservableObject {

    @Published private(set) var devices: [CCUDevice] = []
    @Published private(set) var states: [UUID: CCUDeviceState] = [:]
    @Published private(set) var maps: [UUID: ParameterMap] = [:]
    @Published private(set) var logs: [LogEntry] = []
    @Published var settings = AppSettings()
    @Published private(set) var lastExport: String? = nil

    private var sessions: [UUID: CCUSession] = [:]
    private var passwords: [UUID: String] = [:]
    private var reconnecting: Set<UUID> = []
    private var lastRebuild: [UUID: Date] = [:]

    /// tally 的两种角色。
    enum TallyRole {
        case program
        case preview

        var label: String {
            switch self {
            case .program: return "PGM"
            case .preview: return "PVW"
            }
        }
    }

    init() {
        devices = AppStore.loadDevices()
        maps = AppStore.loadMaps()
        settings = AppStore.loadSettings()
    }

    // MARK: - 查询

    func state(_ id: UUID) -> CCUDeviceState {
        states[id] ?? CCUDeviceState(id: id)
    }

    func map(_ id: UUID) -> ParameterMap {
        maps[id] ?? ParameterMap()
    }

    func device(_ id: UUID) -> CCUDevice? {
        devices.first { $0.id == id }
    }

    func deviceLabel(_ id: UUID) -> String {
        device(id)?.label ?? "未知设备"
    }

    var connectedCount: Int {
        devices.filter { state($0.id).status.isConnected }.count
    }

    var programCount: Int {
        devices.filter { state($0.id).tally.program }.count
    }

    var boundTallyCount: Int {
        devices.filter { map($0.id).tallyBound }.count
    }

    var boundGainCount: Int {
        devices.filter { !map($0.id).gainChannels.isEmpty }.count
    }

    // MARK: - 设备清单

    func add(devices newDevices: [CCUDevice], password: String) {
        guard !newDevices.isEmpty else { return }
        for device in newDevices {
            if !password.isEmpty {
                passwords[device.id] = password
                _ = Keychain.setPassword(password, for: device.id)
            }
            states[device.id] = CCUDeviceState(id: device.id)
        }
        devices.append(contentsOf: newDevices)
        AppStore.saveDevices(devices)
        appendLog("设备", "新增 \(newDevices.count) 台：\(newDevices.map { $0.label }.joined(separator: ", "))")
    }

    func update(_ device: CCUDevice, password: String?) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        AppStore.saveDevices(devices)
        if let password = password, !password.isEmpty {
            passwords[device.id] = password
            _ = Keychain.setPassword(password, for: device.id)
        }
        appendLog(device.label, "已更新设备信息")
        if state(device.id).status.isConnected {
            disconnect(device.id)
            connect(device)
        }
    }

    func remove(_ id: UUID) {
        disconnect(id)
        devices.removeAll { $0.id == id }
        states.removeValue(forKey: id)
        maps.removeValue(forKey: id)
        passwords.removeValue(forKey: id)
        Keychain.deletePassword(for: id)
        AppStore.saveDevices(devices)
        AppStore.saveMaps(maps)
    }

    private func password(for id: UUID) -> String? {
        if let cached = passwords[id] { return cached }
        if let stored = Keychain.password(for: id) {
            passwords[id] = stored
            return stored
        }
        return nil
    }

    // MARK: - 连接

    func connect(_ device: CCUDevice) {
        guard let secret = password(for: device.id) else {
            var state = self.state(device.id)
            state.status = .failed("没有保存密码")
            state.lastError = "没有保存密码"
            states[device.id] = state
            appendLog(device.label, "没有保存密码，无法连接")
            return
        }

        sessions[device.id]?.stop()
        reconnecting.remove(device.id)

        let session = CCUSession(device: device, password: secret)

        session.onLog = { [weak self] text in
            self?.appendLog(device.label, text)
        }
        session.onItemsChanged = { [weak self] in
            self?.rebuild(device.id, force: false)
        }
        session.onStatusChanged = { [weak self] status in
            guard let self = self else { return }
            var state = self.state(device.id)
            state.status = status
            if case .failed(let text) = status { state.lastError = text }
            if status == .closed || status.isFailure { state.updatedAt = Date() }
            self.states[device.id] = state
            self.rebuild(device.id)
            if status == .closed || status.isFailure {
                self.scheduleReconnect(device.id)
            }
        }

        sessions[device.id] = session
        appendLog(device.label, "发起连接 \(device.endpointText)")
        session.connect()
    }

    func disconnect(_ id: UUID) {
        reconnecting.remove(id)
        sessions[id]?.stop()
        sessions.removeValue(forKey: id)
        var state = self.state(id)
        state.status = .closed
        states[id] = state
    }

    func connectAll() {
        for device in devices where device.enabled {
            connect(device)
        }
    }

    func disconnectAll() {
        for device in devices {
            disconnect(device.id)
        }
    }

    private func scheduleReconnect(_ id: UUID) {
        guard settings.autoReconnect else { return }
        guard let device = device(id), device.enabled else { return }
        guard !reconnecting.contains(id) else { return }

        reconnecting.insert(id)
        let delay = max(2, settings.reconnectInterval)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.reconnecting.remove(id)
            guard let current = self.device(id), current.enabled else { return }
            if self.state(id).status.isConnected { return }
            self.connect(current)
        }
    }

    /// 只验证「地址通、Digest 认证过」——不下发任何东西。
    func testConnection(host: String,
                        port: Int,
                        user: String,
                        password: String,
                        completion: @escaping (String) -> Void) {
        let safePort = UInt16(clamping: port)
        HTTPClient.get(host: host, port: safePort, path: "/", timeout: 8) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion("❌ 取 Digest 挑战失败：\(error)")
                case .success(let response):
                    guard let header = response.headers["www-authenticate"],
                          let challenge = DigestChallenge.parse(header) else {
                        completion("❌ 端口 \(safePort) 有 HTTP 响应（状态 \(response.status)）但不是 CCU 的 Digest 挑战")
                        return
                    }
                    let auth = challenge.authorization(method: "GET",
                                                      uri: "/",
                                                      user: user,
                                                      password: password)
                    HTTPClient.get(host: host,
                                   port: safePort,
                                   path: "/",
                                   headers: ["Authorization": auth],
                                   timeout: 8) { second in
                        DispatchQueue.main.async {
                            switch second {
                            case .failure(let error):
                                completion("⚠️ 挑战已取得，但验证请求失败：\(error)")
                            case .success(let verified):
                                if verified.status == 200 {
                                    completion("✅ 认证通过（realm=\(challenge.realm)）")
                                } else if verified.status == 401 {
                                    completion("❌ 用户名或密码不对（HTTP 401）")
                                } else {
                                    completion("⚠️ 认证返回 HTTP \(verified.status)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 派生状态

    /// 从会话里把已绑定的项读出来算成界面状态。
    /// 只读映射里用到的那些参数，不是 3300 项 —— 所以可以放心在数据变化时频繁调用。
    func rebuild(_ id: UUID, force: Bool = true) {
        guard let session = sessions[id] else { return }
        if !force, let last = lastRebuild[id], Date().timeIntervalSince(last) < 0.2 { return }
        lastRebuild[id] = Date()

        let map = maps[id] ?? ParameterMap()
        var wanted: [String] = map.gainChannels.map { $0.itemName }
        if let name = map.tallyPgmItem { wanted.append(name) }
        if let name = map.tallyPvwItem { wanted.append(name) }
        wanted.append(contentsOf: CCUSession.identityItems)

        let snapshot = session.snapshot(for: wanted)
        let pending = session.pendingItemNames()
        let failures = session.failedItemNames()

        var state = states[id] ?? CCUDeviceState(id: id)
        state.itemCount = session.itemCount()
        state.systemName = text(snapshot["ItemAttributeSystemName"])
        state.model = text(snapshot["ItemSerialNumberName"])
        state.serial = text(snapshot["ItemSerialNumberNumber"])
        state.firmware = text(snapshot["ItemVersionOS"])

        state.gains = map.gainChannels.compactMap { binding -> GainChannel? in
            guard let item = snapshot[binding.itemName] else { return nil }
            return GainChannel(itemName: binding.itemName,
                               title: binding.title.isEmpty ? item.shortName : binding.title,
                               rawValue: item.value.number ?? 0,
                               rawMin: item.minValue ?? 0,
                               rawMax: item.maxValue ?? 0,
                               divisor: binding.divisor,
                               unit: binding.unit,
                               writable: item.isWritable,
                               pending: pending.contains(binding.itemName),
                               problem: failures[binding.itemName])
        }

        state.tally = resolveTally(map: map, snapshot: snapshot)
        state.updatedAt = Date()
        states[id] = state
    }

    private func text(_ item: CCUItem?) -> String {
        guard let item = item else { return "" }
        if item.value.isNull { return "" }
        let value = item.displayValue
        return value == "—" ? "" : value
    }

    private func resolveTally(map: ParameterMap, snapshot: [String: CCUItem]) -> TallyState {
        var tally = TallyState()

        func lit(_ name: String?) -> Bool? {
            guard let name = name, let item = snapshot[name] else { return nil }
            if let number = item.value.number {
                let on = number >= map.tallyThreshold
                return map.tallyInverted ? !on : on
            }
            if let flag = item.value.boolean {
                return map.tallyInverted ? !flag : flag
            }
            let text = item.displayValue.trimmingCharacters(in: .whitespaces)
            let on = !(text.isEmpty || text == "0" || text == "—" || text.lowercased() == "false")
            return map.tallyInverted ? !on : on
        }

        var sources: [String] = []
        if let program = lit(map.tallyPgmItem) {
            tally.program = program
            if let name = map.tallyPgmItem { sources.append("PGM←\(name)") }
        }
        if let preview = lit(map.tallyPvwItem) {
            tally.preview = preview
            if let name = map.tallyPvwItem { sources.append("PVW←\(name)") }
        }
        // 同一个参数同时绑了两边时，阈值分不开，按 PGM 优先
        if let name = map.tallyPgmItem, name == map.tallyPvwItem {
            tally.preview = false
        }

        if !sources.isEmpty {
            tally.source = sources.joined(separator: "  ")
        } else if map.tallyBound {
            tally.source = "已绑定但读不到值"
        } else {
            tally.source = "未绑定"
        }
        return tally
    }

    // MARK: - 绑定（核心：参数名由用户在真机上确定）

    func bindGain(device id: UUID, item: CCUItem, title: String, divisor: Double, unit: String) {
        var map = maps[id] ?? ParameterMap()
        let name = title.isEmpty ? item.shortName : title
        let safeDivisor = divisor == 0 ? 1 : divisor

        if let index = map.gainChannels.firstIndex(where: { $0.itemName == item.name }) {
            map.gainChannels[index].title = name
            map.gainChannels[index].divisor = safeDivisor
            map.gainChannels[index].unit = unit
        } else {
            map.gainChannels.append(GainBinding(itemName: item.name,
                                                title: name,
                                                divisor: safeDivisor,
                                                unit: unit))
        }
        maps[id] = map
        saveMaps()
        appendLog(deviceLabel(id), "绑定增益通道 ← \(item.name)（÷\(safeDivisor) \(unit)）")
        rebuild(id)
    }

    func unbindGain(device id: UUID, itemName: String) {
        var map = maps[id] ?? ParameterMap()
        map.gainChannels.removeAll { $0.itemName == itemName }
        maps[id] = map
        saveMaps()
        appendLog(deviceLabel(id), "解除增益通道 \(itemName)")
        rebuild(id)
    }

    func moveGain(device id: UUID, index: Int, offset: Int) {
        var map = maps[id] ?? ParameterMap()
        let target = index + offset
        guard map.gainChannels.indices.contains(index), map.gainChannels.indices.contains(target) else { return }
        map.gainChannels.swapAt(index, target)
        maps[id] = map
        saveMaps()
        rebuild(id)
    }

    func bindTally(device id: UUID, itemName: String, role: TallyRole) {
        var map = maps[id] ?? ParameterMap()
        switch role {
        case .program: map.tallyPgmItem = itemName
        case .preview: map.tallyPvwItem = itemName
        }
        maps[id] = map
        saveMaps()
        appendLog(deviceLabel(id), "绑定 tally \(role.label) ← \(itemName)")
        rebuild(id)
    }

    func unbindTally(device id: UUID, role: TallyRole) {
        var map = maps[id] ?? ParameterMap()
        switch role {
        case .program: map.tallyPgmItem = nil
        case .preview: map.tallyPvwItem = nil
        }
        maps[id] = map
        saveMaps()
        rebuild(id)
    }

    func setTallyOptions(device id: UUID, threshold: Double?, inverted: Bool?) {
        var map = maps[id] ?? ParameterMap()
        if let threshold = threshold { map.tallyThreshold = threshold }
        if let inverted = inverted { map.tallyInverted = inverted }
        maps[id] = map
        saveMaps()
        rebuild(id)
    }

    func autoBind(_ id: UUID) {
        let items = sessions[id]?.itemList() ?? []
        guard !items.isEmpty else {
            appendLog(deviceLabel(id), "还没读到参数，无法自动绑定（先连接并等「读取参数中」结束）")
            return
        }
        let detected = ParameterMap.autoDetect(from: items)
        maps[id] = detected
        saveMaps()
        rebuild(id)
        appendLog(deviceLabel(id),
                  "自动绑定：增益 \(detected.gainChannels.count) 项，tally \(detected.tallyPgmItem ?? "未找到")")
    }

    func clearMap(_ id: UUID) {
        maps[id] = ParameterMap()
        saveMaps()
        rebuild(id)
        appendLog(deviceLabel(id), "已清除该设备的参数映射")
    }

    private func saveMaps() {
        AppStore.saveMaps(maps)
    }

    // MARK: - 增益下发

    /// 设置一条通道的增益。`commit == false` 用于拖动过程中的本地预览。
    func setGain(device id: UUID, channel: GainChannel, displayValue: Double, commit: Bool) {
        guard var state = states[id],
              let index = state.gains.firstIndex(where: { $0.itemName == channel.itemName }) else { return }

        let range = channel.span
        let clamped = min(max(displayValue, range.lowerBound), range.upperBound)
        let divisor = channel.divisor == 0 ? 1 : channel.divisor

        state.gains[index].rawValue = clamped * divisor
        state.gains[index].problem = nil
        state.gains[index].pending = commit && !settings.dryRun
        state.updatedAt = Date()
        states[id] = state

        guard commit else { return }

        if settings.dryRun {
            appendLog(deviceLabel(id), "试运行：\(channel.title) → \(GainChannel.format(clamped, unit: channel.unit))（未下发）")
            if var current = states[id],
               let idx = current.gains.firstIndex(where: { $0.itemName == channel.itemName }) {
                current.gains[idx].pending = false
                states[id] = current
            }
            return
        }

        sessions[id]?.setValue(itemName: channel.itemName, value: CCUItem.target(from: clamped * divisor))
    }

    func nudgeGain(device id: UUID, channel: GainChannel, delta: Double) {
        setGain(device: id, channel: channel, displayValue: channel.value + delta, commit: true)
    }

    func step(for channel: GainChannel) -> Double {
        let span = channel.span.upperBound - channel.span.lowerBound
        if span <= 2 { return 0.1 }
        if span <= 12 { return settings.gainStep }
        if span <= 60 { return 1 }
        return 5
    }

    /// 所有机位一起加 / 减。
    func adjustAllGains(by delta: Double) {
        for device in devices where device.enabled {
            guard let state = states[device.id] else { continue }
            for channel in state.gains where channel.writable {
                setGain(device: device.id, channel: channel, displayValue: channel.value + delta, commit: true)
            }
        }
        appendLog("全部", "所有机位增益 \(delta >= 0 ? "+" : "")\(GainChannel.format(delta, unit: "dB"))")
    }

    /// 所有机位设到同一个值（归零就是这里传 0）。
    func setAllGains(to displayValue: Double) {
        for device in devices where device.enabled {
            guard let state = states[device.id] else { continue }
            for channel in state.gains where channel.writable {
                setGain(device: device.id, channel: channel, displayValue: displayValue, commit: true)
            }
        }
        appendLog("全部", "所有机位增益设为 \(GainChannel.format(displayValue, unit: "dB"))")
    }

    func setDeviceGains(_ id: UUID, to displayValue: Double) {
        guard let state = states[id] else { return }
        for channel in state.gains where channel.writable {
            setGain(device: id, channel: channel, displayValue: displayValue, commit: true)
        }
        appendLog(deviceLabel(id), "全部通道设为 \(GainChannel.format(displayValue, unit: "dB"))")
    }

    /// 某一台设备的全部通道一起加 / 减。
    func adjustGains(_ id: UUID, by delta: Double) {
        guard let state = states[id] else { return }
        for channel in state.gains where channel.writable {
            setGain(device: id, channel: channel, displayValue: channel.value + delta, commit: true)
        }
        appendLog(deviceLabel(id), "全部通道 \(delta >= 0 ? "+" : "")\(GainChannel.format(delta, unit: "dB"))")
    }

    // MARK: - 参数发现

    func discoveryItems(device id: UUID,
                        search: String,
                        role: ItemRole?,
                        writableOnly: Bool,
                        limit: Int) -> [CCUItem] {
        guard let session = sessions[id] else { return [] }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()

        var matched: [CCUItem] = []
        for item in session.itemList() {
            if writableOnly && !item.isWritable { continue }
            if let role = role, ItemClassifier.role(of: item.name) != role { continue }
            if !needle.isEmpty, !item.name.lowercased().contains(needle) { continue }
            matched.append(item)
        }
        matched.sort { $0.name < $1.name }
        if matched.count > limit { return Array(matched.prefix(limit)) }
        return matched
    }

    func discoveryMatchCount(device id: UUID,
                             search: String,
                             role: ItemRole?,
                             writableOnly: Bool) -> Int {
        guard let session = sessions[id] else { return 0 }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var count = 0
        for item in session.itemList() {
            if writableOnly && !item.isWritable { continue }
            if let role = role, ItemClassifier.role(of: item.name) != role { continue }
            if !needle.isEmpty, !item.name.lowercased().contains(needle) { continue }
            count += 1
        }
        return count
    }

    /// 把当前设备读到的全部参数导成 TSV，落到「文件」App 里，方便回传核对。
    func exportInventory(_ id: UUID) -> String? {
        let items = sessions[id]?.itemList() ?? []
        guard !items.isEmpty else { return nil }

        let label = deviceLabel(id)
        var lines: [String] = []
        lines.append("# CCUPad 参数清单")
        lines.append("# 设备\t\(label)\t\(device(id)?.endpointText ?? "")")
        lines.append("# 时间\t\(Date())")
        lines.append("# 共\t\(items.count) 项")
        lines.append("# 列：参数名\t参数ID\t类型\t最小值\t最大值\t当前值\t归类\t可写")

        for item in items.sorted(by: { $0.name < $1.name }) {
            let role = ItemClassifier.role(of: item.name)
            let row = [
                item.name,
                String(item.numericId),
                item.itemType,
                item.minValue.map { String($0) } ?? "",
                item.maxValue.map { String($0) } ?? "",
                item.displayValue,
                role.rawValue,
                item.isWritable ? "是" : "否",
            ]
            lines.append(row.joined(separator: "\t"))
        }

        let stamp = Self.stamp()
        let fileName = "ccupad-\(label)-\(stamp).tsv"
        if let written = AppStore.writeExport(named: fileName, text: lines.joined(separator: "\n")) {
            lastExport = written
            appendLog(label, "已导出参数清单：\(written)")
            return written
        }
        appendLog(label, "导出失败")
        return nil
    }

    func exportMap(_ id: UUID) -> String? {
        let map = maps[id] ?? ParameterMap()
        var lines: [String] = []
        lines.append("# CCUPad 参数映射")
        lines.append("# 设备\t\(deviceLabel(id))\t\(device(id)?.endpointText ?? "")")
        lines.append("# 时间\t\(Date())")
        lines.append("")
        lines.append("[增益通道]")
        lines.append("参数名\t通道名\t除数\t单位")
        for binding in map.gainChannels {
            lines.append([binding.itemName, binding.title, String(binding.divisor), binding.unit].joined(separator: "\t"))
        }
        lines.append("")
        lines.append("[Tally]")
        lines.append("角色\t参数名")
        lines.append("PGM\t\(map.tallyPgmItem ?? "")")
        lines.append("PVW\t\(map.tallyPvwItem ?? "")")
        lines.append("阈值\t\(map.tallyThreshold)")
        lines.append("取反\t\(map.tallyInverted ? "是" : "否")")
        lines.append("备注\t\(map.note)")

        let fileName = "ccupad-map-\(deviceLabel(id))-\(Self.stamp()).tsv"
        if let written = AppStore.writeExport(named: fileName, text: lines.joined(separator: "\n")) {
            lastExport = written
            return written
        }
        return nil
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - 日志

    func appendLog(_ device: String, _ text: String) {
        logs.append(LogEntry(at: Date(), device: device, text: text))
        if logs.count > settings.logLimit {
            logs.removeFirst(logs.count - settings.logLimit)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - 设置

    func saveSettings() {
        AppStore.saveSettings(settings)
    }
}
