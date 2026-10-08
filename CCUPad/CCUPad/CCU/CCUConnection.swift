//
//  CCUConnection.swift
//  CCUPad
//
//  会话层的抽象，以及一个**内置演示机位**。
//
//  为什么要抽象：真机连不上时，你没法判断是 App 的问题还是设备/网络的问题。
//  有了协议，`CCUManager` 对「真实 CCU」和「演示机位」一视同仁 ——
//  装上 App 就能先跑通一遍界面、推子、写入校验与 tally，
//  再去连真机；真机出问题时也知道「这套代码本身是能跑的」。
//
//  演示机位完全在本机生成参数，不碰网络，也不会写任何设备。
//

import Foundation

/// 一台 CCU 的会话能力（真实会话与演示会话都实现它）。
protocol CCUConnection: AnyObject {
    var device: CCUDevice { get }

    var onItemsChanged: (() -> Void)? { get set }
    var onStatusChanged: ((CCUStatus) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }

    func connect()
    func stop()

    func itemList() -> [CCUItem]
    func itemCount() -> Int
    func snapshot(for names: [String]) -> [String: CCUItem]
    func pendingItemNames() -> Set<String>
    func failedItemNames() -> [String: String]

    /// 写一个参数；设备回推后才算确认（演示机位会模拟这个回推）。
    func setValue(itemName: String, value: MPValue)
}

/// 演示机位：不连网络，参数由本机生成。
///
/// 覆盖的场景是**调试用**的，不求以假乱真：
///   - 8 路音频增益，量程 -20.0…+20.0 dB（原始值以 0.1 dB 为单位，所以除数是 10）
///   - 两个 tally 参数（PGM / PVW）每 3 秒翻一次，模拟切换台在切机位
///   - 若干「看着像但不是」的诱饵项（tally 灯模式、音频监听电平），
///     让「参数发现」页有真实的干扰项可以辨认
///   - 约 600 个填充参数，让参数量与真实设备同量级（真机约 3300）
///
/// 线程约定：全部在主线程上跑（`connect` 由界面触发），所以不需要串行队列。
final class SimulatedCCU: CCUConnection {

    let device: CCUDevice

    var onItemsChanged: (() -> Void)? = nil
    var onStatusChanged: ((CCUStatus) -> Void)? = nil
    var onLog: ((String) -> Void)? = nil

    private var items: [String: CCUItem] = [:]
    private var pending: Set<String> = []
    private var failures: [String: String] = [:]

    private var timer: Timer?
    private var closed = false
    private var program = false
    private var preview = true

    init(device: CCUDevice) {
        self.device = device
    }

    // MARK: - 连接

