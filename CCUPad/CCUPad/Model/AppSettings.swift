//
//  AppSettings.swift
//  CCUPad
//

import Foundation

struct AppSettings: Codable, Equatable {
    /// 试运行：只显示将要写入的值，一个字节都不发给设备。默认开。
    var dryRun: Bool = true

    /// 拖动推子时是否实时下发。
    /// 默认关：拖动中只在本地预览，松手才写一次 —— 设备侧不会收到几十条中间值，
    /// 现场也更安全。
    var liveWhileDragging: Bool = false

    /// 推子的默认步进（dB）。0.5 是广播里常见的调步。
    var gainStep: Double = 0.5

    /// 批量操作（全部 ±、全部归零）前是否二次确认。
    var confirmBulkWrite: Bool = true

    /// 断线后自动重连。
    var autoReconnect: Bool = true

    /// 重连间隔（秒）。
    var reconnectInterval: Double = 5

    /// 参数发现页默认只显示前多少行（3300 项一次画完会卡）。
    var discoveryRowLimit: Int = 300

    /// 日志保留条数。
    var logLimit: Int = 300

    /// **锁定「其他项目」**：打开后只留「主控台」（推子 + tally），
    /// 参数发现 / 设备 / 设置三个页都要输入管理密码才能看到。
    /// 只有在**已设置管理密码**时才允许打开（密码存在 Keychain，不在设置文件里）。
    var lockAdmin: Bool = false
}
