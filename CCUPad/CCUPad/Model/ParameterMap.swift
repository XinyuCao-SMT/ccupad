//
//  ParameterMap.swift
//  CCUPad
//
//  每台设备一份「哪个参数是音频增益、哪个参数是 tally」的映射。
//
//  早期设计是「不猜参数名、由用户在现场绑」；现在对 HDCU 系列已经**实测确认**了
//  确切的参数名（见 `hdcu3500Default()`），所以新设备接上就会自动套用，
//  绑定页留给非 HDCU 设备或需要微调的情况。
//
//  实测依据（2026-10，S6_HDCU3500 机群 10 台，HDCU3500 / V3.40）：
//    · 增益 = ItemAudioOutCh1Adjust / Ch2Adjust，**min 0 … max 255（256 档）**，
//      静止值 128 —— 而 OSD 上显示 0，所以 **显示值 = 原始值 − 128**。
//    · ItemAudioOutCh1Level / Ch2Level 是 **3 档枚举**（−20 / 0 / +4 dBu），
//      是输出参考电平标准，不是可以来回推的增益。
//    · tally：在 1 号机上切绿、红挪到 7 号机，前后各读一次全部 10 台 ——
//      只有 ItemTallyRStatus 跟着红、ItemTallyGStatus 跟着绿。**这是实测不是推断。**
//

import Foundation

/// 一条增益通道的绑定。
///
/// 设备上报的常常不是「dB」，而是某个内部步进，所以两个换算参数都要有：
///   - `divisor`：显示值 = 原始值 ÷ divisor（例如以 0.1 dB 为单位时填 10）
///   - `offset` ：显示值再减去它（例如 HDCU 的 ADJUST 原始 0…255、中心 128 才是 0 dB，
///               于是 offset 填 128，界面上的 0 与 OSD 上的 0 就对齐了）
///
/// 两者都**手写解码并给默认值**：合成 Codable 遇到缺失字段会直接抛错，
/// 那会让旧版本存下来的映射整份读不出来（升级即丢绑定）。
struct GainBinding: Codable, Hashable, Identifiable {
    var itemName: String
    var title: String
    var divisor: Double
    var offset: Double
    var unit: String
    /// 枚举型通道的「原始值 → 显示文字」。设备只给数值不给标签
    /// （例如 LEVEL = 3103000/3103001/3103002），标签得由我们带上。
    var valueLabels: [String: String]

    var id: String { itemName }

    init(itemName: String,
         title: String,
         divisor: Double = 1,
         offset: Double = 0,
         unit: String = "dB",
         valueLabels: [String: String] = [:]) {
        self.itemName = itemName
        self.title = title
        self.divisor = divisor
        self.offset = offset
        self.unit = unit
        self.valueLabels = valueLabels
    }

    private enum CodingKeys: String, CodingKey {
        case itemName, title, divisor, offset, unit, valueLabels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemName = try container.decode(String.self, forKey: .itemName)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        divisor = try container.decodeIfPresent(Double.self, forKey: .divisor) ?? 1
        offset = try container.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? "dB"
        valueLabels = try container.decodeIfPresent([String: String].self, forKey: .valueLabels) ?? [:]
    }

    /// 设备原始值 → 界面值
    func displayValue(raw: Double) -> Double {
        let scaled = divisor == 0 ? raw : raw / divisor
        return scaled - offset
    }

    /// 界面值 → 设备原始值
    func rawValue(display: Double) -> Double {
        (display + offset) * (divisor == 0 ? 1 : divisor)
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

    /// **实测确认的 HDCU3500 / 3100 默认映射**（2026-10 在 10 台真机上验证）。
    ///
    /// 前三类：
    ///   · `ItemMicGainCh1/Ch2` —— 摄像机话筒增益，**5 档枚举**（20/30/40/50/60 dB）。
    ///     ⚠️ 设备下发的档位表是「当前可选」的：摄像机没接上时只有 `Null` 一档，
    ///     这时 App 会把它判成不可写（不会推出不合法的中间值）。
    ///   · `ItemAudioOutCh1/Ch2Adjust` —— 音频输出增益，0…255，中心 128 = OSD 的 0。
    ///   · `ItemAudioOutCh1/Ch2Level` —— 输出参考电平标准，3 档枚举。
    static func hdcu3500Default() -> ParameterMap {
        var map = ParameterMap()

        let levelLabels = [
            "3103000": "−20 dBu",
            "3103001": "0 dBu",
            "3103002": "+4 dBu",
        ]
        let micGainLabels = [
            "3001000": "Null",
            "3001001": "20 dB",
            "3001002": "30 dB",
            "3001003": "40 dB",
            "3001004": "50 dB",
            "3001005": "60 dB",
        ]

        map.gainChannels = [
            GainBinding(itemName: "ItemMicGainCh1", title: "MIC1 增益",
                        divisor: 1, offset: 0, unit: "", valueLabels: micGainLabels),
            GainBinding(itemName: "ItemMicGainCh2", title: "MIC2 增益",
                        divisor: 1, offset: 0, unit: "", valueLabels: micGainLabels),
            GainBinding(itemName: "ItemAudioOutCh1Adjust", title: "OUT1 增益",
                        divisor: 1, offset: 128, unit: ""),
            GainBinding(itemName: "ItemAudioOutCh2Adjust", title: "OUT2 增益",
                        divisor: 1, offset: 128, unit: ""),
            GainBinding(itemName: "ItemAudioOutCh1Level", title: "OUT1 电平",
                        divisor: 1, offset: 0, unit: "", valueLabels: levelLabels),
            GainBinding(itemName: "ItemAudioOutCh2Level", title: "OUT2 电平",
                        divisor: 1, offset: 0, unit: "", valueLabels: levelLabels),
        ]

        map.tallyPgmItem = "ItemTallyRStatus"
        map.tallyPvwItem = "ItemTallyGStatus"
        map.note = "HDCU3500 实测默认（MIC GAIN 5 档；ADJUST 0…255 中心 128；R=PGM、G=PVW）"
        return map
    }

    /// 自动挑候选（非 HDCU 设备、或用户想重挑时用）。
    static func autoDetect(from items: [CCUItem]) -> ParameterMap {
        if let exact = exactDefaults(in: items) { return exact }

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
        map.note = "按参数名自动识别于 \(timestamp())"
        return map
    }

    /// 只有当设备**确实带**那批实测确认的参数时，才用实测默认；否则返回 nil。
    ///
    /// 这样既能让 HDCU 装上即绑好，又不会把不存在的参数名写进别的机型。
    static func exactDefaults(in items: [CCUItem]) -> ParameterMap? {
        let names = Set(items.map { $0.name })
        guard names.contains("ItemAudioOutCh1Adjust"),
              names.contains("ItemTallyRStatus") else { return nil }
        return hdcu3500Default()
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
