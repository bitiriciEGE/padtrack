import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Network
import SystemConfiguration

/// Addresses the iPad can use to open this Mac's Safari page.
struct WebAddresses: Equatable {
    /// "Eges-MacBook-Air.local": survives IP changes, needs multicast DNS (some campus and
    /// guest networks block it).
    var localHostName: String?
    /// Works wherever the two devices can reach each other at all, but may change with DHCP.
    var ipv4: String?

    static func current() -> WebAddresses {
        var addresses = WebAddresses()
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            addresses.localHostName = name + ".local"
        }
        addresses.ipv4 = primaryIPv4()
        return addresses
    }

    /// The first IPv4 address of an active Wi‑Fi/Ethernet interface (en*), skipping link-local.
    private static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }
            candidates.append((name, address))
        }
        // en0 is the built-in Wi‑Fi on MacBooks.
        return candidates.sorted { $0.name < $1.name }.first?.address
    }
}

enum WebPairingLink {
    /// The key goes in the URL fragment: Safari never sends it over the network in a request,
    /// the page reads it and proves itself over the WebSocket.
    static func url(host: String, port: UInt16, key: String) -> String {
        let base = address(host: host, port: port)
        return key.isEmpty ? base : base + "/#p=" + key
    }

    static func address(host: String, port: UInt16) -> String {
        "http://\(host):\(port)"
    }
}

enum QRCodeRenderer {
    private static let context = CIContext()

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer scale keeps the modules sharp; the view draws it without interpolation.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// Re-reads the addresses whenever the network changes.
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    var onChange: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onChange?() }
        }
        monitor.start(queue: DispatchQueue(label: "padtrack.network-watcher"))
    }

    deinit {
        monitor.cancel()
    }
}
