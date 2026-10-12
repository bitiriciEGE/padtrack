import Foundation
import Darwin
import PadTrackCore

/// Minimal client for usbmuxd, the macOS daemon that multiplexes TCP connections to iOS
/// devices over the USB cable (this is how Xcode and Finder talk to an iPad).
///
/// Protocol: a Unix socket at /var/run/usbmuxd; every message is a 16-byte little-endian
/// header (total length, version 1, type 8 = plist, tag) followed by an XML property list.
/// After a successful "Connect", the same socket becomes a raw byte pipe to the device port.
enum USBMux {
    static let socketPath = "/var/run/usbmuxd"

    enum Failure: LocalizedError {
        case socket(String)
        case refused(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .socket(let what): return "usbmuxd soketi: \(what)"
            case .refused(3): return "iPad'de PadTrack açık değil"
            case .refused(let code): return "usbmuxd bağlantıyı reddetti (\(code))"
            case .malformed: return "usbmuxd anlaşılamayan yanıt verdi"
            }
        }
    }

    static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("açılamadı") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = strncpy(buffer, socketPath, capacity - 1)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw Failure.socket("bağlanılamadı (errno \(errno))")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func sendPlist(_ plist: [String: Any], fd: Int32, tag: UInt32) throws {
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var packet = Data()
        func appendLE(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { packet.append(contentsOf: $0) }
        }
        appendLE(UInt32(16 + payload.count))
        appendLE(1) // version: plist protocol
        appendLE(8) // message type: plist
        appendLE(tag)
        packet.append(payload)
        try writeAll(fd: fd, data: packet)
    }

    static func receivePlist(fd: Int32) throws -> [String: Any] {
        let header = try readExactly(fd: fd, count: 16)
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        guard length >= 16, length < 1 << 20 else { throw Failure.malformed }
        let payload = try readExactly(fd: fd, count: length - 16)
        guard let object = try PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil) as? [String: Any] else {
            throw Failure.malformed
        }
        return object
    }

    /// Opens a tunnel to `port` on the device. Blocking; call off the main thread.
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        do {
            try sendPlist([
                "MessageType": "Connect",
                "ClientVersionString": "PadTrack",
                "ProgName": "PadTrack",
                "DeviceID": deviceID,
                // usbmuxd expects the port in network byte order.
                "PortNumber": Int(port.bigEndian),
            ], fd: fd, tag: 1)
            let reply = try receivePlist(fd: fd)
            let code = (reply["Number"] as? NSNumber)?.intValue ?? -1
            guard code == 0 else { throw Failure.refused(code) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func readExactly(fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress! + offset, count - offset)
            }
            if n <= 0 { throw Failure.socket("kapandı") }
            offset += n
        }
        return buffer
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n <= 0 { throw Failure.socket("yazılamadı") }
                offset += n
            }
        }
    }
}

/// Watches usbmuxd for iPads/iPhones plugged in by cable.
final class USBDiscovery {
    struct Device: Equatable {
        let deviceID: Int
        let serial: String
    }

    var onChange: (([Device]) -> Void)?

    private let queue: DispatchQueue
    private var devices: [Int: Device] = [:] // confined to `queue`

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        let thread = Thread { [weak self] in self?.listenForever() }
        thread.name = "PadTrack.usbmux.listen"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func listenForever() {
        while true {
            do {
                let fd = try USBMux.openSocket()
                defer { Darwin.close(fd) }
                try USBMux.sendPlist([
                    "MessageType": "Listen",
                    "ClientVersionString": "PadTrack",
                    "ProgName": "PadTrack",
                    "kLibUSBMuxVersion": 3,
                ], fd: fd, tag: 1)
                while true {
                    try handle(USBMux.receivePlist(fd: fd))
                }
            } catch {
                queue.async { [weak self] in
                    guard let self else { return }
                    self.devices.removeAll()
                    self.publish()
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let type = message["MessageType"] as? String else { return }
        switch type {
        case "Attached":
            guard let id = (message["DeviceID"] as? NSNumber)?.intValue,
                  let properties = message["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB" else { return }
            let serial = properties["SerialNumber"] as? String ?? ""
            queue.async { [weak self] in
                guard let self else { return }
                self.devices[id] = Device(deviceID: id, serial: serial)
                self.publish()
            }
        case "Detached":
            guard let id = (message["DeviceID"] as? NSNumber)?.intValue else { return }
            queue.async { [weak self] in
                guard let self else { return }
                self.devices[id] = nil
                self.publish()
            }
        default:
            break
        }
    }

    private func publish() {
        onChange?(devices.values.sorted { $0.deviceID < $1.deviceID })
    }
}

/// TCP stream to the iPad app through the USB cable.
final class USBLink: TrackpadLink {
    var onMessage: ((Message) -> Void)?
    var onClose: ((String) -> Void)?

    private let deviceID: Int
    private let queue: DispatchQueue
    private var fd: Int32 = -1 // confined to `queue`
    private var closed = false // confined to `queue`

    init(deviceID: Int, queue: DispatchQueue) {
        self.deviceID = deviceID
        self.queue = queue
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "PadTrack.usbmux.link"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Runs on its own thread: connect, then block on read() until the socket closes.
    private func run() {
        let socket: Int32
        do {
            socket = try USBMux.connect(deviceID: deviceID, port: PadTrackProtocol.usbPort)
        } catch {
            let reason = error.localizedDescription
            queue.async { [weak self] in self?.fail(reason) }
            return
        }

        var alreadyClosed = false
        queue.sync {
            if self.closed { alreadyClosed = true } else { self.fd = socket }
        }
        if alreadyClosed {
            Darwin.close(socket)
            return
        }

        var deframer = StreamDeframer()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(socket, raw.baseAddress!, raw.count)
            }
            if n <= 0 { break }
            for payload in deframer.push(Data(buffer[0..<n])) {
                guard let message = try? Message.decode(payload) else { continue }
                queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.onMessage?(message)
                }
            }
        }

        // Forget the descriptor before closing it so no one shuts down a reused number.
        queue.sync { self.fd = -1 }
        Darwin.close(socket)
        queue.async { [weak self] in self?.fail("USB bağlantısı kapandı") }
    }

    func send(_ message: Message) {
        guard !closed, fd >= 0 else { return }
        let data = StreamFraming.frame(message.encoded())
        let written = data.withUnsafeBytes { raw -> Int in
            Darwin.send(fd, raw.baseAddress!, raw.count, MSG_DONTWAIT)
        }
        if written != data.count {
            fail("USB'ye yazılamadı")
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        onClose?(reason)
    }
}
