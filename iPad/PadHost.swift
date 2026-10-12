import Foundation
import UIKit
import PadTrackCore

/// A connection to one Mac, whatever carries it (UDP, TCP over USB, Bluetooth).
/// All methods are called on `PadHost.queue`.
protocol PeerLink: AnyObject {
    /// `structural` frames (finger landed/lifted, hello, pong) must not be dropped;
    /// plain move frames may be replaced by a newer one when the link is congested.
    func send(_ payload: Data, structural: Bool)
    func close()
}

/// Owns the transports and forwards touch frames to whichever Mac subscribed last.
final class PadHost: ObservableObject {
    @Published private(set) var statusText = "Mac bekleniyor…"
    @Published private(set) var isConnected = false
    @Published private(set) var wifiStatus = "Başlatılıyor…"
    @Published private(set) var usbStatus = "Başlatılıyor…"
    @Published private(set) var bluetoothStatus = "Kapalı"

    @Published var showTouches: Bool {
        didSet { UserDefaults.standard.set(showTouches, forKey: Keys.showTouches) }
    }

    @Published var bluetoothEnabled: Bool {
        didSet {
            UserDefaults.standard.set(bluetoothEnabled, forKey: Keys.bluetooth)
            let enabled = bluetoothEnabled
            queue.async { self.setBluetooth(enabled) }
        }
    }

    let queue = DispatchQueue(label: "padtrack.host", qos: .userInteractive)

    private enum Keys {
        static let showTouches = "showTouches"
        static let bluetooth = "bluetoothEnabled"
        static let deviceID = "deviceID"
    }

    private let deviceName: String
    /// Persistent random ID; the Mac uses it to remember that the user approved this iPad.
    private let deviceID: String

    // Everything below is confined to `queue`.
    private var network: NetworkServer?
    private var bluetooth: BLEPeripheral?
    private var activeLink: PeerLink?
    private var activeTransport: LinkTransport = .wifi
    private var activePeerName = ""
    private var lastHeard: TimeInterval = 0
    private var seq: UInt32 = 0
    private var surface = CGSize(width: 1024, height: 768)
    private var fingersDown = false
    private var watchdog: DispatchSourceTimer?

    init() {
        let defaults = UserDefaults.standard
        showTouches = defaults.object(forKey: Keys.showTouches) as? Bool ?? true
        bluetoothEnabled = defaults.object(forKey: Keys.bluetooth) as? Bool ?? true
        deviceName = UIDevice.current.name
        if let saved = defaults.string(forKey: Keys.deviceID) {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
    }

    // MARK: Lifecycle

    /// Safe to call repeatedly (e.g. every time the app becomes active): only restarts what died.
    func start() {
        let bluetoothWanted = bluetoothEnabled
        queue.async {
            if self.network?.isHealthy != true {
                self.network?.stop()
                let server = NetworkServer(queue: self.queue, deviceName: self.deviceName, deviceID: self.deviceID)
                server.onMessage = { [weak self] message, link in self?.handle(message, from: link) }
                server.onClose = { [weak self] link in self?.linkClosed(link) }
                server.onStatus = { [weak self] wifi, usb in
                    DispatchQueue.main.async {
                        if let wifi { self?.wifiStatus = wifi }
                        if let usb { self?.usbStatus = usb }
                    }
                }
                self.network = server
                server.start()
            }
            self.setBluetooth(bluetoothWanted)
            self.startWatchdog()
        }
    }

    private func setBluetooth(_ enabled: Bool) {
        if enabled, bluetooth == nil {
            let peripheral = BLEPeripheral(queue: queue, localName: "PadTrack")
            peripheral.onMessage = { [weak self] message, link in self?.handle(message, from: link) }
            peripheral.onClose = { [weak self] link in self?.linkClosed(link) }
            peripheral.onStatus = { [weak self] text in
                DispatchQueue.main.async { self?.bluetoothStatus = text }
            }
            bluetooth = peripheral
        } else if !enabled, let peripheral = bluetooth {
            peripheral.stop()
            bluetooth = nil
            DispatchQueue.main.async { self.bluetoothStatus = "Kapalı" }
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        timer.resume()
        watchdog = timer
    }

    /// The Mac pings twice a second; silence means it went away without saying goodbye.
    private func checkLiveness() {
        guard let link = activeLink else { return }
        if ProcessInfo.processInfo.systemUptime - lastHeard > 5 {
            link.close()
            deactivate()
        }
    }

    // MARK: Messages from the Mac

    private func handle(_ message: Message, from link: PeerLink) {
        if link === activeLink { lastHeard = ProcessInfo.processInfo.systemUptime }
        switch message {
        case .subscribe(let info):
            activate(link, transport: info.transport, peerName: info.hostName)
            sendHello(to: link)
        case .ping(let value):
            link.send(Message.pong(value).encoded(), structural: true)
        case .bye:
            if link === activeLink { deactivate() }
            link.close()
        case .hello, .frame, .pong:
            break
        }
    }

    private func activate(_ link: PeerLink, transport: LinkTransport, peerName: String) {
        if let old = activeLink, old !== link {
            // A newer subscription wins (e.g. the cable was plugged in while on Wi‑Fi).
            old.send(Message.bye.encoded(), structural: true)
            old.close()
        }
        activeLink = link
        activeTransport = transport
        activePeerName = peerName.isEmpty ? "Mac" : peerName
        lastHeard = ProcessInfo.processInfo.systemUptime
        publish()
    }

    private func deactivate() {
        activeLink = nil
        publish()
    }

    private func linkClosed(_ link: PeerLink) {
        if link === activeLink { deactivate() }
    }

    private func sendHello(to link: PeerLink) {
        let hello = HelloInfo(deviceName: deviceName, deviceID: deviceID,
                              surfaceWidth: Float(surface.width), surfaceHeight: Float(surface.height))
        link.send(Message.hello(hello).encoded(), structural: true)
    }

    private func publish() {
        let connected = activeLink != nil
        let text = connected ? "\(activePeerName) · \(activeTransport.displayName)" : "Mac bekleniyor…"
        DispatchQueue.main.async {
            self.isConnected = connected
            self.statusText = text
        }
    }

    // MARK: Touches (called on the main thread by TouchSurfaceView)

    func handleTouches(_ touches: [TouchPoint], timestamp: TimeInterval, structural: Bool) {
        queue.async {
            self.sendFrame(touches, timestamp: timestamp, structural: structural)
            guard touches.isEmpty else { return }
            // UDP may drop a datagram. Repeat "all fingers up" so a release is never missed;
            // the Mac ignores the copies once it has seen one.
            for delay in [0.012, 0.035] {
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.fingersDown else { return }
                    self.sendFrame([], timestamp: timestamp, structural: true)
                }
            }
        }
    }

    func updateSurfaceSize(_ size: CGSize) {
        queue.async {
            self.surface = size
            if let link = self.activeLink { self.sendHello(to: link) }
        }
    }

    private func sendFrame(_ touches: [TouchPoint], timestamp: TimeInterval, structural: Bool) {
        fingersDown = !touches.isEmpty
        guard let link = activeLink else { return }
        seq &+= 1
        let frame = TouchFrame(seq: seq, timestamp: timestamp, touches: touches)
        link.send(Message.frame(frame).encoded(), structural: structural)
    }
}
