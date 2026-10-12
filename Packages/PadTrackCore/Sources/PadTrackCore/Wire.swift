import Foundation

/// Constants shared by the iPad and the Mac app.
public enum PadTrackProtocol {
    public static let version: UInt8 = 1
    /// Bonjour service the iPad advertises for Wi‑Fi / peer-to-peer Wi‑Fi.
    public static let bonjourServiceType = "_padtrack._udp"
    /// TXT record key carrying the iPad's persistent device ID.
    public static let bonjourDeviceIDKey = "id"
    /// TCP port the iPad listens on; the Mac reaches it over the USB cable through usbmuxd.
    public static let usbPort: UInt16 = 47390
    /// TCP port the Mac serves the Safari client on (HTTP page + WebSocket). Fixed, so a
    /// Home Screen bookmark keeps working.
    public static let webPort: UInt16 = 47391
    public static let bleServiceUUID = "7B6F1000-3C2A-4E8B-9D51-2F64A8C0E101"
    /// iPad -> Mac, notify. One message per notification.
    public static let bleFrameCharacteristicUUID = "7B6F1001-3C2A-4E8B-9D51-2F64A8C0E101"
    /// Mac -> iPad, write without response. One message per write.
    public static let bleControlCharacteristicUUID = "7B6F1002-3C2A-4E8B-9D51-2F64A8C0E101"
    public static let maxTouchesPerFrame = 10
}

public enum LinkTransport: UInt8, CaseIterable, Sendable {
    case usb = 1
    case wifi = 2
    case bluetooth = 3
    /// The iPad's Safari page, connected to the Mac's WebSocket server over Wi‑Fi.
    case web = 4

    public var displayName: String {
        switch self {
        case .usb: return "USB"
        case .wifi: return "Wi‑Fi"
        case .bluetooth: return "Bluetooth"
        case .web: return "Safari"
        }
    }

    /// Lower is preferred (USB has the lowest latency, Bluetooth the highest).
    public var priority: Int {
        switch self {
        case .usb: return 1
        case .wifi: return 2
        case .web: return 3
        case .bluetooth: return 4
        }
    }
}

/// One finger on the iPad, in iPad points (origin top-left, y grows downward).
public struct TouchPoint: Equatable, Sendable {
    public var id: UInt8
    public var x: Float
    public var y: Float

    public init(id: UInt8, x: Float, y: Float) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// A full snapshot of every finger touching the iPad at one instant.
/// Because each frame carries the complete state, a lost or coalesced frame never
/// leaves the Mac with a stuck finger: the next frame corrects everything.
public struct TouchFrame: Equatable, Sendable {
    public var seq: UInt32
    /// Seconds on the iPad's monotonic clock (UITouch / UIEvent timestamp).
    public var timestamp: Double
    public var touches: [TouchPoint]

    public init(seq: UInt32, timestamp: Double, touches: [TouchPoint]) {
        self.seq = seq
        self.timestamp = timestamp
        self.touches = touches
    }
}

public struct HelloInfo: Equatable, Sendable {
    public var protocolVersion: UInt8
    public var deviceName: String
    /// Random UUID the iPad app creates once and keeps. The Mac uses it to remember which
    /// iPads the user approved, so it never auto-connects to a stranger's device.
    public var deviceID: String
    public var surfaceWidth: Float
    public var surfaceHeight: Float

    public init(protocolVersion: UInt8 = PadTrackProtocol.version, deviceName: String, deviceID: String = "",
                surfaceWidth: Float, surfaceHeight: Float) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
    }
}

public struct SubscribeInfo: Equatable, Sendable {
    public var protocolVersion: UInt8
    public var transport: LinkTransport
    public var hostName: String

    public init(protocolVersion: UInt8 = PadTrackProtocol.version, transport: LinkTransport, hostName: String) {
        self.protocolVersion = protocolVersion
        self.transport = transport
        self.hostName = hostName
    }
}

public enum Message: Equatable, Sendable {
    /// iPad -> Mac, answer to `subscribe` (and again when the surface size changes).
    case hello(HelloInfo)
    /// iPad -> Mac, every touch change.
    case frame(TouchFrame)
    /// Mac -> iPad keep-alive carrying the Mac's clock in nanoseconds.
    case ping(UInt64)
    /// iPad -> Mac, echoes the ping value so the Mac can measure round-trip time.
    case pong(UInt64)
    /// Mac -> iPad, "send your touches to me over this link".
    case subscribe(SubscribeInfo)
    /// Either side, graceful close.
    case bye
}

public enum WireError: Error, Equatable {
    case truncated
    case unknownType(UInt8)
    case invalidValue
}

extension Message {
    private enum Kind: UInt8 {
        case hello = 1
        case frame = 2
        case ping = 3
        case pong = 4
        case subscribe = 5
        case bye = 6
    }

