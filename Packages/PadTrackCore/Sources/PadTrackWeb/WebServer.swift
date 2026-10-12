#if canImport(Network) && canImport(CryptoKit)
import Foundation
import Network
import PadTrackCore

/// A static file the server hands to Safari (the touch page and its scripts).
public struct WebAsset: Sendable {
    public let data: Data
    public let contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    private static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "webmanifest": "application/manifest+json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "ico": "image/x-icon",
    ]

    /// Every servable file in `directory` becomes "/<name>"; index.html is also served at "/".
    public static func load(directory: URL) -> [String: WebAsset] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var assets: [String: WebAsset] = [:]
        for name in names where !name.hasPrefix(".") {
            let ext = (name as NSString).pathExtension.lowercased()
            guard let type = contentTypes[ext],
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            let asset = WebAsset(data: data, contentType: type)
            assets["/" + name] = asset
            if name == "index.html" { assets["/"] = asset }
        }
        return assets
    }
}

/// One authenticated Safari page. All callbacks arrive on the server's queue.
public final class WebSession {
    public let id: Int
    public let device: WebPairing.Device
    /// Binary WebSocket messages: the same PadTrack wire messages the iPad app sends.
    public var onBinary: ((Data) -> Void)?
    /// Fires at most once, when the page went away or the connection failed. Not after `close()`.
    public var onClose: ((String) -> Void)?

    weak var connection: WebConnection?

    init(id: Int, device: WebPairing.Device, connection: WebConnection) {
        self.id = id
        self.device = device
        self.connection = connection
    }

    public var isOpen: Bool { connection?.isOpen ?? false }

    public func send(_ data: Data) {
        connection?.sendBinary(data)
    }

    /// Closes the WebSocket without calling `onClose`.
    public func close() {
        connection?.close(code: WebSocketCloseCode.normal, reason: "", notify: false)
    }
}

/// Serves the touch page over HTTP and accepts WebSocket connections from it, on one port.
///
/// Requests:  GET /  (and the page's files)   → static assets
///            GET /ws + Upgrade: websocket    → WebSocket; the first message must be
///            {"type":"pair","key":…} or {"type":"resume","token":…}, otherwise it is closed.
///
/// Everything, including the callbacks, runs on `queue`.
public final class WebServer {
    public enum State: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    public var onStateChange: ((State) -> Void)?
    /// Authenticated, open sessions. Delivered asynchronously, never re-entrantly.
    public var onSessionsChange: (([WebSession]) -> Void)?
    /// A QR code was used (the pairing key changed) or the device list changed.
    public var onPairingChange: (() -> Void)?

    public private(set) var state: State = .stopped
    /// Shown on the page before the Mac picks it ("Connected to …").
    public var hostName: String

    public let pairing: WebPairing

    static let maxConnections = 16
    static let headTimeout: TimeInterval = 10
    static let authTimeout: TimeInterval = 10

    private let queue: DispatchQueue
    private let requestedPort: UInt16
    private let assets: [String: WebAsset]
    private var listener: NWListener?
    private var connections: [Int: WebConnection] = [:]
    private var nextID = 1
    private var restart: DispatchWorkItem?
    private var notifyPending = false

    /// `port` 0 picks any free port (tests).
    public init(queue: DispatchQueue, port: UInt16, assets: [String: WebAsset], pairing: WebPairing, hostName: String) {
        self.queue = queue
        self.requestedPort = port
        self.assets = assets
        self.pairing = pairing
        self.hostName = hostName
    }

    public var sessions: [WebSession] {
        connections.values.compactMap { $0.isOpen ? $0.session : nil }.sorted { $0.id < $1.id }
    }

    // MARK: Lifecycle (call on `queue`)

