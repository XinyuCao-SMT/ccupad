//
//  CCUState.swift
//  CCUPad
//
//  界面用的派生状态：连接状态、tally、一条增益通道、一台设备的整体快照。
//  全部由 CCUManager 从会话数据 + ParameterMap 算出来，是可渲染的纯数据。
//

import Foundation

enum CCUStatus: Equatable {
    case idle
    case connecting
    case loading
    case ready
    case failed(String)
    case closed

    var label: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .loading: return "读取参数中"
        case .ready: return "已连接"
        case .failed(let text): return "失败：\(text)"
        case .closed: return "已断开"
        }
    }

    var shortLabel: String {
        switch self {
        case .idle: return "待机"
        case .connecting: return "连接中"
        case .loading: return "读取中"
        case .ready: return "在线"
        case .failed: return "异常"
        case .closed: return "断开"
        }
    }

    var isConnected: Bool {
        switch self {
        case .ready, .loading: return true
        default: return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .loading: return true
        default: return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// tally 状态。tally 在广播里是权威信息（哪个机位在播出），这里只表达这一台机位。
struct TallyState: Equatable {
    var program: Bool = false
    var preview: Bool = false
    /// 数据来源（绑定的参数名、「未绑定」、「无数据」）——出问题时能一眼看出是哪一层。
    var source: String = "未绑定"

    static let unknown = TallyState()

    var isLive: Bool { program || preview }

    var label: String {
        if program { return "PGM" }
        if preview { return "PVW" }
        return "—"
    }

    var detail: String {
        if program { return "播出中" }
        if preview { return "预览" }
        return "未上播"
    }
}

/// 界面上的一条增益通道。原始值、范围、除数都留着 ——
/// 推子改的是**界面值**，下发前再乘回除数。
struct GainChannel: Identifiable, Hashable {
    var itemName: String
    var title: String
    var rawValue: Double
    var rawMin: Double
    var rawMax: Double
    var divisor: Double = 1
    var unit: String = "dB"
    var writable: Bool = true
    var pending: Bool = false
    var problem: String? = nil

    var id: String { itemName }

    var value: Double { divisor == 0 ? rawValue : rawValue / divisor }
    var minValue: Double { divisor == 0 ? rawMin : rawMin / divisor }
    var maxValue: Double { divisor == 0 ? rawMax : rawMax / divisor }

    var span: ClosedRange<Double> {
        let low = min(minValue, maxValue)
        let high = max(minValue, maxValue)
        if high - low < 0.0001 { return (low - 1)...(high + 1) }
        return low...high
    }

    /// 归一化到 0…1，给推子和电平条用。
    var normalized: Double {
        let range = span
        let width = range.upperBound - range.lowerBound
        guard width > 0 else { return 0.5 }
        return min(max((value - range.lowerBound) / width, 0), 1)
    }

    var valueText: String {
        GainChannel.format(value, unit: unit)
    }

    static func format(_ number: Double, unit: String) -> String {
        let text = number == number.rounded() ? String(Int(number)) : String(format: "%.1f", number)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }
}

/// 一台设备在界面上的完整快照。
struct CCUDeviceState: Identifiable {
    let id: UUID
    var status: CCUStatus = .idle
    var itemCount: Int = 0
    var systemName: String = ""
    var model: String = ""
    var serial: String = ""
    var firmware: String = ""
    var gains: [GainChannel] = []
    var tally: TallyState = .unknown
    var lastError: String? = nil
    var updatedAt: Date? = nil

    init(id: UUID) {
        self.id = id
    }

    var gainSummary: String {
        if gains.isEmpty { return "未绑定增益" }
        if gains.count == 1 { return gains[0].valueText }
        let average = gains.reduce(0) { $0 + $1.value } / Double(gains.count)
        let text = average == average.rounded() ? String(Int(average)) : String(format: "%.1f", average)
        return "\(gains.count) 路 · 均 \(text) dB"
    }

    /// 一台设备所有增益通道取平均后的归一化位置，给总览条用。
    var gainNormalized: Double {
        guard !gains.isEmpty else { return 0 }
        return gains.reduce(0) { $0 + $1.normalized } / Double(gains.count)
    }

    var hasPendingWrite: Bool { gains.contains { $0.pending } }

    var hasProblem: Bool { gains.contains { $0.problem != nil } }

    var tallyLevel: Int {
        if tally.program { return 2 }
        if tally.preview { return 1 }
        return 0
    }
}

/// 一台设备的诊断日志。
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let at: Date
    let device: String
    let text: String

    var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: at)
    }
}
