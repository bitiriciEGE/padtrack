#if canImport(Network) && canImport(CryptoKit)
import Foundation
import PadTrackCore
@testable import PadTrackWeb
import XCTest

final class WebPairingTests: XCTestCase {
    func testKeyWorksOnceAndTokenResumes() throws {
        let store = InMemoryPairingStore()
        let pairing = WebPairing(store: store)
        let key = pairing.pairingKey
        XCTAssertGreaterThanOrEqual(key.count, 21)

        XCTAssertNil(pairing.pair(key: "wrong", name: "iPad"))
        XCTAssertNil(pairing.pair(key: "", name: "iPad"))
        let result = try XCTUnwrap(pairing.pair(key: key, name: "  Ege'nin iPad'i\n "))
        XCTAssertEqual(result.device.name, "Ege'nin iPad'i")
        XCTAssertNotEqual(pairing.pairingKey, key, "a used key must be replaced")
        XCTAssertNil(pairing.pair(key: key, name: "iPad"), "a used key must not work twice")

        XCTAssertEqual(pairing.resume(token: result.token)?.id, result.device.id)
        XCTAssertNil(pairing.resume(token: result.token + "x"))
        XCTAssertNil(pairing.resume(token: ""))

        // Survives a restart, and the token itself is not stored.
        let reloaded = WebPairing(store: store)
        XCTAssertEqual(reloaded.resume(token: result.token)?.id, result.device.id)
        XCTAssertFalse(String(decoding: try XCTUnwrap(store.data), as: UTF8.self).contains(result.token))

        reloaded.forgetAll()
        XCTAssertNil(reloaded.resume(token: result.token))
        XCTAssertNil(WebPairing(store: store).resume(token: result.token))
    }

    func testOriginCheck() {
        XCTAssertTrue(WebConnection.isSameOrigin("http://eges-macbook-air.local:47391", host: "Eges-MacBook-Air.local:47391"))
        XCTAssertTrue(WebConnection.isSameOrigin("http://192.168.1.20:47391", host: "192.168.1.20:47391"))
        XCTAssertFalse(WebConnection.isSameOrigin("https://evil.example", host: "192.168.1.20:47391"))
        XCTAssertFalse(WebConnection.isSameOrigin("null", host: "192.168.1.20:47391"))
        XCTAssertFalse(WebConnection.isSameOrigin("http://192.168.1.20:47391", host: nil))
    }
}

/// Runs the real server on a free port and talks to it with URLSession, i.e. Apple's own
/// HTTP and WebSocket client (the same network stack Safari uses).
final class WebServerTests: XCTestCase {
    private let queue = DispatchQueue(label: "padtrack.web.tests")
    private var server: WebServer!
    private var pairing: WebPairing!
    private var port: UInt16 = 0
    private var sessionsChanged: XCTestExpectation?
    private let page = Data("<!doctype html><title>PadTrack</title>".utf8)

    override func setUp() {
        super.setUp()
        pairing = WebPairing(store: InMemoryPairingStore())
        let html = WebAsset(data: page, contentType: "text/html; charset=utf-8")
        server = WebServer(queue: queue, port: 0, assets: ["/": html, "/index.html": html],
                           pairing: pairing, hostName: "Test Mac")

        let ready = expectation(description: "listening")
        ready.assertForOverFulfill = false
        server.onStateChange = { [weak self] state in
            if case .listening(let port) = state {
                self?.port = port
                ready.fulfill()
            }
        }
        server.onSessionsChange = { [weak self] _ in
            self?.sessionsChanged?.fulfill()
        }
        queue.sync { server.start() }
        wait(for: [ready], timeout: 5)
        XCTAssertNotEqual(port, 0)
    }

    override func tearDown() {
        queue.sync { server.stop() }
        server = nil
        super.tearDown()
    }

    func testServesPageAndRejectsUnknownPaths() throws {
        let (body, response) = try fetch("/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(body, page)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")

        XCTAssertEqual(try fetch("/index.html").1.statusCode, 200)
        XCTAssertEqual(try fetch("/../etc/passwd").1.statusCode, 404)
        XCTAssertEqual(try fetch("/ws").1.statusCode, 400, "plain GET on the socket path")
    }