    public func start() {
        guard listener == nil else { return }
        restart?.cancel()
        restart = nil

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVoice

        let port: NWEndpoint.Port = requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort) ?? .any
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            fail(Self.describe(error))
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.setState(.listening(port: listener.port?.rawValue ?? self.requestedPort))
            case .failed(let error):
                self.fail(Self.describe(error))
            case .waiting(let error):
                self.setState(.failed(Self.describe(error)))
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        restart?.cancel()
        restart = nil
        listener?.cancel()
        listener = nil
        for connection in Array(connections.values) {
            connection.close(code: WebSocketCloseCode.goingAway, reason: "server stopped", notify: true)
        }
        connections.removeAll()
        setState(.stopped)
        scheduleSessionNotification()
    }

    /// Also disconnects every Safari page that is currently open.
    public func forgetAllDevices() {
        pairing.forgetAll()
        for connection in Array(connections.values) where connection.session != nil {
            connection.close(code: WebSocketCloseCode.unauthorized, reason: "forgotten", notify: true)
        }
        onPairingChange?()
    }

    public func regeneratePairingKey() {
        pairing.regenerateKey()
        onPairingChange?()
    }

    private func fail(_ reason: String) {
        listener?.cancel()
        listener = nil
        setState(.failed(reason))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.listener == nil, self.restart != nil else { return }
            self.restart = nil
            self.start()
        }
        restart = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? NWError, case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(PadTrackProtocol.webPort) başka bir uygulama tarafından kullanılıyor"
        }
        return "Web sunucusu başlatılamadı: \(error.localizedDescription)"
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = nextID
        nextID += 1
        let webConnection = WebConnection(id: id, connection: connection, server: self, queue: queue)
        connections[id] = webConnection
        webConnection.start()
    }

    func asset(for path: String) -> WebAsset? {
        assets[path]
    }

    struct Grant {
        let device: WebPairing.Device
        /// Only after pairing: the page stores it and uses it from then on.
        let newToken: String?
    }

    func authenticate(type: String, secret: String, name: String) -> Grant? {
        switch type {
        case "pair":
            guard let result = pairing.pair(key: secret, name: name) else { return nil }
            onPairingChange?()
            return Grant(device: result.device, newToken: result.token)
        case "resume":
            guard let device = pairing.resume(token: secret) else { return nil }
            return Grant(device: device, newToken: nil)
        default:
            return nil
        }
    }

    func makeSession(device: WebPairing.Device, connection: WebConnection) -> WebSession {
        WebSession(id: connection.id, device: device, connection: connection)
    }

    func sessionsChanged() {
        scheduleSessionNotification()
    }

    func connectionEnded(_ connection: WebConnection) {
        guard connections[connection.id] === connection else { return }
        connections[connection.id] = nil
        if connection.session != nil { scheduleSessionNotification() }
    }

    private func scheduleSessionNotification() {
        guard !notifyPending else { return }
        notifyPending = true
        queue.async { [weak self] in
            guard let self else { return }
            self.notifyPending = false
            self.onSessionsChange?(self.sessions)
        }
    }
}

/// One TCP connection: an HTTP request, possibly upgraded to a WebSocket.
final class WebConnection {
    private enum Phase {
        case http
        case webSocket
        case closed
    }

    let id: Int
    private(set) var session: WebSession?

    private let connection: NWConnection
    private weak var server: WebServer?
    private let queue: DispatchQueue
    private var phase = Phase.http
    private var head: [UInt8] = []
    private var decoder = WebSocketDecoder(maxMessageSize: 16 * 1024)
    private var timeout: DispatchWorkItem?

