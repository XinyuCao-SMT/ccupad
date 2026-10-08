//
//  DevicesView.swift
//  CCUPad
//
//  设备清单：增删改 + 连接测试。
//  地址支持 ccu-studio 那套写法（10.205.1.101-108, .111），一次把整个机位群建好。
//

import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var manager: CCUManager

    @State private var showAdd = false
    @State private var editing: CCUDevice?

    var body: some View {
        NavigationStack {
            List {
                if manager.devices.isEmpty {
                    Text("还没有设备。点右上角 + 添加 CCU。")
                        .foregroundStyle(Color.secondary)
                } else {
                    ForEach(manager.devices) { device in
                        DeviceRowView(device: device)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = device }
                    }
                    .onDelete { offsets in
                        delete(offsets)
                    }
                }
            }
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddDevicesSheet()
            }
            .sheet(item: $editing) { device in
                EditDeviceSheet(device: device)
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        let targets = offsets.compactMap { index -> UUID? in
            manager.devices.indices.contains(index) ? manager.devices[index].id : nil
        }
        for id in targets {
            manager.remove(id)
        }
    }
}

struct DeviceRowView: View {
    @EnvironmentObject private var manager: CCUManager
    let device: CCUDevice

    private var state: CCUDeviceState { manager.state(device.id) }
    private var map: ParameterMap { manager.map(device.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.status.color)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.label)
                    .font(.headline)
                Text("\(device.endpointText)  ·  \(device.user)")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                Text(bindingText)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                Text(state.status.shortLabel)
                    .font(.caption)
                    .foregroundStyle(state.status.color)

                if state.status.isConnected {
                    Button("断开") { manager.disconnect(device.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("连接") { manager.connect(device) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var bindingText: String {
        var parts: [String] = []
        parts.append(map.gainChannels.isEmpty ? "增益未绑定" : "增益 \(map.gainChannels.count) 路")
        parts.append(map.tallyBound ? "tally 已绑定" : "tally 未绑定")
        if state.itemCount > 0 { parts.append("\(state.itemCount) 项") }
        if let error = state.lastError, !error.isEmpty { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 新增

struct AddDevicesSheet: View {
    @EnvironmentObject private var manager: CCUManager
    @Environment(\.dismiss) private var dismiss

    @State private var spec = "10.205.1.101-108"
    @State private var user = "admin"
    @State private var password = ""
    @State private var port = "80"
    @State private var prefix = "CCU-"
    @State private var base = "100"
    @State private var digits = "2"

    @State private var testResult: String?
    @State private var testing = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("地址") {
                    TextField("IP / 范围 / 列表", text: $spec)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    Text("写法：10.205.1.101 ｜ 10.205.1.101-108 ｜ 逗号混写 10.205.1.101-104, 10.205.1.111")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section("认证") {
                    TextField("用户名", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    Text("密码存进 iOS Keychain，不写进设置文件、不进日志。")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section("机位命名") {
                    TextField("前缀", text: $prefix)
                    TextField("编号基准（末段 − 基准 = 机位号）", text: $base)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("编号位数", text: $digits)
                        .keyboardType(.numberPad)
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    Button(testing ? "测试中…" : "测试连接（只读，不下发任何设置）") {
                        runTest()
                    }
                    .disabled(testing || hosts.isEmpty)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .navigationTitle("添加 CCU")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加 \(hosts.count) 台") { add() }
                        .disabled(hosts.isEmpty)
                }
            }
            .alert("无法添加", isPresented: errorBinding) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private var hosts: [String] {
        DeviceSpecParser.expand(spec)
    }

    private var previewText: String {
        guard let first = hosts.first else { return "还没有解析出地址。" }
        let baseValue = Int(base) ?? 100
        let digitValue = Int(digits) ?? 2
        let names = hosts.prefix(3).map {
            DeviceSpecParser.autoName(host: $0, prefix: prefix, base: baseValue, digits: digitValue)
        }
        var text = "示例：" + names.joined(separator: "、")
        if hosts.count > 3 { text += " …（共 \(hosts.count) 台）" }
        _ = first
        return text
    }

    private func runTest() {
        guard let host = hosts.first else { return }
        testing = true
        testResult = nil
        let suffix = hosts.count > 1 ? "（只测第一台 \(host)）" : ""
        manager.testConnection(host: host,
                               port: Int(port) ?? 80,
                               user: user,
                               password: password) { result in
            testing = false
            testResult = result + suffix
        }
    }

    private func add() {
        let resolved = hosts
        guard !resolved.isEmpty else {
            errorText = "没有解析出任何 IP 地址。"
            return
        }
        if password.isEmpty {
            errorText = "请填密码。密码只存进 Keychain，不会明文落盘。"
            return
        }

        let portNumber = Int(port) ?? 80
        let safePort = (portNumber > 0 && portNumber < 65536) ? portNumber : 80
        let baseValue = Int(base) ?? 100
        let digitValue = Int(digits) ?? 2
        let userName = user.isEmpty ? "admin" : user

        let newDevices = resolved.map { host in
            CCUDevice(name: DeviceSpecParser.autoName(host: host,
                                                     prefix: prefix,
                                                     base: baseValue,
                                                     digits: digitValue),
                      host: host,
                      port: safePort,
                      user: userName)
        }

        manager.add(devices: newDevices, password: password)
        dismiss()
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }
}

// MARK: - 编辑

struct EditDeviceSheet: View {
    @EnvironmentObject private var manager: CCUManager
    @Environment(\.dismiss) private var dismiss

    let device: CCUDevice

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var user: String
    @State private var password = ""

    init(device: CCUDevice) {
        self.device = device
        _name = State(initialValue: device.name)
        _host = State(initialValue: device.host)
        _port = State(initialValue: String(device.port))
        _user = State(initialValue: device.user)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标识") {
                    TextField("机位名", text: $name)
                    TextField("IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                }

                Section("认证") {
                    TextField("用户名", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("新密码（留空表示不修改）", text: $password)
                }

                Section {
                    Button("删除这台设备", role: .destructive) {
                        manager.remove(device.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("编辑设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        var updated = device
        updated.name = name
        updated.host = host
        updated.port = Int(port) ?? 80
        updated.user = user.isEmpty ? "admin" : user
        manager.update(updated, password: password.isEmpty ? nil : password)
        dismiss()
    }
}
