//
//  CCUSession.swift
//  CCUPad
//
//  一台 CCU 的控制会话。整条链路与 ccu-studio 的真机结论一一对应：
//
//    1. GET /           → 取 Digest 挑战（realm=normal / qop=auth）
//    2. GET /linear     → WebSocket 升级，带 Origin 与算好的 Authorization
//    3. Subscribe ×4    → Ch.Notify.Update / VirtualScreen / Service / KeepAlive
//    4. Ch.SetValue 8603=7 → 设备把约 3300 个参数整块推回来
//    5. Ch.SetValue id=…   → 写值；设备会把它回推，以此确认写入生效
//
//  线程约定：内部状态只在 `queue`（串行）上访问；
//  对外回调统一 hop 到主线程，界面直接改 @Published 就行。
//

import Foundation

final class CCUSession: CCUConnection {

    let device: CCUDevice
    private let password: String
    private let ws: WebSocketClient
    private let queue = DispatchQueue(label: "ccupad.session")

    private(set) var items: [String: CCUItem] = [:]
    private(set) var status: CCUStatus = .idle
    private(set) var connectedAt: Date? = nil

    /// 界面回调（都在主线程）。
    var onItemsChanged: (() -> Void)? = nil
    var onStatusChanged: ((CCUStatus) -> Void)? = nil
    var onLog: ((String) -> Void)? = nil

    private struct VerifyTicket {
        var expected: MPValue
        var deadline: Date
        var attempts: Int
    }

    private var pendingWrites: [String: MPValue] = [:]
    private var writeOrder: [String] = []
    private var verify: [String: VerifyTicket] = [:]
    private var failedWrites: [String: String] = [:]

    private var lastItemChange = Date()
    private var tickTimer: DispatchSourceTimer? = nil
    private var settled = false
    private var stopped = false

    /// 用来读出设备身份的固定项（只读）。
    static let identityItems = [
        "ItemAttributeSystemName",
        "ItemSerialNumberName",
        "ItemSerialNumberNumber",
        "ItemVersionOS",
        "ItemNetworkIpAddress",
    ]

    init(device: CCUDevice, password: String) {
        self.device = device
        self.password = password
        self.ws = WebSocketClient(host: device.host,
                                  port: UInt16(clamping: device.port),
                                  path: "/linear")
        wireSocket()
    }

    // MARK: - 对外查询（线程安全：内部 queue.sync）

    func itemList() -> [CCUItem] {
        queue.sync { Array(items.values) }
    }

    func itemCount() -> Int {
        queue.sync { items.count }
    }

    func item(named name: String) -> CCUItem? {
        queue.sync { items[name] }
    }

    func snapshot(for names: [String]) -> [String: CCUItem] {
        queue.sync {
            var out: [String: CCUItem] = [:]
            for name in names {
                if let item = items[name] { out[name] = item }
            }
            return out
        }
    }

    func pendingItemNames() -> Set<String> {
        queue.sync { Set(verify.keys) }
    }

    func failedItemNames() -> [String: String] {
        queue.sync { failedWrites }
    }

    // MARK: - 连接

    func connect() {
        queue.async {
            guard !self.stopped else { return }
            self.emitStatus(.connecting)
            self.log("开始连接 \(self.device.endpointText)")
            self.fetchChallenge()
        }
    }