    func connect() {
        closed = false
        onStatusChanged?(.connecting)
        onLog?("演示机位：正在生成模拟参数…")

        // 分两步走，好让界面真的走一遍「连接中 → 读取参数中 → 已连接」
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, !self.closed else { return }
            self.items = Self.makeItems()
            self.onStatusChanged?(.loading)
            self.onItemsChanged?()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, !self.closed else { return }
                self.onStatusChanged?(.ready)
                self.onLog?("演示机位已就绪：\(self.items.count) 个模拟参数（其中 8 路音频增益 + 2 路 tally）")
                self.startFlipping()
            }
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        onStatusChanged?(.closed)
    }

    // MARK: - 读取

    func itemList() -> [CCUItem] {
        Array(items.values)
    }

    func itemCount() -> Int {
        items.count
    }

    func snapshot(for names: [String]) -> [String: CCUItem] {
        var out: [String: CCUItem] = [:]
        for name in names {
            if let item = items[name] { out[name] = item }
        }
        return out
    }

    func pendingItemNames() -> Set<String> {
        pending
    }

    func failedItemNames() -> [String: String] {
        failures
    }

    // MARK: - 写值（模拟设备的处理延迟与回推）

    func setValue(itemName: String, value: MPValue) {
        guard let item = items[itemName] else {
            failures[itemName] = "演示机位没有参数 \(itemName)"
            onItemsChanged?()
            return
        }
        guard item.isWritable else {
            failures[itemName] = "参数 \(itemName) 在演示机位上是只读的"
            onItemsChanged?()
            return
        }

        pending.insert(itemName)
        onItemsChanged?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, !self.closed else { return }
            self.replace(itemName, value: value)
            self.pending.remove(itemName)
            self.failures.removeValue(forKey: itemName)
            self.onItemsChanged?()
        }
    }

    // MARK: - 模拟切换台切机位

    private func startFlipping() {
        timer?.invalidate()
        let created = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.flipTally()
        }
        timer = created
    }

    private func flipTally() {
        guard !closed else { return }
        program.toggle()
        if !program { preview.toggle() }

        replace("ItemTallyRStatus", value: .int(program ? 1 : 0))
        replace("ItemTallyGStatus", value: .int(preview ? 1 : 0))
        replace("ItemAudioMonitorLevel", value: .int(Int64(-150 - Int.random(in: 0...450))))
        onItemsChanged?()
    }

    private func replace(_ name: String, value: MPValue) {
        guard let item = items[name] else { return }
        items[name] = CCUItem(name: item.name,
                              numericId: item.numericId,
                              itemType: item.itemType,
                              minValue: item.minValue,
                              maxValue: item.maxValue,
                              value: value,
                              enumValues: item.enumValues)
    }

    // MARK: - 生成参数

    private static func makeItems() -> [String: CCUItem] {
        var items: [String: CCUItem] = [:]

        func add(_ name: String,
                 id: Int,
                 type: String = "int",
                 min: Double? = 0,
                 max: Double? = 100,
                 value: MPValue,
                 enumValues: [MPValue]? = nil) {
            items[name] = CCUItem(name: name,
                                  numericId: id,
                                  itemType: type,
                                  minValue: min,
                                  maxValue: max,
                                  value: value,
                                  enumValues: enumValues)
        }

        // 设备身份（只读：min == max 就是真机上「不可写」的表达方式）
        add("ItemAttributeSystemName", id: 9001, type: "string", min: 0, max: 0, value: .string("DEMO-01"))
        add("ItemSerialNumberName", id: 9002, type: "string", min: 0, max: 0, value: .string("HDCU-3500"))
        add("ItemSerialNumberNumber", id: 9003, type: "string", min: 0, max: 0, value: .string("DEMO0001"))
        add("ItemVersionOS", id: 9004, type: "string", min: 0, max: 0, value: .string("1.20-demo"))
        add("ItemNetworkIpAddress", id: 9005, type: "string", min: 0, max: 0, value: .string("10.205.1.101"))
        add("ItemCnsCcuNo", id: 9006, min: 0, max: 96, value: .int(1))

        // 8 路音频增益：原始值是 0.1 dB 单位（-200…200 即 -20.0…+20.0 dB）
        // 所以绑定时的除数是 10 —— 这正是「除数」这个字段要解决的问题。
        let startValues = [-30, -10, 0, 20, 40, -5, 15, 0]
        for index in 1...8 {
            add("ItemAudioIn\(index)Gain",
                id: 1000 + index,
                min: -200,
                max: 200,
                value: .int(Int64(startValues[index - 1])))
        }
        add("ItemAudioOut1Gain", id: 1011, min: 0, max: 3, value: .int(-120),
            enumValues: [.int(-600), .int(-300), .int(-120), .int(0)])
        add("ItemAudioOut2Gain", id: 1012, min: -200, max: 200, value: .int(-60))

        // tally + 音频输出增益：**故意用与真机相同的参数名与量程**，
        // 这样演示机位跑的就是正式那条路径（含 offset 128 的换算），
        // 等于随包带了一个可以自己验一遍的副本。
        add("ItemAudioOutCh1Adjust", id: 3001, min: 0, max: 255, value: .int(140))
        add("ItemAudioOutCh2Adjust", id: 3002, min: 0, max: 255, value: .int(116))
        add("ItemAudioOutCh1Level", id: 3003, min: nil, max: nil, value: .int(3103001),
            enumValues: [.int(3103000), .int(3103001), .int(3103002)])
        add("ItemAudioOutCh2Level", id: 3004, min: nil, max: nil, value: .int(3103001),
            enumValues: [.int(3103000), .int(3103001), .int(3103002)])
        add("ItemTallyRStatus", id: 2001, min: 0, max: 1, value: .int(0))
        add("ItemTallyGStatus", id: 2002, min: 0, max: 1, value: .int(1))
        // 枚举型诱饵：min/max 报的是索引范围，合法值在这个档位表里 ——
        // 正是真机上「不能让推子自由取值」的那种参数
        add("ItemTallyLampMode", id: 2003, min: 0, max: 3, value: .int(0),
            enumValues: [.int(0), .int(1), .int(2), .int(3)])
        add("ItemAudioMonitorLevel", id: 2004, min: -600, max: 0, value: .int(-200))
        add("ItemIntercomGain", id: 2005, min: -200, max: 200, value: .int(-40))

        // 填充项：让参数数量与真机同量级，也方便在「参数发现」页练搜索
        var id = 3000
        let families = [
            "ItemOutputFormat", "ItemReturnFormat", "ItemCameraPaint", "ItemDetail",
            "ItemKnee", "ItemGamma", "ItemBlack", "ItemWhite", "ItemMonitor", "ItemTrunk",
        ]
        let fields = ["Format", "ColorSpace", "Value", "Level", "Mode", "Enable"]
        for family in families {
            for port in 1...10 {
                for field in fields {
                    id += 1
                    add("\(family)\(port)\(field)",
                        id: id,
                        min: 0,
                        max: 100,
                        value: .int(Int64((id * 7) % 101)))
                }
            }
        }

        // 网络与模式类只读项（真机上这些是枚举，这里只求名字像）
        add("ItemMulticastAddressMode", id: 9500, min: 0, max: 0, value: .int(5337001))
        add("ItemNetworkLan1IpAddress", id: 9501, type: "string", min: 0, max: 0, value: .string("10.205.1.101"))
        add("ItemNetworkSubnetMask", id: 9502, type: "string", min: 0, max: 0, value: .string("255.255.255.0"))

        return items
    }
}
