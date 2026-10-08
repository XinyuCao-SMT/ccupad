//
//  WebSocketClient.swift
//  CCUPad
//
//  自己实现的 WebSocket 客户端（RFC 6455 的客户端子集），跑在 Network.framework 上。
//
//  为什么不用 URLSessionWebSocketTask：
//    1) CCU 的 nginx 对 /linear 在**未认证时返回 403 而不是 401**，
//       所以拿不到 Digest 挑战、也就没法靠 URLSession 的自动认证走通；
//       必须先自己 GET / 取挑战，再把算好的 Authorization 头放进升级请求。
//    2) 升级请求必须带 Origin 头，否则 403。URLSession 不保证原样转发自定义头。
//  这两点都是 ccu-studio 在真机上确认过的（见其 README「技术要点」）。
//
//  支持：客户端掩码、16/64 位长度、ping/pong、close、以及分片帧的拼接。
//

import Foundation
import Network

final class WebSocketClient {
    enum State: Equatable {
        case idle
        case connecting
        case open
        case closed
    }

    let host: String
    let port: UInt16
    let path: String

    private let queue = DispatchQueue(label: "ccupad.websocket")
    private var connection: NWConnection? = nil
    private var buffer = Data()
    private var handshakeComplete = false
    private var closed = true
    private var expectedAccept = ""
    private var timeoutItem: DispatchWorkItem? = nil

    // 分片帧的拼接状态
    private var pendingOpcode: UInt8 = 0
    private var pendingPayload = Data()

    var onStateChange: ((State) -> Void)? = nil
    var onMessage: ((MPValue) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    var onClose: (() -> Void)? = nil

    init(host: String, port: UInt16 = 80, path: String = "/linear") {
        self.host = host
        self.port = port
        self.path = path
    }

    var isOpen: Bool { handshakeComplete && !closed }

    // MARK: - 建立连接

    /// 用已经算好的 Digest Authorization 发起升级。
    func connect(authorization: String, origin: String, timeout: TimeInterval = 10) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onError?("端口 \(port) 不合法")
            return
        }

        closed = false
        handshakeComplete = false
        buffer = Data()
        pendingPayload = Data()
        onStateChange?(.connecting)

        let key = Digest.base64(Digest.randomBytes(16))
        expectedAccept = Digest.webSocketAccept(for: key)

