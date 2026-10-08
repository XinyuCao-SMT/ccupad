//
//  GainSnapshot.swift
//  CCUPad
//
//  一次「下发前的现场快照」—— 用于回滚。
//
//  为什么要有它：这个 App 会**真的把增益写进 CCU**。舞台上手滑推错一下，
//  或者批量操作按错方向，必须能立刻退回来 —— 这是 ccu-studio 那边定下的纪律
//  （「执行前强制生成快照，可逐设备回滚」），控制类工具都该照做。
//
//  快照只记录**已绑定**的增益通道，存的是设备原始值（不带除数换算），
//  这样以后改除数、改单位都不会让旧快照失真。
//

import Foundation

struct GainSnapshot: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var at: Date = Date()
    var deviceId: UUID
    var deviceLabel: String
    /// 触发这次快照的操作（批量 +1 dB / 全部归零 / 手动 …）。
    var reason: String
    /// 参数名 → 设备原始值
    var values: [String: Double]

    var channelCount: Int { values.count }

    var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: at)
    }
}
