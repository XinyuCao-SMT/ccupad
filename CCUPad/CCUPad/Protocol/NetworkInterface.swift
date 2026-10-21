//
//  NetworkInterface.swift
//  CCUPad
//
//  「走哪个网卡」。
//
//  现场有时用 Wi-Fi、有时插 USB-C 网卡走有线。iPadOS 不像 Android / Linux 那样
//  给你 SO_BINDTODEVICE，但 Network.framework 提供了 `NWParameters.requiredInterfaceType` ——
//  而本工程两处连接（拿 Digest 挑战的 HTTP 请求、控制通道的 WebSocket）都是自己用
//  `NWConnection` 建的，所以可以直接指定，不需要走 URLSession（它也做不到）。
//
//  ⚠️ 指定了类型但那条链路不存在时，连接会**直接失败**，不会偷偷改走另一张网卡 ——
//  这正是现场想要的行为（宁可连不上，也不要走错网段还显示"已连接"）。
//  所以设置页要如实显示「现在有哪些网卡」。
//

import Foundation
import Network

/// 用户选「走哪个网卡」。
enum NetworkInterfaceChoice: String, Codable, CaseIterable, Identifiable {
    /// 不指定，交给系统按路由决定（默认）。
    case automatic
    case wifi
    case wired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t("自动（系统决定）")
        case .wifi: return L10n.t("仅 Wi-Fi")
        case .wired: return L10n.t("仅有线以太网")
        }
    }

    /// 对应的 Network.framework 类型；`自动` 返回 nil，表示不做限制。
    var requiredType: NWInterface.InterfaceType? {
        switch self {
        case .automatic: return nil
        case .wifi: return .wifi
        case .wired: return .wiredEthernet
        }
    }
}

enum NetworkInterface {
    /// 建 TCP 连接时用的参数。只有明确选了网卡才设置 `requiredInterfaceType`。
    static func parameters(for choice: NetworkInterfaceChoice) -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        if let type = choice.requiredType {
            parameters.requiredInterfaceType = type
        }
        return parameters
    }
}

/// 看当前有哪些网卡可用，给设置页显示（并用来提示「你选的网卡现在没连」）。
///
/// 用单例 + `@ObservedObject`：`NWPathMonitor` 是长生命周期的，放进每台设备的会话里
/// 会开一堆监视器。
final class NetworkInterfaceMonitor: ObservableObject {
    static let shared = NetworkInterfaceMonitor()

    /// 当前可用的网卡类型（去重）。
    @Published private(set) var types: [NWInterface.InterfaceType] = []

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ccupad.nwinfo")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // 用数组 + contains 去重：只依赖 Equatable，不依赖 InterfaceType 是否 Hashable
            var found: [NWInterface.InterfaceType] = []
            for interface in path.availableInterfaces where !found.contains(interface.type) {
                found.append(interface.type)
            }
            DispatchQueue.main.async {
                self?.types = found
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func has(_ type: NWInterface.InterfaceType) -> Bool {
        types.contains(type)
    }

    /// 「Wi-Fi、有线以太网」这样的一句话。
    var summary: String {
        if types.isEmpty { return L10n.t("没有可用网卡") }
        let names = types.map { type -> String in
            switch type {
            case .wifi: return L10n.t("Wi-Fi")
            case .wiredEthernet: return L10n.t("有线以太网")
            case .cellular: return L10n.t("蜂窝")
            case .loopback: return L10n.t("本机回环")
            default: return L10n.t("其它")
            }
        }
        return names.joined(separator: L10n.t("、"))
    }
}
