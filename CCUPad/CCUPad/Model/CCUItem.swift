//
//  CCUItem.swift
//  CCUPad
//
//  设备上的一个参数项，以及「这项大概是干什么的」的启发式判断。
//
//  背景（很重要）：
//    HDCU 一台设备有约 3300 个参数。ccu-studio 的 catalog.mjs 只收录了其中
//    约 250 个（IP Live / 格式 / 网络那一批），**音频增益与 tally 都不在其中**，
//    而索尼没有公开完整的参数名表。
//    所以本 App 不去猜参数名，而是：读回全部参数 → 按名字模式挑出候选 →
//    由你在真机上看着实时值确认并绑定（见 ParameterMap）。
//    下面这些词表就是「挑候选」用的，宁可多挑一些，也不要漏。
//

import Foundation

/// 一个参数项。字段直接对应设备 Ch.Notify.Update 里推回来的结构：
/// `{ "<参数名>": { id, item_type, min, max, value } }`
struct CCUItem: Identifiable, Hashable {
    let name: String
    let numericId: Int
    let itemType: String
    let minValue: Double?
    let maxValue: Double?
    let value: MPValue

    var id: String { name }

    /// 去掉 Item 前缀，界面上短一些。
    var shortName: String {
        name.hasPrefix("Item") ? String(name.dropFirst(4)) : name
    }

    /// 设备用 min == max 表示「这一项不可写」。
    var isReadOnly: Bool {
        guard let low = minValue, let high = maxValue else { return false }
        return low == high
    }

    var isNumeric: Bool { value.number != nil }

    var isWritable: Bool { !isReadOnly && isNumeric }

    var displayValue: String { value.displayText }

    /// 范围文本，例如 "0…100"；取不到就留空。
    var rangeText: String {
        guard let low = minValue, let high = maxValue, low != high else { return "" }
        return "\(formatNumber(low))…\(formatNumber(high))"
    }

    func formatNumber(_ number: Double) -> String {
        if number == number.rounded() { return String(Int(number)) }
        return String(format: "%.3f", number)
    }

    /// 把界面上的浮点值转成设备能接受的形式。
    /// 整数值一定发整数 —— 设备会把 0.0 和 0 当成不同的东西回推，
    /// 发浮点会让「写入后回读校验」永远对不上。
    static func target(from number: Double) -> MPValue {
        if number == number.rounded(), number >= -2147483648, number <= 2147483647 {
            return .int(Int64(number))
        }
        return .double(number)
    }
}

extension MPValue {
    /// 数值型按数值比较，其余按值比较。
    /// 设备回推的 0 与写进去的 0.0 必须算相同，否则校验会一直失败。
    func matches(_ other: MPValue) -> Bool {
        if let mine = number, let theirs = other.number {
            return abs(mine - theirs) < 0.0001
        }
        return self == other
    }
}

/// 参数在界面上的归类。
enum ItemRole: String, CaseIterable, Identifiable {
    case gain
    case tally
    case audio
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gain: return "增益候选"
        case .tally: return "Tally 候选"
        case .audio: return "音频相关"
        case .other: return "其它"
        }
    }
}

/// 按参数名挑候选。宁可宽一点：漏掉一项就等于这项功能在真机上不可用，
/// 多挑几项只是列表长一点，而列表本身就可以搜。
enum ItemClassifier {
    private static let gainWords = ["gain", "level", "volume", "trim", "atten", "fader", "loudness"]
    private static let audioWords = ["audio", "mic", "intercom", "afv", "monitor", "aes", "emb"]
    private static let tallyWords = ["tally", "onair", "on-air", "on_air", "pgm", "preview", "pvw"]

    static func role(of name: String) -> ItemRole {
        let lower = name.lowercased()
        let body = lower.hasPrefix("item") ? String(lower.dropFirst(4)) : lower

        if tallyWords.contains(where: { body.contains($0) }) {
            return .tally
        }
        let looksAudio = audioWords.contains(where: { body.contains($0) })
        let looksGain = gainWords.contains(where: { body.contains($0) })

        if looksAudio && looksGain { return .gain }
        if looksGain && body.contains("audio") { return .gain }
        if looksAudio { return .audio }
        return .other
    }

    /// 自动绑定用的严格一点的名字：必须同时像音频、又像增益，
    /// 而且不能混进只读的监视项。挑不到就返回空，让用户手动绑。
    static func looksLikeAudioGain(_ name: String) -> Bool {
        let lower = name.lowercased()
        let body = lower.hasPrefix("item") ? String(lower.dropFirst(4)) : lower
        let hasAudio = audioWords.contains(where: { body.contains($0) })
        let hasGain = gainWords.contains(where: { body.contains($0) })
        if hasAudio && hasGain { return true }
        return hasGain && lower.contains("audio")
    }

    static func looksLikeTally(_ name: String) -> Bool {
        let lower = name.lowercased()
        let body = lower.hasPrefix("item") ? String(lower.dropFirst(4)) : lower
        return tallyWords.contains(where: { body.contains($0) })
    }
}
