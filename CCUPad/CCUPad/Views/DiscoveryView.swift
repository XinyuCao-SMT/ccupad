//
//  DiscoveryView.swift
//  CCUPad
//
//  参数发现 —— 这一页是整台 App 能与真机对接的关键。
//
//  为什么必须有它：
//    一台 HDCU 有约 3300 个参数，索尼没有公开完整参数名表，
//    「音频增益」和「tally」到底叫什么只能在真机上确认。
//    这一页把全部参数列出来（可按名字搜、按归类筛、还能导出），
//    你在这里把它们绑成增益通道 / tally 来源，映射会记住。
//

import SwiftUI
import Combine

struct DiscoveryView: View {
    @EnvironmentObject private var manager: CCUManager

    @State private var selectedDevice: UUID? = nil
    @State private var search = ""
    @State private var roleFilter: ItemRole? = nil
    @State private var writableOnly = false
    @State private var liveRefresh = true
    @State private var tick = Date()

    @State private var bindingItem: CCUItem? = nil
    @State private var gainTitle = ""
    @State private var divisorText = "1"
    @State private var unitText = "dB"

    @State private var message: String? = nil

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider().overlay(Color.white.opacity(0.08))
                listArea
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("参数发现")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(timer) { _ in
                if liveRefresh { tick = Date() }
            }
            .sheet(item: $bindingItem) { item in
                bindingSheet(item)
            }
            .alert("提示", isPresented: messageBinding) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - 顶部控制区

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            devicePicker
            searchField
            filterRow
            actionRow
        }
        .padding(14)
    }

    private var devicePicker: some View {
        Picker("设备", selection: deviceBinding) {
            Text("请选择设备").tag(UUID?.none)
            ForEach(manager.devices) { device in
                Text("\(device.label)  \(device.endpointText)").tag(Optional(device.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)

            TextField("按参数名搜索，例如 audio / gain / tally", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)

            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", active: roleFilter == nil) { roleFilter = nil }
                chip("增益候选", active: roleFilter == .gain) { roleFilter = .gain }
                chip("Tally 候选", active: roleFilter == .tally) { roleFilter = .tally }
                chip("音频相关", active: roleFilter == .audio) { roleFilter = .audio }
                chip("只显示可写", active: writableOnly) { writableOnly.toggle() }
                chip(liveRefresh ? "实时刷新：开" : "实时刷新：关", active: liveRefresh) { liveRefresh.toggle() }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Theme.accent.opacity(0.25) : Theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Theme.accent.opacity(0.7) : Theme.panelStroke, lineWidth: 1)
                )
                .foregroundStyle(active ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("自动绑定这台设备") {
                if let id = activeDevice {
                    manager.autoBind(id)
                    message = "已按参数名挑了一遍候选。请检查列表里的绑定是否符合预期 —— 自动识别只是起点，tally 一定要在真机上核对。"
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("导出参数清单") {
                exportInventory()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 0)

            Text(countText)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var listArea: some View {
        if manager.devices.isEmpty {
            placeholder("还没有设备。先到「设备」页添加 CCU，回主控台连接后再来这里绑定参数。")
        } else if rows.isEmpty {
            placeholder(emptyListHint)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { item in
                        row(for: item)
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for item: CCUItem) -> some View {
        let map = activeDevice.map { manager.map($0) } ?? ParameterMap()
        let boundGain = map.hasGain(item.name)
        let boundTally = map.hasTally(item.name)
        let role = ItemClassifier.role(of: item.name)

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("id \(item.numericId)")
                    Text(item.itemType)
                    if !item.rangeText.isEmpty { Text(item.rangeText) }
                    if item.isEnumerated { Text("枚举 \(item.enumValues?.count ?? 0) 档") }
                    if item.isReadOnly { Text("只读") }
                    if !item.isReadOnly && !item.isWritable { Text("不可写（无量程/档位）").foregroundStyle(Theme.warning) }
                    if boundGain { Text("已绑增益").foregroundStyle(Theme.gainFill) }
                    if boundTally { Text("已绑 tally").foregroundStyle(Theme.preview) }
                }
                .font(.caption2)
                .foregroundStyle(Color.secondary)

                // 现场是按 OSD 页面认参数的，这里把参数名映射回 OSD 的栏目名
                if let hint = ItemClassifier.hint(for: item.name) {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(Theme.accent.opacity(0.9))
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.displayValue)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                Text(role.label)
                    .font(.caption2)
                    .foregroundStyle(role == .other ? Color.secondary : Theme.accent)
            }

            Menu {
                Button("设为增益通道…") { beginBindGain(item) }
                Button("设为 Tally PGM") { bindTally(item, .program) }
                Button("设为 Tally PVW") { bindTally(item, .preview) }
                if boundGain || boundTally {
                    Divider()
                    if boundGain {
                        Button("解除增益绑定", role: .destructive) { unbindGain(item) }
                    }
                    if boundTally {
                        Button("解除 tally 绑定", role: .destructive) { unbindTally(item) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 绑定动作

    private func beginBindGain(_ item: CCUItem) {
        gainTitle = item.shortName
        divisorText = "1"
        unitText = "dB"
        bindingItem = item
    }

    private func bindTally(_ item: CCUItem, _ role: CCUManager.TallyRole) {
        guard let id = activeDevice else { return }
        manager.bindTally(device: id, itemName: item.name, role: role)
        message = "已把 \(item.name) 绑为 tally \(role.label)。若这台设备用位图表示 tally，就把 PGM 与 PVW 绑同一个参数，再到「设置」里调阈值。"
    }

    private func unbindGain(_ item: CCUItem) {
        guard let id = activeDevice else { return }
        manager.unbindGain(device: id, itemName: item.name)
    }

    private func unbindTally(_ item: CCUItem) {
        guard let id = activeDevice else { return }
        if manager.map(id).tallyPgmItem == item.name {
            manager.unbindTally(device: id, role: .program)
        }
        if manager.map(id).tallyPvwItem == item.name {
            manager.unbindTally(device: id, role: .preview)
        }
    }

    private func exportInventory() {
        guard let id = activeDevice else { return }
        if let name = manager.exportInventory(id) {
            message = "已导出 \(name)。在「文件」App → 本应用 里能找到它，可以直接发回给开发核对参数名。"
        } else {
            message = "没有可导出的参数。先在主控台连接这台设备，等状态变成「已连接」。"
        }
    }

    // MARK: - 绑定表单

    private func bindingSheet(_ item: CCUItem) -> some View {
        NavigationStack {
            Form {
                Section("设备参数") {
                    infoRow("参数名", item.name)
                    infoRow("参数 ID", String(item.numericId))
                    infoRow("类型", item.itemType.isEmpty ? "—" : item.itemType)
                    infoRow("当前值", item.displayValue)
                    infoRow("范围", item.rangeText.isEmpty ? "—" : item.rangeText)
                }

                Section("通道设置") {
                    TextField("通道名", text: $gainTitle)
                    TextField("除数", text: $divisorText)
                        .keyboardType(.decimalPad)
                    TextField("单位", text: $unitText)
                }

                if item.isEnumerated {
                    Section("这项是枚举型") {
                        Text("设备对这项只接受固定档位 —— 而且 min/max 报的是索引范围，不能当量程用。推子、± 按钮与批量操作都会吸附到最近的合法档位。")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        Text("档位：\(item.enumSummary)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }

                Section("除数怎么定") {
                    Text("设备的音频增益常常不是「dB」，而是某个内部步进。若以 0.1 dB 为单位，原始值 60 表示 6.0 dB —— 这时除数填 10。")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    Text("拿不准就先留 1，绑定后在主控台看数字是否合理，再回来改（改除数不会写设备）。")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle("绑定增益通道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { bindingItem = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("绑定") {
                        if let id = activeDevice {
                            let divisor = Double(divisorText) ?? 1
                            manager.bindGain(device: id,
                                             item: item,
                                             title: gainTitle,
                                             divisor: divisor <= 0 ? 1 : divisor,
                                             unit: unitText)
                        }
                        bindingItem = nil
                    }
                }
            }
        }
    }

    // MARK: - 派生数据

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private var activeDevice: UUID? {
        if let selected = selectedDevice,
           manager.devices.contains(where: { $0.id == selected }) {
            return selected
        }
        return manager.devices.first?.id
    }

    private var deviceBinding: Binding<UUID?> {
        Binding(
            get: { activeDevice },
            set: { selectedDevice = $0 }
        )
    }

    private var rows: [CCUItem] {
        _ = tick
        guard let id = activeDevice else { return [] }
        return manager.discoveryItems(device: id,
                                      search: search,
                                      role: roleFilter,
                                      writableOnly: writableOnly,
                                      limit: manager.settings.discoveryRowLimit)
    }

    private var countText: String {
        _ = tick
        guard let id = activeDevice else { return "" }
        let matched = manager.discoveryMatchCount(device: id,
                                                 search: search,
                                                 role: roleFilter,
                                                 writableOnly: writableOnly)
        let total = manager.state(id).itemCount
        if matched > manager.settings.discoveryRowLimit {
            return "命中 \(matched) 项 · 共 \(total) 项 · 只显示前 \(manager.settings.discoveryRowLimit) 项"
        }
        return "命中 \(matched) 项 · 共 \(total) 项"
    }

    private var emptyListHint: String {
        guard let id = activeDevice else { return "请选择一台设备。" }
        if manager.state(id).itemCount == 0 {
            return "这台设备还没有读到参数。回主控台点「连接全部」，等状态变成「已连接」再回来。"
        }
        return "没有匹配的参数。换个关键词，或把筛选切回「全部」。"
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )
    }
}
