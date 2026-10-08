//
//  ParameterMap.swift
//  CCUPad
//
//  每台设备一份「哪个参数是音频增益、哪个参数是 tally」的映射。
//
//  这就是本 App 的核心设计：**不猜参数名**。
//  索尼没公开 HDCU 的完整参数名表（ccu-studio 的 catalog 里也只有 IP Live / 格式那 250 项），
//  所以映射由你在「参数发现」页对着真机确定，然后持久化在这里。
//  换固件、换机型只要重新绑一次，代码不用改。
//

import Foundation

/// 一条增益通道的绑定。
///
/// `divisor` 很关键：设备上报的常常不是「dB」，而是某个内部步进
/// （例如以 0.1 dB 为单位时，原始值 60 表示 6.0 dB）。
/// 界面值 = 原始值 ÷ divisor。拿不准就先留 1，看参数发现页里的原始值再定。
struct GainBinding: Codable, Hashable, Identifiable {
    var itemName: String
    var title: String
    var divisor: Double = 1
    var unit: String = "dB"

    var id: String { itemName }

    /// 设备原始值 → 界面值
    func displayValue(raw: Double) -> Double {
        divisor == 0 ? raw : raw / divisor
    }

    /// 界面值 → 设备原始值
    func rawValue(display: Double) -> Double {
        display * (divisor == 0 ? 1 : divisor)
    }
}

struct ParameterMap: Codable, Hashable {
    /// 增益通道（顺序就是界面上的顺序）。
    var gainChannels: [GainBinding] = []

    /// tally 用哪个参数：分别给「播出」与「预览」各绑一个。
    /// 有些设备的 tally 是一个状态位图参数，那就两个都绑同一个，再靠阈值区分。
    var tallyPgmItem: String? = nil
    var tallyPvwItem: String? = nil

    /// 数值 >= 阈值 视为点亮。0/1 型参数填 0.5 就行。
    var tallyThreshold: Double = 0.5

    /// 有些设备是 0 = 点亮，勾上这个取反。
    var tallyInverted: Bool = false

    /// 界面上给用户看的一句备注。
    var note: String = ""

    var isEmpty: Bool {
        gainChannels.isEmpty && tallyPgmItem == nil && tallyPvwItem == nil
    }

    var tallyBound: Bool {
        tallyPgmItem != nil || tallyPvwItem != nil
    }

    func hasGain(_ itemName: String) -> Bool {
        gainChannels.contains { $0.itemName == itemName }
    }

    func hasTally(_ itemName: String) -> Bool {
        itemName == tallyPgmItem || itemName == tallyPvwItem
    }

    /// 自动挑一组候选（只在用户点「自动绑定」时用，绝不会静默生效）。
    static func autoDetect(from items: [CCUItem]) -> ParameterMap {
        var map = ParameterMap()

        let gains = items
            .filter { $0.isWritable && ItemClassifier.looksLikeAudioGain($0.name) }
            .sorted { $0.name < $1.name }
        map.gainChannels = gains.map { item in
            GainBinding(itemName: item.name, title: item.shortName)
        }

        let tallies = items
            .filter { ItemClassifier.looksLikeTally($0.name) }
            .sorted { $0.name < $1.name }
        if let first = tallies.first {
            map.tallyPgmItem = first.name
        }
        map.note = "自动识别于 \(timestamp())"
        return map
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