    init(id: Int, connection: NWConnection, server: WebServer, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    var isOpen: Bool { phase == .webSocket }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finish(reason: "Safari bağlantısı koptu: \(error.localizedDescription)", notify: true)
            }
        }
        connection.start(queue: queue)
        arm(WebServer.headTimeout)
        receive()
    }

    // MARK: Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.phase != .closed else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            guard self.phase != .closed else { return }
            if isComplete || error != nil {
                self.finish(reason: "Safari bağlantıyı kapattı", notify: true)
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        switch phase {
        case .http:
            head.append(contentsOf: data)
            switch HTTPRequestParser.parse(head) {
            case .incomplete:
                return
            case .invalid:
                respond(status: 400, reason: "Bad Request")
            case .complete(let request, let consumed):
                let leftover = Data(head[consumed...])
                head = []
                route(request, leftover: leftover)
            }
        case .webSocket:
            do {
                for message in try decoder.push(data) {
                    handle(message)
                    if phase == .closed { return }
                }
            } catch let error as WebSocketProtocolError {
                close(code: error.closeCode, reason: error.reason, notify: true)
            } catch {
                close(code: WebSocketCloseCode.protocolError, reason: "", notify: true)
            }
        case .closed:
            return
        }
    }

    // MARK: HTTP

    private func route(_ request: HTTPRequest, leftover: Data) {
        if request.path == "/ws" {
            guard let response = WebSocketHandshake.response(for: request) else {
                respond(status: 400, reason: "Bad Request")
                return
            }
            // Browsers always send Origin. A page from another site must not even try keys.
            if let origin = request.header("origin"), !Self.isSameOrigin(origin, host: request.header("host")) {
                respond(status: 403, reason: "Forbidden")
                return
            }
            phase = .webSocket
            connection.send(content: response, completion: .contentProcessed { _ in })
            arm(WebServer.authTimeout)
            if !leftover.isEmpty { consume(leftover) }
            return
        }

        guard request.method == "GET" else {
            respond(status: 405, reason: "Method Not Allowed")
            return
        }
        guard let asset = server?.asset(for: request.path) else {
            respond(status: 404, reason: "Not Found")
            return
        }
        let headers = [
            ("Content-Type", asset.contentType),
            ("Cache-Control", "no-cache"),
            ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "no-referrer"),
        ]
        sendAndClose(HTTPResponse.make(status: 200, reason: "OK", headers: headers, body: asset.data))
    }

    private func respond(status: Int, reason: String) {
        let body = Data("\(status) \(reason)\n".utf8)
        sendAndClose(HTTPResponse.make(status: status, reason: reason,
                                       headers: [("Content-Type", "text/plain; charset=utf-8")], body: body))
    }

    private func sendAndClose(_ data: Data) {
        let connection = self.connection
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
        finish(reason: "", notify: false, cancelNow: false)
    }

    static func isSameOrigin(_ origin: String, host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let lowered = origin.lowercased()
        for scheme in ["http://", "https://"] where lowered.hasPrefix(scheme) {
            return String(lowered.dropFirst(scheme.count)) == host.lowercased()
        }
        return false
    }

    // MARK: WebSocket

    private func handle(_ message: WebSocketMessage) {
        switch message {
        case .ping(let payload):
            send(frame: WebSocketFrame.encode(.pong(payload)))
        case .pong:
            break
        case .close(let code, _):
            close(code: code ?? WebSocketCloseCode.normal, reason: "", notify: true,
                  closeReason: "Safari sayfası kapandı")
        case .text(let text):
            if session == nil { authenticate(text) }
        case .binary(let data):
            guard let session else {
                close(code: WebSocketCloseCode.policyViolation, reason: "not authenticated", notify: false)
                return
            }
            session.onBinary?(data)
        }
    }

    private func authenticate(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String else {
            deny("bad-request")
            return
        }
        let secret = (object["key"] as? String) ?? (object["token"] as? String) ?? ""
        let name = (object["name"] as? String) ?? "iPad"
        guard let server, let grant = server.authenticate(type: type, secret: secret, name: name) else {
            deny(type == "pair" ? "pair-key" : "token")
            return
        }
        timeout?.cancel()
        timeout = nil
        let session = server.makeSession(device: grant.device, connection: self)
        self.session = session

        var welcome: [String: Any] = ["type": "welcome", "device": grant.device.id, "host": server.hostName]
        if let token = grant.newToken { welcome["token"] = token }
        sendText(welcome)
        server.sessionsChanged()
    }

    private func deny(_ reason: String) {
        sendText(["type": "denied", "reason": reason])
        close(code: WebSocketCloseCode.unauthorized, reason: reason, notify: false)
    }

    private func sendText(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        send(frame: WebSocketFrame.encode(.text(text)))
    }

    func sendBinary(_ data: Data) {
        guard phase == .webSocket, session != nil else { return }
        send(frame: WebSocketFrame.encode(.binary, payload: data))
    }

    private func send(frame: Data) {
        guard phase == .webSocket else { return }
        connection.send(content: frame, completion: .idempotent)
    }

    // MARK: Closing

    /// Sends a close frame (when the WebSocket is up), then tears the connection down.
    func close(code: UInt16, reason: String, notify: Bool, closeReason: String = "Safari bağlantısı kapandı") {
        guard phase != .closed else { return }
        if phase == .webSocket {
            let connection = self.connection
            connection.send(content: WebSocketFrame.encode(.close(code: code, reason: reason)),
                            completion: .contentProcessed { _ in connection.cancel() })
            finish(reason: closeReason, notify: notify, cancelNow: false)
        } else {
            finish(reason: closeReason, notify: notify)
        }
    }

    private func finish(reason: String, notify: Bool, cancelNow: Bool = true) {
        guard phase != .closed else { return }
        phase = .closed
        timeout?.cancel()
        timeout = nil
        let connection = self.connection
        if cancelNow {
            connection.cancel()
        } else {
            // In case the final send never completes.
            queue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
        }
        server?.connectionEnded(self)
        if let session {
            let callback = session.onClose
            session.onBinary = nil
            session.onClose = nil
            if notify { callback?(reason) }
        }
    }

    private func arm(_ seconds: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .http:
                self.finish(reason: "", notify: false)
            case .webSocket where self.session == nil:
                self.close(code: WebSocketCloseCode.unauthorized, reason: "timeout", notify: false)
            default:
                break
            }
        }
        timeout = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
#endif
