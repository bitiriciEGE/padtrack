import Foundation
import Network
import SystemConfiguration
import PadTrackCore

/// What the menu shows. Produced on the core queue, consumed on the main thread.
struct CoreSnapshot: Equatable {
    struct Device: Identifiable, Equatable {
        enum State: Equatable { case available, connecting, connected }
        let id: String
        let name: String
        let transport: LinkTransport
        let state: State
        /// False for a Wi‑Fi/Bluetooth device the user has never approved: it is listed,
        /// but the Mac will not connect to it on its own.
        let trusted: Bool
    }

    struct Connection: Equatable {
        let deviceName: String
        let transport: LinkTransport
        let latencyMs: Double?
    }

    var devices: [Device] = []
    var connection: Connection?
    var paused = false
    var note: String?
    /// The most recent gesture the engine recognised, for checking what the Mac thinks you did.
    var lastGesture: String?
}

/// Everything that touches input runs on one serial queue: link callbacks, the gesture
/// engine and event posting. No hops between threads on the hot path.
///
/// Trust model: a device that sends touches can click anything on this Mac, so the Mac
/// never connects on its own to an unknown device on Wi‑Fi or Bluetooth.
///  - USB is trusted (physical cable, and the iPad itself asked "Trust this computer?").
///  - A Wi‑Fi/Bluetooth device is trusted after the user clicked "Bağlan" for it once, or after
///    it was connected by cable once. Its persistent device ID is remembered.
final class TrackpadCore {
    var onSnapshot: ((CoreSnapshot) -> Void)?

    let queue = DispatchQueue(label: "padtrack.core", qos: .userInteractive)

    private struct Candidate {
        enum Route {
            case wifi(NWEndpoint)
            case usb(deviceID: Int)
            case bluetooth(UUID)
        }
        let id: String
        var name: String
        let transport: LinkTransport
        let route: Route
        /// Known before connecting only for Wi‑Fi (Bonjour TXT record).
        let deviceID: String?
    }

    private struct ActiveSession {
        let candidateID: String
        let transport: LinkTransport
        let link: TrackpadLink
        var hello: HelloInfo
        var lastPong: TimeInterval
        var latencyMs: Double?
    }

    private struct Probe {
        let candidateID: String
        let link: TrackpadLink
        let subscribe: Message
        let startedAt: TimeInterval
        /// The user picked this device in the menu.
        let manual: Bool
    }

    private enum Keys {
        static let trustedDevices = "trustedDeviceIDs"
        static let trustedBluetooth = "trustedBluetoothPeripherals"
    }

    private let engine: GestureEngine
    private let injector = EventInjector()
    private let hostName: String

    private var bonjour: BonjourDiscovery?
    private var usb: USBDiscovery?
    private var bluetooth: BLEDiscovery?

    private var candidates: [String: Candidate] = [:]
    private var active: ActiveSession?
    private var probe: Probe?
    private var backoffUntil: [String: TimeInterval] = [:]
    private var pinnedID: String?
    private var autoConnect = true
    private var paused = false
    private var note: String?
    private var lastGesture: String?

    private var trustedDevices: Set<String>
    private var trustedBluetooth: Set<String>

    private var housekeeping: DispatchSourceTimer?
    private var housekeepingTicks = 0
    private var momentumTimer: DispatchSourceTimer?
    private var lastMomentumTick: UInt64 = 0

    init(settings: GestureSettings, autoConnect: Bool) {
        engine = GestureEngine(settings: settings)
        self.autoConnect = autoConnect
        hostName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        let defaults = UserDefaults.standard
        trustedDevices = Set(defaults.stringArray(forKey: Keys.trustedDevices) ?? [])
        trustedBluetooth = Set(defaults.stringArray(forKey: Keys.trustedBluetooth) ?? [])
    }

    // MARK: Public API (any thread)

    func start() {
        queue.async { self.startOnQueue() }
    }

    func update(settings: GestureSettings) {
        queue.async { self.engine.settings = settings }
    }

    func setAutoConnect(_ enabled: Bool) {
        queue.async {
            self.autoConnect = enabled
            self.evaluate()
            self.publish()
        }
    }

