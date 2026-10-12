import Foundation
import Network
import PadTrackCore

/// Finds iPads advertising `_padtrack._udp` on the local network or over direct Wi‑Fi.
final class BonjourDiscovery {
    struct Service: Equatable {
        let name: String
        let endpoint: NWEndpoint
        /// From the TXT record; lets the Mac recognise an iPad it already trusts.
        let deviceID: String?
    }

    var onChange: (([Service]) -> Void)?

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PadTrackProtocol.bonjourServiceType, domain: nil),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var services: [Service] = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var deviceID: String?
                if case let .bonjour(record) = result.metadata {
                    deviceID = record[PadTrackProtocol.bonjourDeviceIDKey]
                }
                services.append(Service(name: name, endpoint: result.endpoint, deviceID: deviceID))
            }
            self?.onChange?(services)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.browser?.cancel()
                self.browser = nil
                self.onChange?([])
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }
}

/// UDP to the iPad. Each datagram is one message; losses are harmless because every
/// touch frame is a full snapshot and pings repeat.
final class UDPLink: TrackpadLink {
    var onMessage: ((Message) -> Void)?
    var onClose: ((String) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    init(endpoint: NWEndpoint, queue: DispatchQueue) {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVoice
        connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.fail("Wi‑Fi bağlantısı koptu: \(error.localizedDescription)")
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty, let message = try? Message.decode(data) {
                self.onMessage?(message)
            }
            if let error {
                self.fail("Wi‑Fi alma hatası: \(error.localizedDescription)")
            } else {
                self.receive()
            }
        }
    }

    func send(_ message: Message) {
        guard !closed else { return }
        connection.send(content: message.encoded(), completion: .idempotent)
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(reason)
    }
}