    private func fetchChallenge() {
        HTTPClient.get(host: device.host,
                       port: UInt16(clamping: device.port),
                       path: "/",
                       timeout: 8) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    self.fail("取 Digest 挑战失败：\(error)")
                case .success(let response):
                    guard let header = response.headers["www-authenticate"],
                          let challenge = DigestChallenge.parse(header) else {
                        self.fail("\(self.device.host) 有 HTTP 响应（\(response.status)）但不是 CCU 的 Digest 挑战 —— 确认这是 CCU 的网页地址")
                        return
                    }
                    let authorization = challenge.authorization(method: "GET",
                                                               uri: self.ws.path,
                                                               user: self.device.user,
                                                               password: self.password)
                    self.log("已取得 Digest 挑战（realm=\(challenge.realm)），发起控制通道升级")
                    self.ws.connect(authorization: authorization,
                                    origin: "http://\(self.device.host)")
                }
            }
        }
    }

    private func wireSocket() {
        ws.onStateChange = { [weak self] state in
            guard let self = self else { return }
            self.queue.async {
                switch state {
                case .open:
                    self.log("控制通道已打开")
                    self.subscribe()
                case .closed:
                    if self.status.isConnected {
                        self.emitStatus(.closed)
                    }
                    self.stopTicker()
                default:
                    break
                }
            }
        }

        ws.onMessage = { [weak self] message in
            guard let self = self else { return }
            self.queue.async { self.handle(message) }
        }

        ws.onError = { [weak self] text in
            guard let self = self else { return }
            self.queue.async { self.log("⚠️ \(text)") }
        }

        ws.onClose = { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                if self.status.isConnected {
                    self.emitStatus(.closed)
                }
                self.stopTicker()
            }
        }
    }

    private func subscribe() {
        for channel in ["Ch.Notify.Update", "Ch.Notify.VirtualScreen", "Ch.Notify.Service", "Ch.Notify.KeepAlive"] {
            ws.send(.subscribe(channel: channel))
        }
        // 8603 = ItemWebAllItemRequest：官方网页每次打开页面都这么把全部参数要一遍
        ws.send(.requestAllItems())

        settled = false
        lastItemChange = Date()
        emitStatus(.loading)
        startTicker()
    }

    // MARK: - 收报文

    private func handle(_ message: MPValue) {
        guard let frame = message.arrayValue, frame.count >= 3 else { return }
        guard frame[1].stringValue == "Ch.Notify.Update" else { return }
        guard let payload = frame[2].mapValue else { return }

        var changed = false

        for (name, raw) in payload {
            guard let info = raw.mapValue else { continue }

            let item = CCUItem(name: name,
                               numericId: info["id"]?.integer ?? 0,
                               itemType: info["item_type"]?.displayText ?? "",
                               minValue: info["min"]?.number,
                               maxValue: info["max"]?.number,
                               value: info["value"] ?? .null,
                               enumValues: info["enum"]?.arrayValue)

            if items[name] != item { changed = true }
            items[name] = item

            // 设备把值回推了 = 写入被接受
            if let ticket = verify[name], ticket.expected.matches(item.value) {
                verify.removeValue(forKey: name)
                failedWrites.removeValue(forKey: name)
                changed = true
            }
        }

        if changed {
            lastItemChange = Date()
            DispatchQueue.main.async { self.onItemsChanged?() }
        }
    }

    // MARK: - 时钟：读全 → 下发 → 校验

    private func startTicker() {
        stopTicker()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
    }

    private func stopTicker() {
        tickTimer?.cancel()
        tickTimer = nil
    }

    private func tick() {
        guard !stopped else { return }

        // 1) 参数表不再增长 → 认为读全了
        if !settled, !items.isEmpty, Date().timeIntervalSince(lastItemChange) > 1.5 {
            settled = true
            emitStatus(.ready)
            log("已读取 \(items.count) 个参数")
        }

        // 2) 下发队列
        pumpWrites()

        // 3) 超时重试
        checkVerifyTimeouts()
    }

    private func pumpWrites() {
        guard !writeOrder.isEmpty else { return }
        let batch = Array(writeOrder.prefix(4))
        writeOrder.removeFirst(batch.count)

        for (index, name) in batch.enumerated() {
            guard let value = pendingWrites.removeValue(forKey: name) else { continue }
            // 同一批里隔 60 ms 发一条：设备端偶发丢包，太快容易一起丢
            queue.asyncAfter(deadline: .now() + Double(index) * 0.06) { [weak self] in
                self?.performWrite(name: name, value: value)
            }
        }
    }

    private func performWrite(name: String, value: MPValue) {
        guard !stopped else { return }
        guard let item = items[name] else {
            markFailed(name, "设备上没有参数 \(name)")
            return
        }
        if let reason = item.writeBlockReason {
            markFailed(name, "参数 \(name) 不可写：\(reason)")
            return
        }
        if item.value.matches(value) {
            // 值已经一样，不必发；清掉进行中的标记
            verify.removeValue(forKey: name)
            failedWrites.removeValue(forKey: name)
            DispatchQueue.main.async { self.onItemsChanged?() }
            return
        }

        ws.send(.setValue(id: item.numericId, value: value))
        verify[name] = VerifyTicket(expected: value, deadline: Date().addingTimeInterval(3), attempts: 1)
        DispatchQueue.main.async { self.onItemsChanged?() }
    }

    private func checkVerifyTimeouts() {
        guard !verify.isEmpty else { return }
        let now = Date()

        for (name, ticket) in verify {
            guard ticket.deadline < now else { continue }
            if ticket.attempts < 2, let item = items[name] {
                ws.send(.setValue(id: item.numericId, value: ticket.expected))
                verify[name] = VerifyTicket(expected: ticket.expected,
                                            deadline: now.addingTimeInterval(3),
                                            attempts: ticket.attempts + 1)
                log("重试写入 \(name)（第 \(ticket.attempts + 1) 次）")
            } else {
                markFailed(name, "写入 \(name) 未被设备确认 —— 值可能被设备拒绝")
            }
        }
    }

    private func markFailed(_ name: String, _ reason: String) {
        verify.removeValue(forKey: name)
        failedWrites[name] = reason
        log("⚠️ \(reason)")
        DispatchQueue.main.async { self.onItemsChanged?() }
    }

    // MARK: - 写值

    /// 入队一个写入。同名后写覆盖先写；真正的发送由 tick 节流控制。
    func setValue(itemName: String, value: MPValue) {
        queue.async {
            guard !self.stopped else { return }
            guard self.status.isConnected else {
                self.markFailed(itemName, "未连接，未下发 \(itemName)")
                return
            }
            self.pendingWrites[itemName] = value
            if !self.writeOrder.contains(itemName) {
                self.writeOrder.append(itemName)
            }
            self.failedWrites.removeValue(forKey: itemName)
            self.verify[itemName] = VerifyTicket(expected: value,
                                                 deadline: Date().addingTimeInterval(3),
                                                 attempts: 0)
            DispatchQueue.main.async { self.onItemsChanged?() }
        }
    }

    // MARK: - 收尾

    func stop() {
        queue.async {
            self.stopped = true
            self.stopTicker()
            self.ws.close()
            self.emitStatus(.closed)
        }
    }

    func isStopped() -> Bool {
        queue.sync { stopped }
    }

    // MARK: - 内部工具

    private func emitStatus(_ newStatus: CCUStatus) {
        status = newStatus
        if newStatus.isConnected {
            if connectedAt == nil { connectedAt = Date() }
        } else {
            connectedAt = nil
        }
        DispatchQueue.main.async { self.onStatusChanged?(newStatus) }
    }

    private func log(_ text: String) {
        DispatchQueue.main.async { self.onLog?(text) }
    }

    private func fail(_ text: String) {
        emitStatus(.failed(text))
        log("❌ \(text)")
        ws.close()
        stopTicker()
    }
}
