//
//  EnumChannelView.swift
//  CCUPad
//
//  枚举型通道的控件。
//
//  为什么要单独做一个：设备的这类参数**只接受固定档位**（实测：摄像机话筒增益
//  `ItemMicGainCh1` 就是 20 / 30 / 40 / 50 / 60 dB 五档，输出电平标准是 −20 / 0 / +4 dBu 三档）。
//  用推子去表达「五档选择器」既别扭、又容易推出设备不接受的中间值 —— 一排按钮才是对的控件。
//
//  档位来源是设备**当前**下发的 `enum` 列表（它是随状态变化的：摄像机没接上时
//  话筒增益只剩下 Null 一档），所以这里永远按实时档位渲染，不缓存。
//

import SwiftUI

struct EnumChannelView: View {
    let channel: GainChannel
    let enabled: Bool
    var onSelect: (Double) -> Void

    /// 档位从高到低排：往上更响，符合现场直觉。
    private var options: [Double] {
        (channel.snapValues ?? []).sorted(by: >)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(channel.title)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            VStack(spacing: 3) {
                ForEach(options, id: \.self) { value in
                    optionButton(value)
                }
            }

            Text(channel.valueText)
                .font(.system(.footnote, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(channel.pending ? Theme.warning : Color.primary)
                .lineLimit(1)

            if let problem = channel.problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(Theme.program)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if options.isEmpty {
                Text("设备当前不提供可选项")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 104)
        .opacity(enabled ? 1 : 0.4)
    }

    private func optionButton(_ value: Double) -> some View {
        let selected = isCurrent(value)
        return Button {
            onSelect(value)
        } label: {
            Text(label(for: value))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Theme.accent.opacity(0.85) : Color.white.opacity(0.10))
                )
                .foregroundStyle(selected ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func isCurrent(_ value: Double) -> Bool {
        abs(channel.value - value) < 0.0001
    }

    private func label(for value: Double) -> String {
        if let text = channel.label(forDisplayValue: value), !text.isEmpty { return text }
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return channel.unit.isEmpty ? number : "\(number) \(channel.unit)"
    }
}
