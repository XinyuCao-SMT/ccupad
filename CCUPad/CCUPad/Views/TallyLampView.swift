//
//  TallyLampView.swift
//  CCUPad
//
//  tally 灯：PGM 红 / PVW 绿 / 未上播 灰。
//  这是整块面板上最先被看到的东西，所以做得最显眼。
//

import SwiftUI

struct TallyLampView: View {
    let tally: TallyState
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tally.color)
                .frame(width: compact ? 8 : 11, height: compact ? 8 : 11)

            Text(tally.label)
                .font(compact ? .caption2 : .caption)
                .fontWeight(.bold)
                .foregroundStyle(tally.color)
        }
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(
            Capsule().fill(tally.color.opacity(0.16))
        )
        .overlay(
            Capsule().stroke(tally.color.opacity(0.35), lineWidth: 1)
        )
    }
}

/// 设备连接状态的小圆点 + 文字。
struct StatusChipView: View {
    let status: CCUStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.shortLabel)
                .font(.caption2)
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(status.color.opacity(0.12))
        )
    }
}
