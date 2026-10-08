//
//  DigestAuth.swift
//  CCUPad
//
//  CCU 的网页接口用 HTTP Digest 认证（MD5 / qop=auth / realm=normal）。
//  与 ccu-studio 的 lib/protocol.mjs 行为一致。
//
//  两个必须照做的细节（都是真机上踩出来的）：
//    1) /linear 这个 WebSocket 地址在**未认证时返回 403 而不是 401**，
//       也就是说它不会给我们 Digest 挑战。所以必须先去 GET / 拿一次挑战，
//       再把算好的 Authorization 直接放进升级请求里。
//    2) 升级请求必须带 Origin 头，否则 nginx 直接 403。
//

import Foundation
import CryptoKit

struct DigestChallenge {
    var realm: String = ""
    var nonce: String = ""
    var qop: String? = nil
    var opaque: String? = nil
    var algorithm: String? = nil

    /// 从 WWW-Authenticate 头里解析出挑战。
    ///
    /// 自己按引号切分，而不是用正则：realm 里可能带逗号，
    /// 正则很容易在那里断错。
    static func parse(_ header: String) -> DigestChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("digest") else { return nil }

        var challenge = DigestChallenge()
        let body = trimmed.dropFirst("digest".count)

        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in body {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                continue
            }
            if ch == "," && !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)

        for part in parts {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard let eq = text.firstIndex(of: "=") else { continue }
            let key = String(text[text.startIndex..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(text[text.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "realm": challenge.realm = value
            case "nonce": challenge.nonce = value
            case "qop": challenge.qop = value
            case "opaque": challenge.opaque = value
            case "algorithm": challenge.algorithm = value
            default: break
            }
        }

        guard !challenge.realm.isEmpty, !challenge.nonce.isEmpty else { return nil }
        return challenge
    }

    /// qop 可能是 "auth,auth-int"，只认第一个。
    var preferredQop: String? {
        guard let qop = qop else { return nil }
        let first = qop.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let value = first, !value.isEmpty else { return nil }
        return value
    }

    /// 算出可以直接放进请求头的 Authorization。
    func authorization(method: String, uri: String, user: String, password: String, nc: Int = 1) -> String {
        let ha1 = Digest.md5Hex("\(user):\(realm):\(password)")
        let ha2 = Digest.md5Hex("\(method):\(uri)")
        let ncHex = String(format: "%08x", nc)
        let cnonce = Digest.randomHex(8)

        var parts = [
            "username=\"\(user)\"",
            "realm=\"\(realm)\"",
            "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\"",
        ]

        if let qop = preferredQop {
            let response = Digest.md5Hex("\(ha1):\(nonce):\(ncHex):\(cnonce):\(qop):\(ha2)")
            parts.append("response=\"\(response)\"")
            parts.append("qop=\(qop)")
            parts.append("nc=\(ncHex)")
            parts.append("cnonce=\"\(cnonce)\"")
        } else {
            let response = Digest.md5Hex("\(ha1):\(nonce):\(ha2)")
            parts.append("response=\"\(response)\"")
        }

        if let algorithm = algorithm { parts.append("algorithm=\(algorithm)") }
        if let opaque = opaque { parts.append("opaque=\"\(opaque)\"") }

        return "Digest " + parts.joined(separator: ", ")
    }
}

enum Digest {
    /// MD5 十六进制小写。Digest 认证只认 MD5，这里用 CryptoKit 的 Insecure.MD5。
    static func md5Hex(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 随机字节的十六进制串（cnonce / Sec-WebSocket-Key 都用它）。
    static func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomBytes(_ byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    static func base64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    /// WebSocket 握手要求的 Sec-WebSocket-Accept：SHA1(key + 固定 GUID)。
    static func webSocketAccept(for key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }
}
