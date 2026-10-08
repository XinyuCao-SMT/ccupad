//
//  Theme.swift
//  CCUPad
//
//  深色广播风配色。现场多是暗环境，面板要一眼能读出「哪台在播出」。
//

import SwiftUI

enum Theme {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let panelStroke = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.07)

    /// PGM：播出中，红
    static let program = Color(red: 0.95, green: 0.20, blue: 0.22)
    /// PVW：预览，绿
    static let preview = Color(red: 0.20, green: 0.85, blue: 0.40)
    /// 未上播 / 未知
    static let idle = Color(red: 0.45, green: 0.47, blue: 0.52)
    static let accent = Color(red: 0.30, green: 0.65, blue: 1.00)
    static let warning = Color(red: 1.00, green: 0.68, blue: 0.18)
    static let gainFill = Color(red: 0.25, green: 0.60, blue: 0.95)
}

extension CCUStatus {
    var color: Color {
        switch self {
        case .ready: return Theme.preview
        case .loading, .connecting: return Theme.warning
        case .failed: return Theme.program
        case .closed, .idle: return Theme.idle
        }
    }
}

extension TallyState {
    var color: Color {
        if program { return Theme.program }
        if preview { return Theme.preview }
        return Theme.idle
    }
}

/// 面板统一外观：圆角深色卡片。
struct PanelBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.panelStroke, lineWidth: 1)
            )
    }
}

extension View {
    func panel(padding: CGFloat = 14) -> some View {
        modifier(PanelBackground(padding: padding))
    }
}
