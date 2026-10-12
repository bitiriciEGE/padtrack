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

    @Published private(set) var snapshot = CoreSnapshot()
    @Published private(set) var hasEventAccess = CGPreflightPostEventAccess()

    private let core: TrackpadCore
    private var permissionTimer: Timer?

    private enum Keys {
        static let settings = "gestureSettings"
        static let autoConnect = "autoConnect"
    }

    init() {
        let loaded = Self.loadSettings()
        let auto = UserDefaults.standard.object(forKey: Keys.autoConnect) as? Bool ?? true
        settings = loaded
        autoConnect = auto
        var initial = loaded
        initial.doubleClickInterval = NSEvent.doubleClickInterval
        core = TrackpadCore(settings: initial, autoConnect: auto)

        core.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.snapshot != snapshot else { return }
                self.snapshot = snapshot
            }
        }
        core.start()

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
