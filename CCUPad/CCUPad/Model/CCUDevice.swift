//
//  CCUDevice.swift
//  CCUPad
//
//  一台 CCU 的连接信息。密码不进这里 —— 它单独存 Keychain（见 Keychain.swift）。
//

import Foundation

struct CCUDevice: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 80
    var user: String = "admin"
    var enabled: Bool = true

    var label: String { name.isEmpty ? host : name }

    var endpointText: String {
        port == 80 ? host : "\(host):\(port)"
    }
}

/// IP 规格展开：单个、末段范围、逗号分隔的混合。
///
/// 与 ccu-studio 的 expandIps 保持一致（现场就是这么写规划的）：
///   `10.205.1.101`、`10.205.1.101-108, 10.205.1.111`
/// 结果去重，并按末段数字排序，顺序稳定。
enum DeviceSpecParser {
    static func expand(_ spec: String) -> [String] {
        var collected: [String] = []
        let separators = CharacterSet(charactersIn: " ,;\n\t\r")
        let tokens = spec.components(separatedBy: separators).filter { !$0.isEmpty }

        for token in tokens {
            if token.contains("-") {
                let parts = token.split(separator: "-", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let octets = parts[0].split(separator: ".").map(String.init)
                guard octets.count == 4,
                      let start = Int(octets[3]),
                      let end = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
                let prefix = octets[0...2].joined(separator: ".")
                if start <= end {
                    for value in start...end { collected.append("\(prefix).\(value)") }
                } else {
                    for value in stride(from: start, through: end, by: -1) {
                        collected.append("\(prefix).\(value)")
                    }
                }
                continue
            }
            if isIPv4(token) { collected.append(token) }
        }

        var seen = Set<String>()
        var unique: [String] = []
        for host in collected where !seen.contains(host) {
            seen.insert(host)
            unique.append(host)
        }
        return unique.sorted { lastOctet($0) < lastOctet($1) }
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255, !part.isEmpty else { return false }
        }
        return true
    }

    static func lastOctet(_ host: String) -> Int {
        let parts = host.split(separator: ".").map(String.init)
        guard let last = parts.last, let value = Int(last) else { return 0 }
        return value
    }

    /// 按「末段 − 基准」生成机位名，例如基准 100 时 .101 → CCU-01。
    ///
    /// CNS 机位号在 ccu-studio 里就是这么推的（CcuNo = 末段 − 100），
    /// 这里沿用同一套编号习惯，省得两边对不上。
    static func autoName(host: String, prefix: String, base: Int, digits: Int) -> String {
        let index = lastOctet(host) - base
        let width = max(1, min(digits, 4))
        let number = abs(index)
        var text = String(number)
        while text.count < width { text = "0" + text }
        if index < 0 { text = "-" + text }
        return "\(prefix)\(text)"
    }
}
