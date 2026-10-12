import Foundation

// Minimal HTTP/1.1 + WebSocket (RFC 6455) server-side pieces for the Safari client.
// Pure Swift + Foundation so they run (and are tested) anywhere; the socket handling
// itself lives in PadTrackWeb.

// MARK: - HTTP request

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// Request target as sent, path plus optional query.
    public var target: String
    /// Header names are lowercased; repeated headers are joined with ", ".
    public var headers: [String: String]

    public init(method: String, target: String, headers: [String: String]) {
        self.method = method
        self.target = target
        self.headers = headers
    }

    public var path: String {
        target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// True when the request asks to switch this connection to WebSocket version 13.
    public var isWebSocketUpgrade: Bool {
        guard method == "GET",
              let upgrade = header("upgrade"), Self.tokens(upgrade).contains("websocket"),
              let connection = header("connection"), Self.tokens(connection).contains("upgrade"),
              let key = header("sec-websocket-key"), !key.isEmpty,
              header("sec-websocket-version")?.trimmingCharacters(in: .whitespaces) == "13" else {
            return false
        }
        return true
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

public enum HTTPRequestParser {
    public enum Result: Equatable {
        case incomplete
        case invalid
        /// `consumed` is the length of the request head including the blank line.
        case complete(HTTPRequest, consumed: Int)
    }

    /// Anything larger than this is not a request we want to read.
    public static let maxHeadBytes = 8 * 1024

    public static func parse(_ bytes: [UInt8]) -> Result {
        guard let end = headEnd(in: bytes) else {
            return bytes.count > maxHeadBytes ? .invalid : .incomplete
        }
        guard end <= maxHeadBytes else { return .invalid }
        let head = String(decoding: bytes[0..<end], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers)
        return .complete(request, consumed: end + 4)
    }

    /// Index of the "\r\n\r\n" that ends the head, if present.
    private static func headEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i
        }
        return nil
    }
}

public enum HTTPResponse {
    public static func make(status: Int, reason: String, headers: [(String, String)] = [], body: Data = Data()) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - WebSocket handshake

public enum WebSocketHandshake {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Sec-WebSocket-Accept = base64(SHA-1(key + GUID)).
    public static func acceptValue(forKey key: String) -> String {
        let input = key.trimmingCharacters(in: .whitespaces) + guid
        return Data(SHA1.hash(Array(input.utf8))).base64EncodedString()
    }

    /// The 101 response for a valid upgrade request, nil otherwise.
    public static func response(for request: HTTPRequest) -> Data? {
        guard request.isWebSocketUpgrade, let key = request.header("sec-websocket-key") else { return nil }
        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptValue(forKey: key))\r\n\r\n"
        return Data(head.utf8)
    }
}

// MARK: - WebSocket frames

public enum WebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    public var isControl: Bool { rawValue & 0x8 != 0 }
}

public enum WebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(code: UInt16?, reason: String)
}

public enum WebSocketCloseCode {
    public static let normal: UInt16 = 1000
    public static let goingAway: UInt16 = 1001
    public static let protocolError: UInt16 = 1002
    public static let invalidData: UInt16 = 1007
    public static let policyViolation: UInt16 = 1008
    public static let tooBig: UInt16 = 1009
    /// Application range (4000-4999): pairing key or device token rejected.
    public static let unauthorized: UInt16 = 4001
}

public struct WebSocketProtocolError: Error, Equatable {
    public let closeCode: UInt16
    public let reason: String

    public init(closeCode: UInt16, reason: String) {
        self.closeCode = closeCode
        self.reason = reason
    }
}