    /// Compact little-endian encoding. A five-finger frame is 59 bytes.
    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case .hello(let info):
            w.u8(Kind.hello.rawValue)
            w.u8(info.protocolVersion)
            w.f32(info.surfaceWidth)
            w.f32(info.surfaceHeight)
            w.string(info.deviceName)
            w.string(info.deviceID)
        case .frame(let frame):
            w.u8(Kind.frame.rawValue)
            w.u32(frame.seq)
            w.f64(frame.timestamp)
            let touches = frame.touches.prefix(PadTrackProtocol.maxTouchesPerFrame)
            w.u8(UInt8(touches.count))
            for touch in touches {
                w.u8(touch.id)
                w.f32(touch.x)
                w.f32(touch.y)
            }
        case .ping(let value):
            w.u8(Kind.ping.rawValue)
            w.u64(value)
        case .pong(let value):
            w.u8(Kind.pong.rawValue)
            w.u64(value)
        case .subscribe(let info):
            w.u8(Kind.subscribe.rawValue)
            w.u8(info.protocolVersion)
            w.u8(info.transport.rawValue)
            w.string(info.hostName)
        case .bye:
            w.u8(Kind.bye.rawValue)
        }
        return w.data
    }

    public static func decode(_ data: Data) throws -> Message {
        var r = ByteReader(data)
        let raw = try r.u8()
        guard let kind = Kind(rawValue: raw) else { throw WireError.unknownType(raw) }
        switch kind {
        case .hello:
            let version = try r.u8()
            let width = try r.f32()
            let height = try r.f32()
            let name = try r.string()
            let deviceID = try r.isAtEnd ? "" : r.string()
            return .hello(HelloInfo(protocolVersion: version, deviceName: name, deviceID: deviceID,
                                    surfaceWidth: width, surfaceHeight: height))
        case .frame:
            let seq = try r.u32()
            let timestamp = try r.f64()
            let count = try Int(r.u8())
            var touches: [TouchPoint] = []
            touches.reserveCapacity(count)
            for _ in 0..<count {
                let id = try r.u8()
                let x = try r.f32()
                let y = try r.f32()
                guard x.isFinite, y.isFinite else { throw WireError.invalidValue }
                touches.append(TouchPoint(id: id, x: x, y: y))
            }
            guard timestamp.isFinite else { throw WireError.invalidValue }
            return .frame(TouchFrame(seq: seq, timestamp: timestamp, touches: touches))
        case .ping:
            return try .ping(r.u64())
        case .pong:
            return try .pong(r.u64())
        case .subscribe:
            let version = try r.u8()
            let transportRaw = try r.u8()
            guard let transport = LinkTransport(rawValue: transportRaw) else { throw WireError.invalidValue }
            let name = try r.string()
            return .subscribe(SubscribeInfo(protocolVersion: version, transport: transport, hostName: name))
        case .bye:
            return .bye
        }
    }
}

// MARK: - Stream framing (TCP over USB)

/// TCP is a byte stream, so every message gets a 2-byte little-endian length prefix.
/// UDP datagrams and Bluetooth notifications already carry message boundaries and are sent unframed.
public enum StreamFraming {
    public static func frame(_ payload: Data) -> Data {
        let length = UInt16(min(payload.count, Int(UInt16.max)))
        var out = Data(capacity: Int(length) + 2)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8(length >> 8))
        out.append(payload.prefix(Int(length)))
        return out
    }
}

public struct StreamDeframer {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feed raw bytes; returns every complete message payload found so far.
    public mutating func push(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var payloads: [Data] = []
        var offset = 0
        while buffer.count - offset >= 2 {
            let length = Int(buffer[offset]) | (Int(buffer[offset + 1]) << 8)
            guard buffer.count - offset - 2 >= length else { break }
            payloads.append(Data(buffer[(offset + 2)..<(offset + 2 + length)]))
            offset += 2 + length
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return payloads
    }
}

// MARK: - Byte helpers

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { appendLittleEndian(value) }
    mutating func u32(_ value: UInt32) { appendLittleEndian(value) }
    mutating func u64(_ value: UInt64) { appendLittleEndian(value) }
    mutating func f32(_ value: Float) { u32(value.bitPattern) }
    mutating func f64(_ value: Double) { u64(value.bitPattern) }

    /// Length-prefixed UTF-8, at most 255 bytes.
    mutating func string(_ value: String) {
        let bytes = Array(value.utf8.prefix(255))
        u8(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }

    private mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func u8() throws -> UInt8 {
        guard index < bytes.count else { throw WireError.truncated }
        let value = bytes[index]
        index += 1
        return value
    }

    mutating func u16() throws -> UInt16 { try littleEndian(UInt16.self) }
    mutating func u32() throws -> UInt32 { try littleEndian(UInt32.self) }
    mutating func u64() throws -> UInt64 { try littleEndian(UInt64.self) }
    mutating func f32() throws -> Float { try Float(bitPattern: u32()) }
    mutating func f64() throws -> Double { try Double(bitPattern: u64()) }

    mutating func string() throws -> String {
        let length = try Int(u8())
        guard index + length <= bytes.count else { throw WireError.truncated }
        let value = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
        index += length
        return value
    }

    private mutating func littleEndian<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard index + size <= bytes.count else { throw WireError.truncated }
        var value: T = 0
        for i in 0..<size {
            value |= T(bytes[index + i]) << (8 * i)
        }
        index += size
        return value
    }
}
