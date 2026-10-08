//
//  DashboardView.swift
//  CCUPad
//
//  主控台：顶上一排批量操作，中间总览条，下面是每台 CCU 一个格子。
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var manager: CCUManager

    @State private var showBulkConfirm = false
    @State private var bulkText = ""
    @State private var bulkAction: (() -> Void)? = nil
    @State private var showUnlock = false

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controlBar
                    GainOverviewView()
                    deviceGrid
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("主控台")
            .navigationBarTitleDisplayMode(.inline)
            .alert("确认批量下发", isPresented: $showBulkConfirm) {
                Button("取消", role: .cancel) {
                    bulkAction = nil
                }
                Button("下发") {
                    bulkAction?()
                    bulkAction = nil
                }
            } message: {
                Text(bulkText)
            }
            .sheet(isPresented: $showUnlock) {
                AdminUnlockSheet()
            }
        }
    }

    // MARK: - 批量操作

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                actionButton("连接全部", systemImage: "link") {
                    manager.connectAll()
                }

                actionButton("全部断开", systemImage: "link.badge.plus") {
                    manager.disconnectAll()
                }

                dryRunButton

                actionButton("全部 +\(stepLabel)", systemImage: "plus") {
                    bulk(L10n.f("把所有机位已绑定的增益通道提高 %@ dB？", stepLabel)) {
                        manager.adjustAllGains(by: manager.settings.gainStep)
                    }
                }

                actionButton("全部 −\(stepLabel)", systemImage: "minus") {
                    bulk(L10n.f("把所有机位已绑定的增益通道降低 %@ dB？", stepLabel)) {
                        manager.adjustAllGains(by: -manager.settings.gainStep)
                    }
                }

                actionButton("全部 0 dB", systemImage: "arrow.counterclockwise") {
                    bulk(L10n.t("把所有机位已绑定的增益通道设为 0 dB？")) {
                        manager.setAllGains(to: 0)
                    }
                }

                actionButton("撤销上次下发", systemImage: "arrow.uturn.backward") {
                    manager.undoLastChange()
                }

                // 锁定「其他项目」时的入口/出口：现场操作员只推增益，配置要密码才进得去
                if manager.settings.lockAdmin {
                    if manager.adminUnlocked {
                        actionButton("收起其他项目", systemImage: "lock.open.fill") {
                            manager.lockAdminNow()
                        }
                    } else {
                        actionButton("解锁其他项目", systemImage: "lock.fill") {
                            showUnlock = true
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func actionButton(_ title: LocalizedStringKey,
                              systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: 9).stroke(Theme.panelStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var dryRunButton: some View {
        Button {
            manager.settings.dryRun.toggle()
            manager.saveSettings()
        } label: {
            Label(manager.settings.dryRun ? "试运行：开" : "试运行：关",
                  systemImage: manager.settings.dryRun ? "lock.shield" : "lock.open")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(manager.settings.dryRun ? Theme.warning.opacity(0.20) : Theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(manager.settings.dryRun ? Theme.warning.opacity(0.6) : Theme.panelStroke,
                                lineWidth: 1)
                )
                .foregroundStyle(manager.settings.dryRun ? Theme.warning : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var stepLabel: String {
        let step = manager.settings.gainStep
        return step == step.rounded() ? String(Int(step)) : String(format: "%.1f", step)
    }

    private func bulk(_ text: String, action: @escaping () -> Void) {
        if manager.settings.confirmBulkWrite {
            bulkText = text
            bulkAction = action
            showBulkConfirm = true
        } else {
            action()
        }
    }

    // MARK: - 设备格子

    @ViewBuilder
    private var deviceGrid: some View {
        if manager.devices.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(manager.devices) { device in
                    CCUTileView(device: device)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("先添加 CCU")
                .font(.headline)
            Text("到「设备」页填 IP（支持 10.205.1.101-108 与逗号混写）、用户名和密码，再回来点「连接全部」。")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Text("连上之后，音频增益与 tally 需要到「参数发现」页绑定到具体参数。索尼没有公开 CCU 的完整参数名表，所以这台 App 不猜名字 —— 它把候选挑出来，由你在真机上确认。")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