        let connection = NWConnection(host: NWEndpoint.Host(host),
                                     port: endpointPort,
                                     using: .tcp)
        self.connection = connection

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.handshakeComplete, !self.closed else { return }
            self.onError?("控制通道握手超时（\(Int(timeout)) 秒）——设备可达但 /linear 没有回应")
            self.close()
        }
        timeoutItem = watchdog
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let request = [
                    "GET \(self.path) HTTP/1.1",
                    "Host: \(self.host)",
                    "Connection: Upgrade",
                    "Upgrade: websocket",
                    "Origin: \(origin)",
                    "Sec-WebSocket-Key: \(key)",
                    "Sec-WebSocket-Version: 13",
                    "Authorization: \(authorization)",
                    "Cache-Control: no-cache",
                    "Pragma: no-cache",
                    "User-Agent: CCUPad/1.0",
                    "", "",
                ].joined(separator: "\r\n")

                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error = error {
                        self.onError?("发送升级请求失败：\(error.localizedDescription)")
                        self.close()
                    } else {
                        self.receiveLoop()
                    }
                })
            case .failed(let error):
                self.onError?("连接 \(self.host) 失败：\(error.localizedDescription)")
                self.close()
            case .cancelled:
                self.markClosed()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveLoop() {
        guard let connection = connection, !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                if self.handshakeComplete {
                    self.drainFrames()
                } else {
                    self.processHandshake()
                }
            }

            if let error = error {
                if !self.closed { self.onError?("接收出错：\(error.localizedDescription)") }
                self.close()
                return
            }
            if isComplete {
                self.markClosed()
                return
            }
            self.receiveLoop()
        }
    }

    private func processHandshake() {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }

        let headData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let head = String(data: headData, encoding: .isoLatin1) else {
            onError?("握手响应无法解析")
            close()
            return
        }

        let rows = head.components(separatedBy: "\r\n")
        let statusFields = (rows.first ?? "").split(separator: " ")
        let status = statusFields.count >= 2 ? (Int(statusFields[1]) ?? 0) : 0

        guard status == 101 else {
            onError?(Self.explain(status: status))
            close()
            return
        }

        var accept = ""
        for row in rows where row.lowercased().hasPrefix("sec-websocket-accept:") {
            if let colon = row.firstIndex(of: ":") {
                accept = String(row[row.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            break
        }
        guard accept == expectedAccept else {
            onError?("Sec-WebSocket-Accept 校验失败 —— 对端可能不是标准 WebSocket 服务")
            close()
            return
        }

        timeoutItem?.cancel()
        buffer = buffer.subdata(in: headerEnd.upperBound..<buffer.count)
        handshakeComplete = true
        onStateChange?(.open)
        drainFrames()
    }

    /// 把升级失败的 HTTP 状态码翻译成能照着做的结论。
    private static func explain(status: Int) -> String {
        switch status {
        case 401:
            return "/linear 返回 401：Digest 挑战被拒绝，检查用户名 / 密码"
        case 403:
            return "/linear 返回 403：认证头或 Origin 没被接受（用户名 / 密码不对，或该地址不放行控制通道）"
        case 404:
            return "/linear 返回 404：这台设备的网页接口路径不同，可能不是 HDCU 系列"
        case 500, 502, 503, 504:
            return "/linear 返回 \(status)：CCU 的网页服务异常或正在重启"
        default:
            return "/linear 返回 HTTP \(status)：控制通道升级失败"
        }
    }

    // MARK: - 帧

    private struct Frame {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
    }

    private func drainFrames() {
        while !closed, let frame = readFrame() {
            let opcode: UInt8
            let payload: Data

            if frame.opcode == 0x0 {
                // 续帧
                pendingPayload.append(frame.payload)
                if !frame.fin { continue }
                opcode = pendingOpcode
                payload = pendingPayload
                pendingPayload = Data()
            } else if !frame.fin {
                // 首帧但没结束
                pendingOpcode = frame.opcode
                pendingPayload = frame.payload
                continue
            } else {
                opcode = frame.opcode
                payload = frame.payload
            }

            switch opcode {
            case 0x8:
                close()
                return
            case 0x9:
                sendFrame(opcode: 0xa, payload: payload)
            case 0xa:
                break
            case 0x1, 0x2:
                do {
                    let value = try MessagePack.decode(payload)
                    onMessage?(value)
                } catch {
                    onError?("报文解码失败：\(error)")
                }
            default:
                break
            }
        }
    }

    /// 从缓冲区里取出一个完整帧；数据不够就原样留着，返回 nil。
    private func readFrame() -> Frame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }

        let fin = (bytes[0] & 0x80) != 0
        let opcode = bytes[0] & 0x0f
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7f)
        var offset = 2

        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            var value = 0
            for i in 0..<8 { value = (value << 8) | Int(bytes[offset + i]) }
            length = value
            offset += 8
        }

        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }

        guard length >= 0, bytes.count >= offset + length else { return nil }

        var payload = Array(bytes[offset..<(offset + length)])
        if masked && !maskKey.isEmpty {
            for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
        }

        buffer = buffer.subdata(in: (offset + length)..<buffer.count)
        return Frame(fin: fin, opcode: opcode, payload: Data(payload))
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        guard let connection = connection, !closed else { return }

        var frame = Data()
        frame.append(0x80 | opcode)

        let mask = [UInt8](Digest.randomBytes(4))
        let length = payload.count

        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xff))
            frame.append(UInt8(length & 0xff))
        } else {
            frame.append(0x80 | 127)
            var value = UInt64(length)
            var lengthBytes: [UInt8] = []
            for _ in 0..<8 {
                lengthBytes.insert(UInt8(value & 0xff), at: 0)
                value >>= 8
            }
            frame.append(contentsOf: lengthBytes)
        }

        frame.append(contentsOf: mask)

        var masked = [UInt8](payload)
        for i in 0..<masked.count { masked[i] ^= mask[i % 4] }
        frame.append(contentsOf: masked)

        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// 发一个 MessagePack 报文（二进制帧）。
    func send(_ value: MPValue) {
        sendFrame(opcode: 0x2, payload: MessagePack.encode(value))
    }

    // MARK: - 关闭

    func close() {
        guard !closed else { return }
        closed = true
        handshakeComplete = false
        timeoutItem?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onStateChange?(.closed)
        onClose?()
    }

    private func markClosed() {
        guard !closed else { return }
        closed = true
        handshakeComplete = false
        timeoutItem?.cancel()
        connection = nil
        onStateChange?(.closed)
        onClose?()
    }
}