    /// The user picked a device: connect to it and trust it from now on.
    func connect(to id: String) {
        queue.async {
            self.paused = false
            self.pinnedID = id
            if self.active?.candidateID == id { return }
            if let probe = self.probe {
                probe.link.close()
                self.probe = nil
            }
            self.backoffUntil[id] = nil
            if let candidate = self.candidates[id] { self.startProbe(candidate, manual: true) }
            self.publish()
        }
    }

    /// Disconnects and stays disconnected until the user picks a device again.
    func disconnect() {
        queue.async {
            self.paused = true
            self.pinnedID = nil
            if let probe = self.probe {
                probe.link.close()
                self.probe = nil
            }
            self.dropActive(note: nil, sendBye: true)
            self.publish()
        }
    }

    func forgetTrustedDevices() {
        queue.async {
            self.trustedDevices.removeAll()
            self.trustedBluetooth.removeAll()
            self.saveTrust()
            self.publish()
        }
    }

    // MARK: Setup

    private func startOnQueue() {
        let bonjour = BonjourDiscovery(queue: queue)
        bonjour.onChange = { [weak self] services in self?.updateWiFi(services) }
        bonjour.start()
        self.bonjour = bonjour

        let usb = USBDiscovery(queue: queue)
        usb.onChange = { [weak self] devices in self?.updateUSB(devices) }
        usb.start()
        self.usb = usb

        let bluetooth = BLEDiscovery(queue: queue)
        bluetooth.onChange = { [weak self] devices in self?.updateBluetooth(devices) }
        bluetooth.start()
        self.bluetooth = bluetooth

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.housekeep() }
        timer.resume()
        housekeeping = timer

