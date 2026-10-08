//
//  GainOverviewView.swift
//  CCUPad
//
//  全部机位的增益总览条：一条一行，横轴是各自量程的归一化位置。
//  这是「一眼看完所有 CCU」的那张图 —— 播出中的机位整条变红。
//

import SwiftUI

struct GainOverviewView: View {
    @EnvironmentObject private var manager: CCUManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if manager.devices.isEmpty {
                Text("还没有设备。到「设备」页添加 CCU（支持 10.205.1.101-108 这种范围写法）。")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(manager.devices) { device in
                    DeviceGainBar(device: device)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("全部机位增益总览")
                .font(.headline)

            Spacer(minLength: 4)

            Text(summary)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
    }

    private var summary: String {
        var parts = [L10n.f("在线 %lld/%lld", manager.connectedCount, manager.devices.count)]
        if manager.boundTallyCount > 0 {
            parts.append(L10n.f("播出 %lld", manager.programCount))
        } else {
            parts.append("tally 未绑定")
        }
        return parts.joined(separator: " · ")
    }
}

struct DeviceGainBar: View {
    @EnvironmentObject private var manager: CCUManager
    let device: CCUDevice

    private var state: CCUDeviceState { manager.state(device.id) }

    var body: some View {
        HStack(spacing: 10) {
            Text(device.label)
                .font(.caption)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.track)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: max(geo.size.width * CGFloat(state.gainNormalized), 2))
                }
            }
            .frame(height: 14)

            Text(state.gains.isEmpty ? "未绑定" : state.gainSummary)
                .font(.caption2)
                .frame(width: 132, alignment: .trailing)
                .foregroundStyle(state.gains.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
    }

    private var barColor: Color {
        state.tallyLevel > 0 ? state.tally.color.opacity(0.9) : Theme.gainFill
    }
}
