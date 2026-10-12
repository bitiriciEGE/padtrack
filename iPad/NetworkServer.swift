import Foundation
import Network
import PadTrackCore

/// Two listeners:
///  - UDP + Bonjour for Wi‑Fi. `includePeerToPeer` also allows Apple's direct Wi‑Fi (AWDL),
///    so the iPad and the Mac do not even need to share a router.
///  - TCP on a fixed port for the USB cable. The Mac reaches it through usbmuxd, the same
///    tunnel Xcode and Finder use, so no network is involved at all.
/// All callbacks run on the queue given at init.
final class NetworkServer {
    var onMessage: ((Message, PeerLink) -> Void)?
    var onClose: ((PeerLink) -> Void)?
    /// (wifi status, usb status); nil leaves a value unchanged.
    var onStatus: ((String?, String?) -> Void)?

    private(set) var isHealthy = true

    private let queue: DispatchQueue
    private let deviceName: String
    private let deviceID: String
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var links: [ObjectIdentifier: PeerLink] = [:]
    private var janitor: DispatchSourceTimer?

    init(queue: DispatchQueue, deviceName: String, deviceID: String) {
        self.queue = queue
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    func start() {
        startUDP()
        startTCP()
        startJanitor()
    }

    func stop() {
        udpListener?.cancel()
        tcpListener?.cancel()
        janitor?.cancel()
        janitor = nil
        for link in links.values { link.close() }
        links.removeAll()
    }

    // MARK: UDP (Wi‑Fi)

    private func startUDP() {
        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            parameters.serviceClass = .interactiveVoice
            let listener = try NWListener(using: parameters)
            // The device ID travels in the TXT record so the Mac can recognise an approved iPad
            // before connecting to it.
            var txt = NWTXTRecord()
            txt[PadTrackProtocol.bonjourDeviceIDKey] = deviceID
            listener.service = NWListener.Service(name: deviceName, type: PadTrackProtocol.bonjourServiceType,
                                                  domain: nil, txtRecord: txt.data)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus?("Hazır (aynı ağ veya doğrudan Wi‑Fi)", nil)
                case .waiting(let error):
                    self?.onStatus?("Bekliyor: \(error.localizedDescription)", nil)
                case .failed(let error):
                    self?.isHealthy = false
                    self?.onStatus?("Hata: \(error.localizedDescription)", nil)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptDatagrams(connection)
            }
            listener.start(queue: queue)
            udpListener = listener
        } catch {
            isHealthy = false
            onStatus?("Başlatılamadı: \(error.localizedDescription)", nil)
        }
    }

    private func acceptDatagrams(_ connection: NWConnection) {
        let link = UDPPeerLink(connection: connection)
        register(link, connection: connection)
        connection.start(queue: queue)
        receiveDatagram(on: connection, link: link)
    }

    private func receiveDatagram(on connection: NWConnection, link: UDPPeerLink) {
        connection.receiveMessage { [weak self, weak link] data, _, _, error in
            guard let self, let link else { return }
            if let data, !data.isEmpty, let message = try? Message.decode(data) {
                link.lastActivity = ProcessInfo.processInfo.systemUptime
                self.onMessage?(message, link)
            }
            if error == nil {
                self.receiveDatagram(on: connection, link: link)
            }
        }
    }

    // MARK: TCP (USB via usbmuxd)

    private func startTCP() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: PadTrackProtocol.usbPort) else { return }
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus?(nil, "Hazır (kabloyu takmak yeterli)")
                case .failed(let error):
                    self?.isHealthy = false
                    self?.onStatus?(nil, "Hata: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptStream(connection)
            }
            listener.start(queue: queue)
            tcpListener = listener
        } catch {
            isHealthy = false
            onStatus?(nil, "Başlatılamadı: \(error.localizedDescription)")
        }
    }

    private func acceptStream(_ connection: NWConnection) {
        let link = TCPPeerLink(connection: connection)
        register(link, connection: connection)
        connection.start(queue: queue)
        receiveStream(on: connection, link: link)
    }

    private func receiveStream(on connection: NWConnection, link: TCPPeerLink) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak link] data, _, isComplete, error in
            guard let self, let link else { return }
            if let data, !data.isEmpty {
                for payload in link.deframer.push(data) {
                    if let message = try? Message.decode(payload) { self.onMessage?(message, link) }
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveStream(on: connection, link: link)
            }
        }
    }

    // MARK: Bookkeeping

    private func register(_ link: PeerLink, connection: NWConnection) {
        let key = ObjectIdentifier(link)
        links[key] = link
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .failed, .cancelled:
                if self.links.removeValue(forKey: key) != nil {
                    self.onClose?(link)
                }
            default:
                break
            }
        }
    }

    /// UDP has no "connection closed"; forget peers that went quiet (the active Mac pings constantly).
    private func startJanitor() {
        guard janitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for link in self.links.values {
                if let udp = link as? UDPPeerLink, now - udp.lastActivity > 10 {
                    udp.close()
                }
            }
        }
        timer.resume()
        janitor = timer
    }
}

final class UDPPeerLink: PeerLink {
    let connection: NWConnection
    var lastActivity = ProcessInfo.processInfo.systemUptime

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ payload: Data, structural: Bool) {
        // Every frame is a complete snapshot, so a lost datagram is simply superseded.
        connection.send(content: payload, completion: .idempotent)
    }

    func close() {
        connection.cancel()
    }
}

final class TCPPeerLink: PeerLink {
    let connection: NWConnection
    var deframer = StreamDeframer()

    private var inFlight = 0
    private var pendingMove: Data?
    private let maxInFlight = 6

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ payload: Data, structural: Bool) {
        if structural {
            // A newer full snapshot makes any waiting move frame obsolete.
            pendingMove = nil
        } else if inFlight >= maxInFlight {
            pendingMove = payload
            return
        }
        write(payload)
    }

    private func write(_ payload: Data) {
        inFlight += 1
        connection.send(content: StreamFraming.frame(payload), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.inFlight -= 1
            if self.inFlight < self.maxInFlight, let next = self.pendingMove {
                self.pendingMove = nil
                self.write(next)
            }
        })
    }

    func close() {
        connection.cancel()
    }
}
