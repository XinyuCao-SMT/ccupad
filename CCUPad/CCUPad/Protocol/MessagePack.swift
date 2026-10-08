//
//  MessagePack.swift
//  CCUPad
//
//  设备的控制通道 ws://<ip>/linear 上跑的是 MessagePack 帧，形状为 [2, "方法名", {参数}]。
//  这里逐条对齐 ccu-studio 里已经对真机验证过的 Node 版实现（lib/protocol.mjs）：
//  整数取最短编码、字符串三种长度前缀、数组/映射两种长度前缀，一个不少。
//
//  自己实现而不是引第三方包，是为了让工程保持零依赖 ——
//  CI 上不需要解析 Swift Package，编译失败也只可能来自我们自己的代码。
//

import Foundation

/// 一个 MessagePack 值。
///
/// 只实现设备实际会用到的类型。map 的键在设备上永远是字符串，
/// 所以直接固定成 [String: MPValue]，省掉一次键类型转换。
indirect enum MPValue: Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MPValue])
    case map([String: MPValue])
}

extension MPValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 数值统一成 Double（整数、浮点、布尔都吃），增益这类可计算的量都用它。
    var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .uint(let v): return Double(v)
        case .double(let v): return v
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }

    var integer: Int? {
        guard let n = number else { return nil }
        return Int(n)
    }

    var boolean: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .uint(let v): return v != 0
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [MPValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var mapValue: [String: MPValue]? {
        if case .map(let m) = self { return m }
        return nil
    }

    subscript(key: String) -> MPValue? {
        mapValue?[key]
    }

    /// 给界面显示的紧凑文本。
    var displayText: String {
        switch self {
        case .null:
            return "—"
        case .bool(let v):
            return v ? "true" : "false"
        case .int(let v):
            return String(v)
        case .uint(let v):
            return String(v)
        case .double(let v):
            if v == v.rounded() { return String(Int64(v)) }
            return String(format: "%.4f", v)
        case .string(let s):
            return s
        case .binary(let d):
            return "<\(d.count) 字节>"
        case .array(let a):
            return "[" + a.map { $0.displayText }.joined(separator: ", ") + "]"
        case .map(let m):
            return "{" + m.keys.sorted().map { "\($0): \(m[$0]?.displayText ?? "")" }.joined(separator: ", ") + "}"
        }
    }
}

enum MessagePackError: Error, CustomStringConvertible {
    case truncated
    case unsupported(UInt8)
    case badString

    var description: String {
        switch self {
        case .truncated: return "MessagePack 数据不完整"
        case .unsupported(let b): return String(format: "MessagePack 不支持的字节 0x%02X", b)
        case .badString: return "MessagePack 字符串不是合法的 UTF-8"
        }
    }
}

enum MessagePack {
    static func decode(_ data: Data) throws -> MPValue {
        var decoder = Decoder(bytes: [UInt8](data))
        return try decoder.decodeValue()
    }

    static func encode(_ value: MPValue) -> Data {
        var out: [UInt8] = []
        append(value, to: &out)
        return Data(out)
    }

    // MARK: - 解码

    struct Decoder {
        let bytes: [UInt8]
        var pos = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var remaining: Int { bytes.count - pos }

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, remaining >= n else { throw MessagePackError.truncated }
            let slice = bytes[pos..<(pos + n)]
            pos += n
            return slice
        }

        mutating func u8() throws -> UInt8 {
            guard remaining >= 1 else { throw MessagePackError.truncated }
            let b = bytes[pos]
            pos += 1
            return b
        }

        // 注意：ArraySlice 的下标沿用原数组的索引，所以一律从 startIndex 起算
        mutating func u16() throws -> UInt16 {
            let s = try take(2)
            return (UInt16(s[s.startIndex]) << 8) | UInt16(s[s.startIndex + 1])
        }

        mutating func u32() throws -> UInt32 {
            let s = try take(4)
            var v: UInt32 = 0
            for i in 0..<4 { v = (v << 8) | UInt32(s[s.startIndex + i]) }
            return v
        }

