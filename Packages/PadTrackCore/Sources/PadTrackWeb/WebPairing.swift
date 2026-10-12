#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// Where paired Safari devices are kept between launches.
public protocol WebPairingStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

public final class UserDefaultsPairingStore: WebPairingStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "webPairedDevices") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Data? { defaults.data(forKey: key) }
    public func save(_ data: Data) { defaults.set(data, forKey: key) }
}

public final class InMemoryPairingStore: WebPairingStore {
    public var data: Data?
    public init() {}
    public func load() -> Data? { data }
    public func save(_ data: Data) { self.data = data }
}

/// Decides who may drive this Mac from Safari. Anyone on the same Wi‑Fi can reach the
/// web server, so a connection is only accepted with
///  - the one-time pairing key from the QR code in the Mac menu (consumed on use), or
///  - the long random device token the Mac handed out at pairing.
/// Only a SHA-256 of each token is stored.
///
/// Not thread-safe: use it from the server's queue.
public final class WebPairing {
    public struct Device: Codable, Equatable, Sendable {
        public let id: String
        public var name: String
        public let pairedAt: Date
        fileprivate let tokenHash: String
    }

    public static let maxDevices = 20

    public private(set) var pairingKey: String
    public private(set) var devices: [Device]

    private let store: WebPairingStore

    public init(store: WebPairingStore) {
        self.store = store
        pairingKey = Self.randomString(byteCount: 16)
        devices = store.load().flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
    }

    /// Invalidates the QR code currently shown.
    public func regenerateKey() {
        pairingKey = Self.randomString(byteCount: 16)
    }

    /// A correct key is consumed, so a photographed or leaked QR code works once at most.
    public func pair(key: String, name: String) -> (device: Device, token: String)? {
        guard Self.constantTimeEquals(key, pairingKey) else { return nil }
        regenerateKey()
        let token = Self.randomString(byteCount: 32)
        let device = Device(id: Self.randomString(byteCount: 6), name: Self.cleanName(name),
                            pairedAt: Date(), tokenHash: Self.hash(token))
        devices.append(device)
        if devices.count > Self.maxDevices {
            devices.removeFirst(devices.count - Self.maxDevices)
        }
        save()
        return (device, token)
    }

    public func resume(token: String) -> Device? {
        guard !token.isEmpty else { return nil }
        let hashed = Self.hash(token)
        return devices.first { $0.tokenHash == hashed }
    }

    /// Every Safari device must scan a new QR code afterwards.
    public func forgetAll() {
        devices.removeAll()
        save()
        regenerateKey()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            store.save(data)
        }
    }

    // MARK: Helpers

    /// URL-safe base64 without padding; fits in a URL fragment and a small QR code.
    static func randomString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard !x.isEmpty, x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count {
            difference |= x[i] ^ y[i]
        }
        return difference == 0
    }

    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        return trimmed.isEmpty ? "iPad" : String(trimmed.prefix(40))
    }
}
#endif
