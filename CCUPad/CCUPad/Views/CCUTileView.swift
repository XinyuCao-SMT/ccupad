//
//  CCUTileView.swift
//  CCUPad
//
//  一台 CCU 的格子：tally 灯 + 身份 + 每组增益通道的推子。
//  格子边框就是 tally 颜色 —— 一眼扫过去就知道哪台在播出。
//

import SwiftUI

struct CCUTileView: View {
    @EnvironmentObject private var manager: CCUManager
    let device: CCUDevice

    private var state: CCUDeviceState { manager.state(device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tallyStroke, lineWidth: tallyStrokeWidth)
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            TallyLampView(tally: state.tally)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.label)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            StatusChipView(status: state.status)
        }
    }

    private var subtitle: String {
        var parts: [String] = [device.endpointText]
        if !state.systemName.isEmpty, state.systemName != device.label {
            parts.append(state.systemName)
        }
        if !state.model.isEmpty { parts.append(state.model) }
        if state.itemCount > 0 { parts.append("\(state.itemCount) 项") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if state.gains.isEmpty {
            emptyGains
        } else {
            faders
        }
    }

    private var emptyGains: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未绑定增益通道")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Text("到「参数发现」页把设备上的音频增益项绑成通道；也可以先让 App 按名字挑一遍。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            Button("自动绑定这台设备") {
                manager.autoBind(device.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var faders: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(state.gains) { channel in
                    VerticalFaderView(
                        channel: channel,
                        step: manager.step(for: channel),
                        enabled: channel.writable && state.status.isConnected,
                        live: manager.settings.liveWhileDragging,
                        onPreview: { value in
                            manager.setGain(device: device.id,
                                            channel: channel,
                                            displayValue: value,
                                            commit: false)
                        },
                        onCommit: { value in
                            manager.setGain(device: device.id,
                                            channel: channel,
                                            displayValue: value,
                                            commit: true)
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text(state.gainSummary)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(state.tally.source)
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineLimit(1)

            if !state.gains.isEmpty {
                Button("0 dB") {
                    manager.setDeviceGains(device.id, to: 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - 边框

    private var tallyStroke: Color {
        switch state.tallyLevel {
        case 2: return Theme.program
        case 1: return Theme.preview
        default: return Theme.panelStroke
        }
    }

    private var tallyStrokeWidth: CGFloat {
        state.tallyLevel > 0 ? 2.5 : 1
    }
}
