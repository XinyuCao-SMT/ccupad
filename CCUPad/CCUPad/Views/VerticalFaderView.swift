//
//  VerticalFaderView.swift
//  CCUPad
//
//  垂直推子 —— 现场调音最顺手的控件：手指按哪儿就跳到哪儿，
//  拖动时只在本地预览（默认不下发），松手才写一次设备。
//
//  改的是**界面值**（displayValue）；通道里存的是设备原始值，
//  两者差一个除数（见 GainBinding.divisor）。
//

import SwiftUI

struct VerticalFaderView: View {
    let channel: GainChannel
    let step: Double
    let enabled: Bool
    let live: Bool
    /// 枚举型参数的合法档位；有值时松手吸附到最近档位，而不是按 step 取整。
    var snapValues: [Double]? = nil
    var onPreview: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var dragging = false
    @State private var localValue: Double? = nil

    private var shownValue: Double {
        localValue ?? channel.value
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(channel.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            GeometryReader { geo in
                faderBody(size: geo.size)
            }
            .frame(height: 190)

            Text(text(for: shownValue))
                .font(.system(.footnote, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(channel.pending ? Theme.warning : .primary)
                .lineLimit(1)

            HStack(spacing: 6) {
                nudgeButton("−") { onCommit(snap(channel.value - step)) }
                nudgeButton("0") { onCommit(0) }
                nudgeButton("+") { onCommit(snap(channel.value + step)) }
            }
            .opacity(enabled ? 1 : 0.4)

            if let problem = channel.problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(Theme.program)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 68)
    }

    // MARK: - 推子主体

    @ViewBuilder
    private func faderBody(size: CGSize) -> some View {
        let height = max(size.height, 1)
        let width = max(size.width, 1)
        let range = channel.span
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let knobY = height * CGFloat(1 - normalized(shownValue, range: range, span: span))

        ZStack(alignment: .top) {
            Capsule()
                .fill(Theme.track)
                .frame(width: 10)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(channel.pending ? Theme.warning : Theme.gainFill)
                    .frame(width: 10, height: max(height - knobY, 0))
            }

            // 0 dB 参考线（量程里含 0 时才画）
            if range.lowerBound < 0 && range.upperBound > 0 {
                let zeroY = height * CGFloat(1 - normalized(0, range: range, span: span))
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: width * 0.7, height: 1)
                    .offset(y: zeroY)
            }

            Circle()
                .fill(channel.pending ? Theme.warning : Color.white)
                .frame(width: dragging ? 30 : 24, height: dragging ? 30 : 24)
                .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
                .offset(y: knobY - (dragging ? 15 : 12))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.35)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard enabled else { return }
                    dragging = true
                    let value = valueAt(y: gesture.location.y, height: height, range: range, span: span)
                    localValue = value
                    if live { onPreview(value) }
                }
                .onEnded { gesture in
                    guard enabled else { return }
                    dragging = false
                    let value = valueAt(y: gesture.location.y, height: height, range: range, span: span)
                    localValue = nil
                    onCommit(value)
                }
        )
    }

    private func nudgeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 坐标换算

    private func normalized(_ value: Double, range: ClosedRange<Double>, span: Double) -> Double {
        min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func valueAt(y: CGFloat, height: CGFloat, range: ClosedRange<Double>, span: Double) -> Double {
        let ratio = min(max(Double(y) / Double(max(height, 1)), 0), 1)
        let raw = range.upperBound - ratio * span
        return snap(raw)
    }

    private func snap(_ value: Double) -> Double {
        // 枚举型：只能落在设备给的档位上
        if let values = snapValues, values.count > 1 {
            return GainChannel.snapped(value, range: channel.span, enumValues: values)
        }

        let range = channel.span
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step > 0.0001 else { return clamped }
        return (clamped / step).rounded() * step
    }

    private func text(for value: Double) -> String {
        // 枚举型通道（例如输出参考电平标准）显示设备的档位文字，而不是 3103001 这种原始值
        if let label = channel.label(forDisplayValue: value), !label.isEmpty { return label }
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return channel.unit.isEmpty ? number : "\(number) \(channel.unit)"
    }
}
