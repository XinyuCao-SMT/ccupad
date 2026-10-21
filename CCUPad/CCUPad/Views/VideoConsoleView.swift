//
//  VideoConsoleView.swift
//  CCUPad
//
//  视频主控台：只管彩条相关（开关 + 彩条上那一行文字），不碰音频。
//
//  为什么要单独一页并且上锁：彩条会**改画面**。音频岗在推话筒增益时不该顺手把某台的
//  彩条打开；反过来视频岗也不需要看到推子。所以：
//    · 与音频主控台分开两页；
//    · 打开这一页要**管理密码**（和「设置 → 安全」里那个是同一个密码）；
//    · 解锁状态**不持久化**，重启回到锁定；页内还有一个「锁定视频台」可以立刻收起。
//
//  没有设置管理密码时这一页默认是开的 —— 否则设密码之前就永远进不去。
//

import SwiftUI

struct VideoConsoleView: View {
    @EnvironmentObject private var manager: CCUManager
    @State private var showUnlock = false

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if manager.videoConsoleAvailable {
                    content
                } else {
                    locked
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("视频主控台")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showUnlock) {
                VideoUnlockSheet()
            }
        }
    }

    // MARK: - 已解锁

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlBar
                if manager.devices.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(manager.devices) { device in
                            VideoTileView(device: device)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                action("连接全部", systemImage: "bolt.horizontal") {
                    manager.connectAll()
                }

                action("全部彩条开", systemImage: "rectangle.on.rectangle") {
                    manager.setAllColorBars(on: true)
                }

                action("全部彩条关", systemImage: "rectangle") {
                    manager.setAllColorBars(on: false)
                }

                // 注意：横向 ScrollView 里不要放 Spacer —— 内容宽度不受限，会把按钮压扁
                Button {
                    manager.lockVideoNow()
                } label: {
                    Label("锁定视频台", systemImage: "lock.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(Color.secondary)
                .controlSize(.small)
            }
        }
    }

    private func action(_ title: LocalizedStringKey, systemImage: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("先添加 CCU")
                .font(.subheadline)
            Text("到「设备」页填 IP 和密码，回这里点「连接全部」。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panel()
    }

    // MARK: - 锁定

    private var locked: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.secondary)

            Text("视频主控台需要密码")
                .font(.headline)

            Text("彩条会改画面，所以这一页单独上锁。密码就是「设置 → 安全」里那个管理密码。")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("输入密码解锁") { showUnlock = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 视频主控台的解锁框（和「其他项目」的那个分开，避免一处解锁两处都开）。
struct VideoUnlockSheet: View {
    @EnvironmentObject private var manager: CCUManager
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var errorText: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("管理密码") {
                    SecureField("密码", text: $password)

                    if let errorText = errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(Theme.program)
                    }

                    Text("解锁后才能看到彩条开关。解锁状态不会保留到下次启动。")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle("解锁视频主控台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁") {
                        if manager.unlockVideo(with: password) {
                            dismiss()
                        } else {
                            errorText = L10n.t("密码不对")
                        }
                    }
                }
            }
        }
    }
}

/// 视频主控台里的一台机位：tally 灯 + 编号（带彩条文字）+ 彩条开关。
struct VideoTileView: View {
    @EnvironmentObject private var manager: CCUManager
    let device: CCUDevice

    private var state: CCUDeviceState { manager.state(device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            colorBarSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            TallyLampView(tally: state.tally)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.label)
                        .font(.headline)
                        .lineLimit(1)

                    if !state.barText.isEmpty {
                        Text(state.barText)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                }

                Text(device.endpointText)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            StatusChipView(status: state.status)
        }
    }

    @ViewBuilder
    private var colorBarSection: some View {
        if let on = state.colorBarOn {
            Button {
                manager.toggleColorBar(device: device.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: on ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                    Text(L10n.t(on ? "彩条 开" : "彩条 关"))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(on ? Theme.warning.opacity(0.85) : Color.white.opacity(0.12))
                )
                .foregroundStyle(on ? Color.black : Color.primary)
            }
            .buttonStyle(.plain)
            .disabled(!state.status.isConnected || !state.colorBarWritable)

            if state.colorBarCooldownLeft() > 0 {
                Text("刚切过，等 2 秒让设备生效")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            } else if !state.colorBarWritable {
                Text("这个参数现在不可写")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
            }
        } else {
            Text("未绑定彩条开关")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Text("到「参数发现」页把彩条开关参数绑上，或在那里点「套用实测默认」。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
    }

    private var strokeColor: Color {
        switch state.tallyLevel {
        case 2: return Theme.program
        case 1: return Theme.preview
        default: return Theme.panelStroke
        }
    }

    private var strokeWidth: CGFloat {
        state.tallyLevel > 0 ? 2 : 1
    }
}
