import AppKit
import Foundation
import PadTrackCore

/// Main-thread model behind the menu bar UI.
final class AppController: ObservableObject {
    @Published var settings: GestureSettings {
        didSet {
            Self.save(settings)
            core.update(settings: effectiveSettings)
        }
    }

    @Published var autoConnect: Bool {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: Keys.autoConnect)
            core.setAutoConnect(autoConnect)
        }
    }

    /// Serve the touch page so an iPad can connect from Safari (no iPad app needed).
    @Published var webEnabled: Bool {
        didSet {
            UserDefaults.standard.set(webEnabled, forKey: Keys.webEnabled)
            core.setWebEnabled(webEnabled)
        }
    }

    /// The QR code points at the IP address instead of "name.local" (for networks without mDNS).
    @Published var qrUsesIP: Bool {
        didSet {
            UserDefaults.standard.set(qrUsesIP, forKey: Keys.qrUsesIP)
            refreshQRCode()
        }
    }

    @Published private(set) var snapshot = CoreSnapshot() {
        didSet {
            if snapshot.web != oldValue.web { refreshQRCode() }
        }
    }
    @Published private(set) var hasEventAccess = CGPreflightPostEventAccess()
    @Published private(set) var webAddresses = WebAddresses.current()
    @Published private(set) var qrImage: NSImage?

    private let core: TrackpadCore
    private var permissionTimer: Timer?
    private let networkWatcher = NetworkWatcher()

    private enum Keys {
        static let settings = "gestureSettings"
        static let autoConnect = "autoConnect"
        static let webEnabled = "webClientEnabled"
        static let qrUsesIP = "webQRUsesIP"
    }

    init() {
        let loaded = Self.loadSettings()
        let defaults = UserDefaults.standard
        let auto = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        let web = defaults.object(forKey: Keys.webEnabled) as? Bool ?? true
        settings = loaded
        autoConnect = auto
        webEnabled = web
        qrUsesIP = defaults.bool(forKey: Keys.qrUsesIP)
        var initial = loaded
        initial.doubleClickInterval = NSEvent.doubleClickInterval
        core = TrackpadCore(settings: initial, autoConnect: auto, webEnabled: web)

        core.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.snapshot != snapshot else { return }
                self.snapshot = snapshot
            }
        }
        core.start()

        networkWatcher.onChange = { [weak self] in self?.refreshAddresses() }
        networkWatcher.start()

        if !hasEventAccess {
            // Shows the system prompt that leads to Privacy & Security › Accessibility.
            CGRequestPostEventAccess()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = CGPreflightPostEventAccess()
            if granted != self.hasEventAccess { self.hasEventAccess = granted }
        }
    }

    // MARK: Derived state

    var isConnected: Bool { snapshot.connection != nil }

    var statusLine: String {
        if let connection = snapshot.connection {
            var parts = [connection.deviceName, connection.transport.displayName]
            if let latency = connection.latencyMs {
                parts.append(String(format: "~%.0f ms", max(latency, 1)))
            }
            return parts.joined(separator: " · ")
        }
        if snapshot.paused { return "Bağlantı kesildi. Bir cihaz seçin." }
        if let note = snapshot.note { return note }
        return "iPad bekleniyor…"
    }

    private var effectiveSettings: GestureSettings {
        var s = settings
        s.doubleClickInterval = NSEvent.doubleClickInterval
        return s
    }

    // MARK: Actions

    func connect(_ id: String) { core.connect(to: id) }
    func disconnect() { core.disconnect() }

    func resetSettings() { settings = GestureSettings() }
    func forgetTrustedDevices() { core.forgetTrustedDevices() }

    // MARK: Safari client

    /// The host the QR code points at; nil when there is no usable network address.
    var webHost: String? {
        qrUsesIP ? webAddresses.ipv4 : (webAddresses.localHostName ?? webAddresses.ipv4)
    }

    var webPort: UInt16? {
        if case .listening(let port) = snapshot.web.server { return port }
        return nil
    }

    /// Address without the key, to show in the menu.
    var webAddressText: String? {
        guard let host = webHost, let port = webPort else { return nil }
        return WebPairingLink.address(host: host, port: port)
    }

    /// Full one-time pairing link (what the QR code holds).
    var pairingLink: String? {
        guard let host = webHost, let port = webPort else { return nil }
        return WebPairingLink.url(host: host, port: port, key: snapshot.web.pairingKey)
    }

    /// With Universal Clipboard the link can be pasted straight into Safari on the iPad.
    func copyPairingLink() {
        guard let link = pairingLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func newPairingCode() { core.regenerateWebPairingKey() }

    func refreshAddresses() {
        let current = WebAddresses.current()
        if current != webAddresses {
            webAddresses = current
            refreshQRCode()
        }
    }

    private func refreshQRCode() {
        qrImage = pairingLink.flatMap(QRCodeRenderer.image(for:))
    }

    func openAccessibilitySettings() {
        CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Persistence

    private static func loadSettings() -> GestureSettings {
        guard let data = UserDefaults.standard.data(forKey: Keys.settings),
              let settings = try? JSONDecoder().decode(GestureSettings.self, from: data) else {
            return GestureSettings()
        }
        return settings
    }

    private static func save(_ settings: GestureSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
    }
}