    func testPairingFlowAndBinaryRoundTrip() throws {
        let key = queue.sync { pairing.pairingKey }

        // Wrong key: denied, then closed.
        let stranger = socket()
        try send(stranger, text: #"{"type":"pair","key":"not-the-key","name":"x"}"#)
        XCTAssertEqual(try receiveJSON(stranger)["type"] as? String, "denied")
        XCTAssertThrowsError(try receive(stranger), "server must close after denying")

        // Right key: welcome with a device token.
        sessionsChanged = expectSessionsChange()
        let paired = socket()
        try send(paired, text: #"{"type":"pair","key":"\#(key)","name":"Test iPad"}"#)
        let welcome = try receiveJSON(paired)
        XCTAssertEqual(welcome["type"] as? String, "welcome")
        XCTAssertEqual(welcome["host"] as? String, "Test Mac")
        let token = try XCTUnwrap(welcome["token"] as? String)
        wait(for: [sessionsChanged!], timeout: 5)
        let session = try XCTUnwrap(queue.sync { server.sessions.first })
        XCTAssertEqual(session.device.name, "Test iPad")
        XCTAssertNotEqual(queue.sync { pairing.pairingKey }, key)

        // Mac -> page.
        let subscribe = Message.subscribe(SubscribeInfo(transport: .web, hostName: "Test Mac")).encoded()
        queue.sync { session.send(subscribe) }
        guard case .data(let received) = try receive(paired) else { return XCTFail("expected binary") }
        XCTAssertEqual(received, subscribe)

        // Page -> Mac.
        let gotFrame = expectation(description: "frame reaches the session")
        let frame = Message.frame(TouchFrame(seq: 1, timestamp: 2, touches: [TouchPoint(id: 0, x: 3, y: 4)])).encoded()
        queue.sync {
            session.onBinary = { data in
                XCTAssertEqual(data, frame)
                gotFrame.fulfill()
            }
        }
        try send(paired, data: frame)
        wait(for: [gotFrame], timeout: 5)

        // The used key no longer works.
        let replay = socket()
        try send(replay, text: #"{"type":"pair","key":"\#(key)","name":"x"}"#)
        XCTAssertEqual(try receiveJSON(replay)["type"] as? String, "denied")

        // The token does.
        let returning = socket()
        try send(returning, text: #"{"type":"resume","token":"\#(token)","name":"Test iPad"}"#)
        let again = try receiveJSON(returning)
        XCTAssertEqual(again["type"] as? String, "welcome")
        XCTAssertNil(again["token"])

        // Closing from the Mac side does not report a close back.
        let closed = expectation(description: "page sees the close")
        queue.sync {
            session.onClose = { _ in XCTFail("close() must be silent") }
            session.close()
        }
        paired.receive { result in
            if case .failure = result { closed.fulfill() }
        }
        wait(for: [closed], timeout: 5)

        // Page going away is reported.
        let reported = expectation(description: "remote close reported")
        let other = try XCTUnwrap(queue.sync { server.sessions.first { $0.id != session.id } })
        queue.sync { other.onClose = { _ in reported.fulfill() } }
        returning.cancel(with: .goingAway, reason: nil)
        wait(for: [reported], timeout: 5)
    }

    func testBinaryBeforeAuthenticationIsRefused() throws {
        let task = socket()
        try send(task, data: Message.bye.encoded())
        XCTAssertThrowsError(try receive(task))
        XCTAssertTrue(queue.sync { server.sessions.isEmpty })
    }

    func testOtherSitesCannotConnect() throws {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        request.setValue("http://evil.example", forHTTPHeaderField: "Origin")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        XCTAssertThrowsError(try receive(task))
    }

    func testForgetAllDisconnectsPages() throws {
        let key = queue.sync { pairing.pairingKey }
        let task = socket()
        try send(task, text: #"{"type":"pair","key":"\#(key)","name":"iPad"}"#)
        XCTAssertEqual(try receiveJSON(task)["type"] as? String, "welcome")

        let reported = expectation(description: "session closed")
        queue.sync {
            server.sessions.first?.onClose = { _ in reported.fulfill() }
            server.forgetAllDevices()
        }
        wait(for: [reported], timeout: 5)
        XCTAssertTrue(queue.sync { server.sessions.isEmpty })
    }

    // MARK: Helpers

    private func expectSessionsChange() -> XCTestExpectation {
        let change = expectation(description: "sessions change")
        change.assertForOverFulfill = false
        return change
    }

    private func fetch(_ path: String) throws -> (Data, HTTPURLResponse) {
        let done = expectation(description: "GET \(path)")
        var result: (Data, HTTPURLResponse)?
        var failure: Error?
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let data, let response = response as? HTTPURLResponse { result = (data, response) }
            failure = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }

    private func socket() -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        task.resume()
        return task
    }

    private func send(_ task: URLSessionWebSocketTask, text: String) throws {
        try send(task, message: .string(text))
    }

    private func send(_ task: URLSessionWebSocketTask, data: Data) throws {
        try send(task, message: .data(data))
    }

    private func send(_ task: URLSessionWebSocketTask, message: URLSessionWebSocketTask.Message) throws {
        let done = expectation(description: "send")
        var failure: Error?
        task.send(message) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
    }

    private func receive(_ task: URLSessionWebSocketTask) throws -> URLSessionWebSocketTask.Message {
        let done = expectation(description: "receive")
        var result: Result<URLSessionWebSocketTask.Message, Error>?
        task.receive { outcome in
            result = outcome
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func receiveJSON(_ task: URLSessionWebSocketTask) throws -> [String: Any] {
        guard case .string(let text) = try receive(task) else {
            XCTFail("expected text")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
#endif