public enum WebSocketFrame {
    /// Server frames are sent unmasked; pass a 4-byte `mask` to encode a client frame.
    public static func encode(_ opcode: WebSocketOpcode, payload: Data, mask: [UInt8]? = nil, fin: Bool = true) -> Data {
        var out = Data(capacity: payload.count + 14)
        out.append((fin ? 0x80 : 0) | opcode.rawValue)
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        if payload.count < 126 {
            out.append(maskBit | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            out.append(maskBit | 126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        if let mask, mask.count == 4 {
            out.append(contentsOf: mask)
            for (i, byte) in payload.enumerated() {
                out.append(byte ^ mask[i & 3])
            }
        } else {
            out.append(payload)
        }
        return out
    }

    public static func encode(_ message: WebSocketMessage, mask: [UInt8]? = nil) -> Data {
        switch message {
        case .text(let text): return encode(.text, payload: Data(text.utf8), mask: mask)
        case .binary(let data): return encode(.binary, payload: data, mask: mask)
        case .ping(let data): return encode(.ping, payload: data.prefix(125), mask: mask)
        case .pong(let data): return encode(.pong, payload: data.prefix(125), mask: mask)
        case .close(let code, let reason):
            var payload = Data()
            if let code {
                payload.append(UInt8(code >> 8))
                payload.append(UInt8(code & 0xFF))
                payload.append(contentsOf: Array(reason.utf8.prefix(123)))
            }
            return encode(.close, payload: payload, mask: mask)
        }
    }
}

/// Incremental frame parser. Feed bytes as they arrive; get whole messages back.
/// Fragmented messages are reassembled; control frames may arrive between fragments.
public struct WebSocketDecoder {
    public let maxMessageSize: Int
    /// A server must reject unmasked client frames (RFC 6455 §5.1); a client must reject masked ones.
    public let expectMasked: Bool

    private var buffer: [UInt8] = []
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments: [UInt8] = []

    public init(maxMessageSize: Int = 64 * 1024, expectMasked: Bool = true) {
        self.maxMessageSize = maxMessageSize
        self.expectMasked = expectMasked
    }

    public mutating func push(_ data: Data) throws -> [WebSocketMessage] {
        buffer.append(contentsOf: data)
        var messages: [WebSocketMessage] = []
        var offset = 0
        defer { if offset > 0 { buffer.removeFirst(offset) } }

        while true {
            let available = buffer.count - offset
            guard available >= 2 else { break }
            let b0 = buffer[offset]
            let b1 = buffer[offset + 1]
            let fin = b0 & 0x80 != 0
            guard b0 & 0x70 == 0 else { throw WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError, reason: "reserved bits") }
            guard let opcode = WebSocketOpcode(rawValue: b0 & 0x0F) else {
                throw WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError, reason: "unknown opcode")
            }
            let masked = b1 & 0x80 != 0
            guard masked == expectMasked else {
                throw WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError, reason: masked ? "masked frame" : "unmasked frame")
            }

            var headerLength = 2
            var length = Int(b1 & 0x7F)
            if length == 126 {
                guard available >= 4 else { break }
                length = Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
                headerLength = 4
            } else if length == 127 {
                guard available >= 10 else { break }
                var value: UInt64 = 0
                for i in 0..<8 { value = value << 8 | UInt64(buffer[offset + 2 + i]) }
                guard value <= UInt64(Int32.max) else {
                    throw WebSocketProtocolError(closeCode: WebSocketCloseCode.tooBig, reason: "frame too big")
                }
                length = Int(value)
                headerLength = 10
            }

            if opcode.isControl {
                guard fin, length <= 125 else {
                    throw WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError, reason: "bad control frame")
                }
            } else {
                let pending = opcode == .continuation ? fragments.count : 0
                guard pending + length <= maxMessageSize else {
                    throw WebSocketProtocolError(closeCode: WebSocketCloseCode.tooBig, reason: "message too big")
                }
            }

            let maskLength = masked ? 4 : 0
            guard available >= headerLength + maskLength + length else { break }

            let payloadStart = offset + headerLength + maskLength
            var payload = Array(buffer[payloadStart..<(payloadStart + length)])
            if masked {
                let maskStart = offset + headerLength
                for i in 0..<payload.count {
                    payload[i] ^= buffer[maskStart + (i & 3)]
                }
            }
            offset = payloadStart + length

            if let message = try handle(opcode: opcode, fin: fin, payload: payload) {
                messages.append(message)
            }
        }
        return messages
    }

    private mutating func handle(opcode: WebSocketOpcode, fin: Bool, payload: [UInt8]) throws -> WebSocketMessage? {
        switch opcode {
        case .ping:
            return .ping(Data(payload))
        case .pong:
            return .pong(Data(payload))
        case .close:
            guard payload.count != 1 else {
                throw WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError, reason: "bad close payload")
            }
            guard payload.count >= 2 else { return .close(code: nil, reason: "") }
            let code = UInt16(payload[0]) << 8 | UInt16(payload[1])
            return .close(code: code, reason: String(decoding: payload[2...], as: UTF8.self))
        case .text, .binary:
            guard fragmentOpcode == nil else {
                throw WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError, reason: "expected continuation")
            }
            if fin { return try Self.dataMessage(opcode, payload) }
            fragmentOpcode = opcode
            fragments = payload
            return nil
        case .continuation:
            guard let started = fragmentOpcode else {
                throw WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError, reason: "unexpected continuation")
            }
            fragments.append(contentsOf: payload)
            guard fin else { return nil }
            let whole = fragments
            fragmentOpcode = nil
            fragments = []
            return try Self.dataMessage(started, whole)
        }
    }

    private static func dataMessage(_ opcode: WebSocketOpcode, _ payload: [UInt8]) throws -> WebSocketMessage {
        if opcode == .text {
            guard let text = String(bytes: payload, encoding: .utf8) else {
                throw WebSocketProtocolError(closeCode: WebSocketCloseCode.invalidData, reason: "invalid UTF-8")
            }
            return .text(text)
        }
        return .binary(Data(payload))
    }
}

// MARK: - SHA-1

/// Only used for the WebSocket handshake value, where RFC 6455 mandates SHA-1.
/// Not used for anything security related.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]

        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let base = chunk + i * 4
                w[i] = UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
                    | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
            }
            for i in 16..<80 {
                w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotateLeft(b, 30)
                b = a
                a = temp
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(20)
        for word in h {
            digest.append(UInt8(word >> 24))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}