        mutating func u64() throws -> UInt64 {
            let s = try take(8)
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(s[s.startIndex + i]) }
            return v
        }

        mutating func float32() throws -> Float {
            let s = try take(4)
            var bits: UInt32 = 0
            for i in 0..<4 { bits = (bits << 8) | UInt32(s[s.startIndex + i]) }
            return Float(bitPattern: bits)
        }

        mutating func float64() throws -> Double {
            let s = try take(8)
            var bits: UInt64 = 0
            for i in 0..<8 { bits = (bits << 8) | UInt64(s[s.startIndex + i]) }
            return Double(bitPattern: bits)
        }

        mutating func decodeString(_ n: Int) throws -> MPValue {
            let s = try take(n)
            guard let text = String(bytes: s, encoding: .utf8) else { throw MessagePackError.badString }
            return .string(text)
        }

        mutating func decodeArray(_ n: Int) throws -> MPValue {
            var out: [MPValue] = []
            if n > 0 { out.reserveCapacity(n) }
            for _ in 0..<n { out.append(try decodeValue()) }
            return .array(out)
        }

        mutating func decodeMap(_ n: Int) throws -> MPValue {
            var out: [String: MPValue] = [:]
            for _ in 0..<n {
                let key = try decodeValue()
                let value = try decodeValue()
                if let text = key.stringValue {
                    out[text] = value
                } else {
                    out[key.displayText] = value
                }
            }
            return .map(out)
        }

        mutating func decodeValue() throws -> MPValue {
            let b = try u8()

            if b <= 0x7f { return .int(Int64(b)) }
            if b >= 0xe0 { return .int(Int64(b) - 256) }
            if b >= 0x80 && b <= 0x8f { return try decodeMap(Int(b & 0x0f)) }
            if b >= 0x90 && b <= 0x9f { return try decodeArray(Int(b & 0x0f)) }
            if b >= 0xa0 && b <= 0xbf { return try decodeString(Int(b & 0x1f)) }

            switch b {
            case 0xc0:
                return .null
            case 0xc2:
                return .bool(false)
            case 0xc3:
                return .bool(true)
            case 0xc4:
                let n = Int(try u8())
                return .binary(Data(try take(n)))
            case 0xc5:
                let n = Int(try u16())
                return .binary(Data(try take(n)))
            case 0xc6:
                let n = Int(try u32())
                return .binary(Data(try take(n)))
            case 0xca:
                return .double(Double(try float32()))
            case 0xcb:
                return .double(try float64())
            case 0xcc:
                return .uint(UInt64(try u8()))
            case 0xcd:
                return .uint(UInt64(try u16()))
            case 0xce:
                return .uint(UInt64(try u32()))
            case 0xcf:
                return .uint(try u64())
            case 0xd0:
                return .int(Int64(Int8(bitPattern: try u8())))
            case 0xd1:
                return .int(Int64(Int16(bitPattern: try u16())))
            case 0xd2:
                return .int(Int64(Int32(bitPattern: try u32())))
            case 0xd3:
                return .int(Int64(bitPattern: try u64()))
            case 0xd9:
                return try decodeString(Int(try u8()))
            case 0xda:
                return try decodeString(Int(try u16()))
            case 0xdb:
                return try decodeString(Int(try u32()))
            case 0xdc:
                return try decodeArray(Int(try u16()))
            case 0xdd:
                return try decodeArray(Int(try u32()))
            case 0xde:
                return try decodeMap(Int(try u16()))
            case 0xdf:
                return try decodeMap(Int(try u32()))
            default:
                throw MessagePackError.unsupported(b)
            }
        }
    }

    // MARK: - 编码

    static func append(_ value: MPValue, to out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(0xc0)
        case .bool(let v):
            out.append(v ? 0xc3 : 0xc2)
        case .int(let v):
            appendInt(v, to: &out)
        case .uint(let v):
            if v <= UInt64(Int64.max) {
                appendInt(Int64(v), to: &out)
            } else {
                appendBeBytes(v, count: 8, marker: 0xcf, to: &out)
            }
        case .double(let v):
            appendBeBytes(v.bitPattern, count: 8, marker: 0xcb, to: &out)
        case .string(let s):
            appendString(s, to: &out)
        case .binary(let d):
            let n = d.count
            if n < 256 {
                out.append(0xc4)
                out.append(UInt8(n))
            } else if n < 65536 {
                appendBeBytes(UInt64(n), count: 2, marker: 0xc5, to: &out)
            } else {
                appendBeBytes(UInt64(n), count: 4, marker: 0xc6, to: &out)
            }
            out.append(contentsOf: d)
        case .array(let a):
            appendHeader(count: a.count, smallBase: 0x90, wideMarker: 0xdc, to: &out)
            for item in a { append(item, to: &out) }
        case .map(let m):
            appendHeader(count: m.count, smallBase: 0x80, wideMarker: 0xde, to: &out)
            for key in m.keys.sorted() {
                appendString(key, to: &out)
                append(m[key] ?? .null, to: &out)
            }
        }
    }

    private static func appendInt(_ v: Int64, to out: inout [UInt8]) {
        if v >= 0 && v <= 127 {
            out.append(UInt8(v))
        } else if v < 0 && v >= -32 {
            out.append(UInt8(bitPattern: Int8(v)))
        } else if v >= 0 && v <= 255 {
            out.append(0xcc)
            out.append(UInt8(v))
        } else if v >= 0 && v <= 65535 {
            appendBeBytes(UInt64(v), count: 2, marker: 0xcd, to: &out)
        } else if v >= 0 && v <= 4294967295 {
            appendBeBytes(UInt64(v), count: 4, marker: 0xce, to: &out)
        } else if v >= -128 && v <= 127 {
            appendBeBytes(UInt64(bitPattern: v), count: 1, marker: 0xd0, to: &out)
        } else if v >= -32768 && v <= 32767 {
            appendBeBytes(UInt64(bitPattern: v), count: 2, marker: 0xd1, to: &out)
        } else if v >= -2147483648 && v <= 2147483647 {
            appendBeBytes(UInt64(bitPattern: v), count: 4, marker: 0xd2, to: &out)
        } else {
            appendBeBytes(UInt64(bitPattern: v), count: 8, marker: 0xd3, to: &out)
        }
    }

    private static func appendHeader(count: Int, smallBase: UInt8, wideMarker: UInt8, to out: inout [UInt8]) {
        if count < 16 {
            out.append(smallBase | UInt8(count))
        } else if count < 65536 {
            appendBeBytes(UInt64(count), count: 2, marker: wideMarker, to: &out)
        } else {
            // 16 位长度前缀装不下时只能用 32 位；设备不会走到这里，留着保持编码器完整
            let marker32 = wideMarker == 0xdc ? UInt8(0xdd) : UInt8(0xdf)
            appendBeBytes(UInt64(count), count: 4, marker: marker32, to: &out)
        }
    }

    private static func appendBeBytes(_ v: UInt64, count: Int, marker: UInt8?, to out: inout [UInt8]) {
        if let marker = marker { out.append(marker) }
        var shift = (count - 1) * 8
        while shift >= 0 {
            out.append(UInt8((v >> UInt64(shift)) & 0xff))
            shift -= 8
        }
    }

    private static func appendString(_ s: String, to out: inout [UInt8]) {
        let utf8 = Array(s.utf8)
        let n = utf8.count
        if n < 32 {
            out.append(0xa0 | UInt8(n))
        } else if n < 256 {
            out.append(0xd9)
            out.append(UInt8(n))
        } else if n < 65536 {
            appendBeBytes(UInt64(n), count: 2, marker: 0xda, to: &out)
        } else {
            appendBeBytes(UInt64(n), count: 4, marker: 0xdb, to: &out)
        }
        out.append(contentsOf: utf8)
    }
}

// MARK: - 设备报文

extension MPValue {
    /// 订阅一个通知通道： [2, "Subscribe", {channel: "..."}]
    static func subscribe(channel: String) -> MPValue {
        .array([.int(2), .string("Subscribe"), .map(["channel": .string(channel)])])
    }

    /// 索要全部参数： [2, "Ch.SetValue", {id: 8603, op_type: 0, value: 7}]
    ///
    /// 8603 = ItemWebAllItemRequest，官方网页每次打开页面就是这么把所有项要一遍的。
    /// 设备收到后会把约 3300 个参数通过 Ch.Notify.Update 推回来。
    static func requestAllItems() -> MPValue {
        .array([.int(2), .string("Ch.SetValue"), .map([
            "id": .int(8603),
            "op_type": .int(0),
            "value": .int(7),
        ])])
    }

    /// 写一个参数： [2, "Ch.SetValue", {id: <参数ID>, op_type: 0, value: <值>}]
    static func setValue(id: Int, value: MPValue) -> MPValue {
        .array([.int(2), .string("Ch.SetValue"), .map([
            "id": .int(Int64(id)),
            "op_type": .int(0),
            "value": value,
        ])])
    }
}
