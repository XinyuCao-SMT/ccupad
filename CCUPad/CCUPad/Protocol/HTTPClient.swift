//
//  HTTPClient.swift
//  CCUPad
//
//  极简 HTTP/1.1 客户端，只干一件事：向 CCU 的 / 取一次 Digest 挑战。
//
//  为什么不用 URLSession：
//    - 我们要的只是响应头里的 WWW-Authenticate，URLSession 的认证状态机会插一脚；
//    - 设备侧是 nginx + Digest，行为与 ccu-studio 里已经跑通的裸 TCP 实现完全一致，
//      这里就照那个实现来，少一层不可控。
//
//  只支持：GET、Content-Length 与 chunked 两种响应体、Connection: close。
//

import Foundation
import Network

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

enum HTTPClientError: Error, CustomStringConvertible {
    case timeout
    case badResponse
    case connectFailed(String)

    var description: String {
        switch self {
        case .timeout: return "请求超时"
        case .badResponse: return "响应无法解析"
        case .connectFailed(let text): return "连接失败：\(text)"
        }
    }
}

enum HTTPClient {
    static func get(host: String,
                    port: UInt16 = 80,
                    path: String = "/",
                    headers extraHeaders: [String: String] = [:],
                    timeout: TimeInterval = 8,
                    completion: @escaping (Result<HTTPResponse, Error>) -> Void) {

        // 端口先转成 Network.framework 的类型：不合法的端口直接失败，
        // 不要靠 `?? 80` 这种依赖字面量推断的写法。
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(HTTPClientError.connectFailed("端口 \(port) 不合法")))
            return
        }

        let queue = DispatchQueue(label: "ccupad.http")
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                     port: endpointPort,
                                     using: .tcp)

        var buffer = Data()
        var finished = false

        func finish(_ result: Result<HTTPResponse, Error>) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(result)
        }

        /// 解析响应。allowIncomplete = true 时，即使正文没收全也先交出去
        /// （对端 close 之后我们就只能拿到这些了）。
        func parse(_ data: Data, allowIncomplete: Bool) -> HTTPResponse? {
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }

            let headData = data.subdata(in: 0..<headerEnd.lowerBound)
            guard let head = String(data: headData, encoding: .isoLatin1) else { return nil }

            let rows = head.components(separatedBy: "\r\n")
            let statusFields = (rows.first ?? "").split(separator: " ")
            let status = statusFields.count >= 2 ? (Int(statusFields[1]) ?? 0) : 0

            var headers: [String: String] = [:]
            for row in rows.dropFirst() {
                guard let colon = row.firstIndex(of: ":") else { continue }
                let key = String(row[row.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(row[row.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            let body = data.subdata(in: headerEnd.upperBound..<data.count)
            let chunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
            let length = Int(headers["content-length"] ?? "") ?? -1

            if chunked {
                if allowIncomplete { return HTTPResponse(status: status, headers: headers, body: dechunk(body)) }
                // chunked 的结束标志是 "0\r\n\r\n"
                if body.range(of: Data("\r\n0\r\n".utf8)) == nil && body.range(of: Data("0\r\n\r\n".utf8)) == nil {
                    return nil
                }
                return HTTPResponse(status: status, headers: headers, body: dechunk(body))
            }

            if length < 0 {
                // 既没长度也不是 chunked：只能等对端关闭
                guard allowIncomplete else { return nil }
                return HTTPResponse(status: status, headers: headers, body: body)
            }

            if body.count < length && !allowIncomplete { return nil }
            let trimmed = body.count > length ? body.subdata(in: 0..<length) : body
            return HTTPResponse(status: status, headers: headers, body: trimmed)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data, !data.isEmpty { buffer.append(data) }

                if let response = parse(buffer, allowIncomplete: false) {
                    finish(.success(response))
                    return
                }
                if let error = error {
                    finish(.failure(HTTPClientError.connectFailed(error.localizedDescription)))
                    return
                }
                if isComplete {
                    if let response = parse(buffer, allowIncomplete: true) {
                        finish(.success(response))
                    } else {
                        finish(.failure(HTTPClientError.badResponse))
                    }
                    return
                }
                receive()
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(HTTPClientError.timeout))
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var lines = ["GET \(path) HTTP/1.1", "Host: \(host)", "Connection: close"]
                for (key, value) in extraHeaders { lines.append("\(key): \(value)") }
                let request = lines.joined(separator: "\r\n") + "\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error = error {
                        finish(.failure(HTTPClientError.connectFailed(error.localizedDescription)))
                    } else {
                        receive()
                    }
                })
            case .failed(let error):
                finish(.failure(HTTPClientError.connectFailed(error.localizedDescription)))
            case .cancelled:
                finish(.failure(HTTPClientError.connectFailed("连接被取消")))
            default:
                break
            }
        }

        connection.start(queue: queue)
    }
}

/// 把 chunked 正文拼回完整正文。
private func dechunk(_ data: Data) -> Data {
    var out = Data()
    var cursor = data.startIndex
    while cursor < data.endIndex {
        guard let lineEnd = data.range(of: Data("\r\n".utf8), in: cursor..<data.endIndex) else { break }
        let sizeText = String(data: data.subdata(in: cursor..<lineEnd.lowerBound), encoding: .isoLatin1) ?? ""
        let sizeHex = sizeText.split(separator: ";").first.map(String.init) ?? ""
        guard let size = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
        let chunkStart = lineEnd.upperBound
        guard let chunkEnd = data.index(chunkStart, offsetBy: size, limitedBy: data.endIndex) else { break }
        out.append(data.subdata(in: chunkStart..<chunkEnd))
        cursor = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
    }
    return out
}