        publish()
    }

    // MARK: Discovery

    private func updateWiFi(_ services: [BonjourDiscovery.Service]) {
        replaceCandidates(of: .wifi, with: services.map {
            Candidate(id: "wifi:\($0.name)", name: $0.name, transport: .wifi, route: .wifi($0.endpoint), deviceID: $0.deviceID)
        })
    }

    private func updateUSB(_ devices: [USBDiscovery.Device]) {
        replaceCandidates(of: .usb, with: devices.map {
            Candidate(id: "usb:\($0.deviceID)", name: "USB cihazı", transport: .usb, route: .usb(deviceID: $0.deviceID), deviceID: nil)
        })
    }

    private func updateBluetooth(_ devices: [BLEDiscovery.Device]) {
        replaceCandidates(of: .bluetooth, with: devices.map {
            Candidate(id: "ble:\($0.id.uuidString)", name: $0.name, transport: .bluetooth, route: .bluetooth($0.id), deviceID: nil)
        })
    }

    private func replaceCandidates(of transport: LinkTransport, with fresh: [Candidate]) {
        var updated = candidates.filter { $0.value.transport != transport }
        for var candidate in fresh {
            // USB and Bluetooth do not know the real device name before `hello`; keep the learned one.
            if transport != .wifi, let known = candidates[candidate.id] {
                candidate.name = known.name
            }
            updated[candidate.id] = candidate
        }
        // Never drop the device we are connected to just because discovery hiccuped.
        if let active, updated[active.candidateID] == nil, let current = candidates[active.candidateID] {
            updated[active.candidateID] = current
        }
        candidates = updated
        evaluate()
        publish()
    }

    // MARK: Trust

    private func isTrusted(_ candidate: Candidate) -> Bool {
        switch candidate.route {
        case .usb:
            return true
        case .wifi:
            guard let id = candidate.deviceID else { return false }
            return trustedDevices.contains(id)
        case .bluetooth(let peripheral):
            return trustedBluetooth.contains(peripheral.uuidString)
        }
    }

    private func remember(_ candidate: Candidate, hello: HelloInfo) {
        if !hello.deviceID.isEmpty { trustedDevices.insert(hello.deviceID) }
        if case .bluetooth(let peripheral) = candidate.route { trustedBluetooth.insert(peripheral.uuidString) }
        saveTrust()
    }

    private func saveTrust() {
        let defaults = UserDefaults.standard
        defaults.set(Array(trustedDevices), forKey: Keys.trustedDevices)
        defaults.set(Array(trustedBluetooth), forKey: Keys.trustedBluetooth)
    }

    // MARK: Connection management

    /// Decides whether to connect, or to upgrade to a faster transport (USB > Wi‑Fi > Bluetooth).
    /// Only trusted devices are connected automatically.
    private func evaluate() {
        guard probe == nil, !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let usable = candidates.values
            .filter { (backoffUntil[$0.id] ?? 0) <= now }
            .sorted { ($0.transport.priority, $0.name) < ($1.transport.priority, $1.name) }

        if let active {
            guard autoConnect, pinnedID != active.candidateID else { return }
            if let better = usable.first(where: { $0.transport.priority < active.transport.priority && isTrusted($0) }) {
                startProbe(better, manual: false)
            }
            return
        }

        if let pinnedID, let pinned = usable.first(where: { $0.id == pinnedID }) {
            startProbe(pinned, manual: true)
        } else if autoConnect, let best = usable.first(where: { isTrusted($0) }) {
            startProbe(best, manual: false)
        }
    }

    private func startProbe(_ candidate: Candidate, manual: Bool) {
        let link: TrackpadLink
        switch candidate.route {
        case .wifi(let endpoint):
            link = UDPLink(endpoint: endpoint, queue: queue)
        case .usb(let deviceID):
            link = USBLink(deviceID: deviceID, queue: queue)
        case .bluetooth(let id):
            guard let bleLink = bluetooth?.makeLink(for: id) else { return }
            link = bleLink
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handle(message, from: link)
        }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link else { return }
            self.linkClosed(link, reason: reason)
        }
        let subscribe = Message.subscribe(SubscribeInfo(transport: candidate.transport, hostName: hostName))
        probe = Probe(candidateID: candidate.id, link: link, subscribe: subscribe,
                      startedAt: ProcessInfo.processInfo.systemUptime, manual: manual)
        link.start()
        link.send(subscribe)
        publish()
    }

    private func handle(_ message: Message, from link: TrackpadLink) {
        switch message {
        case .frame(let frame):
            // Touches are only ever accepted from the one promoted (trusted) link.
            guard let active, active.link === link else { return }
            run(engine.process(frame))

        case .hello(let hello):
            if let probe, probe.link === link {
                promote(probe, hello: hello)
            } else if var session = active, session.link === link {
                session.hello = hello
                active = session
            }

        case .pong(let sentAt):
            guard var session = active, session.link === link else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= sentAt {
                // Half the round trip approximates the one-way delay of a touch.
                session.latencyMs = Double(now - sentAt) / 2_000_000
            }
            session.lastPong = ProcessInfo.processInfo.systemUptime
            active = session

        case .bye:
            if let active, active.link === link {
                dropActive(note: "iPad bağlantıyı kapattı", sendBye: false)
                evaluate()
                publish()
            } else if let probe, probe.link === link {
                failProbe(probe, note: nil)
            }

        case .ping, .subscribe:
            break
        }
    }

    private func promote(_ probe: Probe, hello: HelloInfo) {
        guard let candidate = candidates[probe.candidateID] else {
            self.probe = nil
            probe.link.send(.bye)
            probe.link.close()
            evaluate()
            publish()
            return
        }

        // Defense in depth: an automatic Wi‑Fi/Bluetooth connection must also prove, in its
        // own hello, that it is a device the user approved before.
        let trustedByHello = !hello.deviceID.isEmpty && trustedDevices.contains(hello.deviceID)
        if candidate.transport != .usb && !probe.manual && !trustedByHello {
            self.probe = nil
            probe.link.send(.bye)
            probe.link.close()
            backoffUntil[probe.candidateID] = ProcessInfo.processInfo.systemUptime + 60
            note = "Tanınmayan cihaz: bağlanmak için menüden \"Bağlan\"a tıklayın"
            publish()
            return
        }

        self.probe = nil
        if let old = active {
            old.link.send(.bye)
            old.link.close()
        }
        run(engine.reset())

        remember(candidate, hello: hello)
        if !hello.deviceName.isEmpty {
            candidates[probe.candidateID]?.name = hello.deviceName
        }
        active = ActiveSession(candidateID: probe.candidateID, transport: candidate.transport, link: probe.link,
                               hello: hello, lastPong: ProcessInfo.processInfo.systemUptime, latencyMs: nil)
        backoffUntil[probe.candidateID] = nil
        note = nil
        publish()
    }

    private func linkClosed(_ link: TrackpadLink, reason: String) {
        if let probe, probe.link === link {
            failProbe(probe, note: reason)
            return
        }
        if let active, active.link === link {
            dropActive(note: reason, sendBye: false)
            evaluate()
            publish()
        }
    }

    private func failProbe(_ probe: Probe, note: String?) {
        probe.link.close()
        self.probe = nil
        backoffUntil[probe.candidateID] = ProcessInfo.processInfo.systemUptime + 3
        // USB lists every iPhone/iPad on the cable; a refusal usually just means the app is not open there.
        if active == nil, let note { self.note = note }
        evaluate()
        publish()
    }

    private func dropActive(note: String?, sendBye: Bool) {
        guard let session = active else { return }
        if sendBye { session.link.send(.bye) }
        session.link.close()
        active = nil
        run(engine.reset())
        if let note { self.note = note }
    }

    // MARK: Timers

    private func housekeep() {
        let now = ProcessInfo.processInfo.systemUptime
        housekeepingTicks += 1

        if let probe {
            if now - probe.startedAt > 6 {
                failProbe(probe, note: "Bağlantı zaman aşımına uğradı")
            } else {
                // UDP and Bluetooth may lose the first subscribe; repeat until `hello` arrives.
                probe.link.send(probe.subscribe)
            }
        }

        if let session = active {
            session.link.send(.ping(DispatchTime.now().uptimeNanoseconds))
            if now - session.lastPong > 4 {
                dropActive(note: "iPad yanıt vermiyor", sendBye: false)
            }
        }

        if housekeepingTicks % 4 == 0 {
            bluetooth?.pruneStale(now: now)
            publish() // refresh latency
        }
        evaluate()
    }

    private func run(_ actions: [TrackpadAction]) {
        var recognised: String?
        for action in actions {
            injector.perform(action)
            if let label = Self.label(for: action) { recognised = label }
        }
        if engine.needsTick { startMomentumTimer() }
        if let recognised {
            lastGesture = recognised
            publish()
        }
    }

    /// Human-readable name of the start of a gesture; nil for continuous updates.
    private static func label(for action: TrackpadAction) -> String? {
        switch action {
        case .buttonDown(.left, let count):
            switch count {
            case 1: return "Sol tık"
            case 2: return "Çift tık"
            default: return "Üçlü tık"
            }
        case .buttonDown(.right, _): return "Sağ tık (iki parmak)"
        case .buttonDown(.middle, _): return "Orta tık (üç parmak)"
        case .scroll(_, _, .began): return "Kaydırma"
        case .magnify(_, .began): return "Yakınlaştırma"
        case .rotate(_, .began): return "Döndürme"
        case .system(.missionControl): return "Mission Control"
        case .system(.appExpose): return "Uygulama pencereleri"
        case .system(.spaceLeft): return "Soldaki masaüstü"
        case .system(.spaceRight): return "Sağdaki masaüstü"
        case .system(.lookUp): return "Sözlükte ara"
        default: return nil
        }
    }

    private func startMomentumTimer() {
        guard momentumTimer == nil else { return }
        lastMomentumTick = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.momentumStep() }
        timer.resume()
        momentumTimer = timer
    }

    private func momentumStep() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastMomentumTick) / 1_000_000_000
        lastMomentumTick = now
        for action in engine.tick(dt: dt) { injector.perform(action) }
        if !engine.needsTick {
            momentumTimer?.cancel()
            momentumTimer = nil
        }
    }

    // MARK: Snapshot

    private func publish() {
        var snapshot = CoreSnapshot()
        snapshot.devices = candidates.values
            .sorted { ($0.transport.priority, $0.name) < ($1.transport.priority, $1.name) }
            .map { candidate -> CoreSnapshot.Device in
                let state: CoreSnapshot.Device.State
                if active?.candidateID == candidate.id {
                    state = .connected
                } else if probe?.candidateID == candidate.id {
                    state = .connecting
                } else {
                    state = .available
                }
                return CoreSnapshot.Device(id: candidate.id, name: candidate.name, transport: candidate.transport,
                                           state: state, trusted: isTrusted(candidate))
            }
        if let active {
            snapshot.connection = CoreSnapshot.Connection(deviceName: active.hello.deviceName,
                                                          transport: active.transport,
                                                          latencyMs: active.latencyMs)
        }
        snapshot.paused = paused
        snapshot.note = note
        snapshot.lastGesture = lastGesture
        onSnapshot?(snapshot)
    }
}
