//
//  SettingsView.swift
//  CCUPad
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: CCUManager

    var body: some View {
        NavigationStack {
            Form {
                sendSection
                connectionSection
                bindingSection
                snapshotSection
                AdminSecuritySection()
                logSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 下发

    private var sendSection: some View {
        Section("下发") {
            Toggle("试运行（只显示，不下发）", isOn: boolBinding(\.dryRun))

            Toggle("拖动推子时实时下发", isOn: boolBinding(\.liveWhileDragging))

            Toggle("批量操作前二次确认", isOn: boolBinding(\.confirmBulkWrite))

            Picker("推子步进", selection: doubleBinding(\.gainStep)) {
                Text("0.1 dB").tag(0.1)
                Text("0.5 dB").tag(0.5)
                Text("1 dB").tag(1.0)
                Text("2 dB").tag(2.0)
            }

            Text("默认开「试运行」：所有操作都会照常走一遍并写进日志，但一个字节都不会发给设备。确认没问题再关掉。")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var connectionSection: some View {
        Section("连接") {
            Toggle("断线自动重连", isOn: boolBinding(\.autoReconnect))

            Stepper(L10n.f("重连间隔 %lld 秒", Int(manager.settings.reconnectInterval)),
                    value: doubleBinding(\.reconnectInterval),
                    in: 2...60,
                    step: 1)

            Stepper(L10n.f("参数列表最多显示 %lld 行", manager.settings.discoveryRowLimit),
                    value: intBinding(\.discoveryRowLimit),
                    in: 50...2000,
                    step: 50)
        }
    }

    // MARK: - 映射

    private var bindingSection: some View {
        Section("参数映射") {
            if manager.devices.isEmpty {
                Text("还没有设备")
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(manager.devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.label)
                            .font(.subheadline)
                        Text(mapSummary(device.id))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }

            if let exported = manager.lastExport {
                Text("最近导出：\(exported)")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func mapSummary(_ id: UUID) -> String {
        let map = manager.map(id)
        var parts: [String] = []
        parts.append("增益 \(map.gainChannels.count) 路")
        if let pgm = map.tallyPgmItem {
            parts.append("PGM ← \(pgm)")
        } else {
            parts.append(L10n.t("PGM 未绑定"))
        }
        if let pvw = map.tallyPvwItem {
            parts.append("PVW ← \(pvw)")
        }
        if map.tallyBound {
            var thresholdText = L10n.f("阈值 %@", String(map.tallyThreshold))
            if map.tallyInverted { thresholdText += L10n.t("（取反）") }
            parts.append(thresholdText)
        }
        if !map.note.isEmpty { parts.append(map.note) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 增益快照与回滚

    /// 下发是真的写设备，所以每次批量操作前都会自动拍一张快照 —— 这里能退回去。
    private var snapshotSection: some View {
        Section("增益快照与回滚") {
            if manager.snapshots.isEmpty {
                Text("还没有快照。批量下发前会自动拍一张（试运行不拍），也可以在主控台按「拍快照」。")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(manager.snapshots.prefix(8)) { snapshot in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(snapshot.timeText)  \(snapshot.deviceLabel)")
                                .font(.caption)
                            Text("\(snapshot.channelCount) 路 · \(snapshot.reason)")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("回滚") {
                            manager.restoreGainSnapshot(snapshot)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Button("撤销上一次下发") {
                manager.undoLastChange()
            }
            .disabled(manager.snapshots.isEmpty)

            if !manager.snapshots.isEmpty {
                Button("清空全部快照", role: .destructive) {
                    manager.clearSnapshots()
                }
            }
        }
    }

    // MARK: - 日志
    private var logSection: some View {
        Section("日志") {
            Button("清空日志") {
                manager.clearLogs()
            }

            ForEach(manager.logs.suffix(40)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.timeText)  \(entry.device)")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                    Text(entry.text)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - 关于

    /// 版本号从包里读 —— 以前这里硬编码版本字符串，每次发版都得记得改一处，容易漏。
    private var appVersionText: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    private var appBuildText: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }

    private var aboutSection: some View {
        Section("关于") {
            VStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                Text(verbatim: "CCUPad \(appVersionText)")
                    .font(.headline)

                Text(L10n.f("开发者：%@", "SMT-Xinyu Cao"))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)

                Text(L10n.f("构建 %@", appBuildText))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Text("协议：HTTP Digest（MD5 / qop=auth）+ ws://<ip>/linear + MessagePack，与 ccu-studio 在 HDCU-3500 / 3100 上验证过的实现一致。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)

            Text("前提：iPad 与 CCU 在同一局域网、CCU 管理口开放 80 端口；首次连接时系统会弹「本地网络」权限，必须允许，否则数据包会被静默丢弃（表现为一直连不上、还没有报错）。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)

            Text("参数名：索尼没有公开 CCU 的完整参数名表，所以增益与 tally 都必须在「参数发现」页对着真机绑定一次。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)

            Text("安全：关掉「试运行」后，推子会真的写进 CCU。建议先只在一台设备上验证。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - 写穿绑定（改一次存一次，不需要 onChange）

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { manager.settings[keyPath: keyPath] },
            set: { newValue in
                manager.settings[keyPath: keyPath] = newValue
                manager.saveSettings()
            }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        Binding(
            get: { manager.settings[keyPath: keyPath] },
            set: { newValue in
                manager.settings[keyPath: keyPath] = newValue
                manager.saveSettings()
            }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(
            get: { manager.settings[keyPath: keyPath] },
            set: { newValue in
                manager.settings[keyPath: keyPath] = newValue
                manager.saveSettings()
            }
        )
    }
}
