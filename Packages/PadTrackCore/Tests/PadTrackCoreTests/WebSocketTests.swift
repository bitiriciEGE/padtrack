import XCTest
@testable import PadTrackCore

final class WebSocketTests: XCTestCase {
    // MARK: SHA-1 / handshake

    func testSHA1KnownVectors() {
        XCTAssertEqual(hex(SHA1.hash(Array("".utf8))), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(SHA1.hash(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(SHA1.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        // Exactly one block of input forces a second padding block.
        XCTAssertEqual(hex(SHA1.hash([UInt8](repeating: 0x61, count: 64))),
                       "0098ba824b5c16427bd7a1122a5a442a25ec644d")
    }

    func testAcceptValueFromRFC6455() {
        XCTAssertEqual(WebSocketHandshake.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testSafariUpgradeRequestParsesAndGets101() throws {
        let raw = "GET /ws HTTP/1.1\r\n"
            + "Host: Eges-MacBook-Air.local:47391\r\n"
            + "Origin: http://Eges-MacBook-Air.local:47391\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
        guard case .complete(let request, let consumed) = HTTPRequestParser.parse(Array(raw.utf8)) else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(consumed, raw.utf8.count)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/ws")
        XCTAssertEqual(request.header("Host"), "Eges-MacBook-Air.local:47391")
        XCTAssertTrue(request.isWebSocketUpgrade)

        let response = try XCTUnwrap(WebSocketHandshake.response(for: request))
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        // No extension is negotiated, so the client must not compress frames.
        XCTAssertFalse(text.lowercased().contains("extensions"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testHTTPParserEdgeCases() {
        XCTAssertEqual(HTTPRequestParser.parse(Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
        XCTAssertEqual(HTTPRequestParser.parse(Array("NONSENSE\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequestParser.parse(Array("GET / HTTP/1.1\r\nno colon here\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequestParser.parse([UInt8](repeating: 0x41, count: HTTPRequestParser.maxHeadBytes + 1)), .invalid)

        guard case .complete(let plain, _) = HTTPRequestParser.parse(Array("GET /?x=1 HTTP/1.1\r\nHost: a\r\n\r\n".utf8)) else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(plain.path, "/")
        XCTAssertFalse(plain.isWebSocketUpgrade)
        XCTAssertNil(WebSocketHandshake.response(for: plain))
    }

    // MARK: Frames (examples from RFC 6455 §5.7)

    func testMaskedClientTextFrame() throws {
        var decoder = WebSocketDecoder()
        let bytes: [UInt8] = [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        XCTAssertEqual(try decoder.push(Data(bytes)), [.text("Hello")])
        XCTAssertEqual(WebSocketFrame.encode(.text, payload: Data("Hello".utf8), mask: [0x37, 0xFA, 0x21, 0x3D]), Data(bytes))
    }

    func testUnmaskedServerFramesAndFragments() throws {
        XCTAssertEqual(WebSocketFrame.encode(.text, payload: Data("Hello".utf8)),
                       Data([0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F]))

        var client = WebSocketDecoder(expectMasked: false)
        let fragmented: [UInt8] = [0x01, 0x03, 0x48, 0x65, 0x6C, 0x89, 0x00, 0x80, 0x02, 0x6C, 0x6F]
        XCTAssertEqual(try client.push(Data(fragmented)), [.ping(Data()), .text("Hello")])
    }

    func testExtendedLengthsAndByteByByteFeeding() throws {
        let medium = Data((0..<256).map { UInt8($0 & 0xFF) })
        let large = Data(repeating: 7, count: 65_536)
        let mask: [UInt8] = [1, 2, 3, 4]

        let mediumFrame = WebSocketFrame.encode(.binary, payload: medium, mask: mask)
        XCTAssertEqual(Array(mediumFrame.prefix(4)), [0x82, 0xFE, 0x01, 0x00])
        let largeFrame = WebSocketFrame.encode(.binary, payload: large, mask: mask)
        XCTAssertEqual(Array(largeFrame.prefix(10)), [0x82, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0])

        var decoder = WebSocketDecoder(maxMessageSize: 70_000)
        var received: [WebSocketMessage] = []
        for byte in mediumFrame {
            received += try decoder.push(Data([byte]))
        }
        received += try decoder.push(largeFrame)
        XCTAssertEqual(received, [.binary(medium), .binary(large)])
    }

    func testServerRejectsUnmaskedOversizedAndBadFrames() {
        var a = WebSocketDecoder()
        XCTAssertThrowsError(try a.push(Data([0x82, 0x01, 0x00]))) { error in
            XCTAssertEqual((error as? WebSocketProtocolError)?.closeCode, WebSocketCloseCode.protocolError)
        }

        var b = WebSocketDecoder(maxMessageSize: 100)
        XCTAssertThrowsError(try b.push(WebSocketFrame.encode(.binary, payload: Data(count: 200), mask: [9, 9, 9, 9]))) { error in
            XCTAssertEqual((error as? WebSocketProtocolError)?.closeCode, WebSocketCloseCode.tooBig)
        }

        var c = WebSocketDecoder()
        XCTAssertThrowsError(try c.push(WebSocketFrame.encode(.continuation, payload: Data([1]), mask: [1, 1, 1, 1])))

        var d = WebSocketDecoder()
        XCTAssertThrowsError(try d.push(WebSocketFrame.encode(.text, payload: Data([0xC3, 0x28]), mask: [0, 0, 0, 0]))) { error in
            XCTAssertEqual((error as? WebSocketProtocolError)?.closeCode, WebSocketCloseCode.invalidData)
        }
    }

    func testCloseFrameRoundTrip() throws {
        let frame = WebSocketFrame.encode(.close(code: 4001, reason: "eşleştirme"), mask: [5, 6, 7, 8])
        var decoder = WebSocketDecoder()
        XCTAssertEqual(try decoder.push(frame), [.close(code: 4001, reason: "eşleştirme")])

        var empty = WebSocketDecoder()
        XCTAssertEqual(try empty.push(WebSocketFrame.encode(.close, payload: Data(), mask: [1, 2, 3, 4])),
                       [.close(code: nil, reason: "")])
    }

    // MARK: Shared fixtures with WebClient/protocol.test.mjs

    /// The Safari page encodes these messages in JavaScript; the bytes must match exactly.
    func testWireFixturesSharedWithJavaScript() throws {
        XCTAssertEqual(try Message.decode(data("01010080934400004d440469506164057765622d31")),
                       .hello(HelloInfo(deviceName: "iPad", deviceID: "web-1", surfaceWidth: 1180, surfaceHeight: 820)))
        XCTAssertEqual(try Message.decode(data("0207000000000000000000f83f0103000024410000a441")),
                       .frame(TouchFrame(seq: 7, timestamp: 1.5, touches: [TouchPoint(id: 3, x: 10.25, y: 20.5)])))
        XCTAssertEqual(try Message.decode(data("040807060504030201")), .pong(0x0102_0304_0506_0708))

        XCTAssertEqual(hex(Message.subscribe(SubscribeInfo(transport: .web, hostName: "Mac")).encoded()), "050104034d6163")
        XCTAssertEqual(hex(Message.ping(42).encoded()), "032a00000000000000")
        XCTAssertEqual(hex(Message.bye.encoded()), "06")
    }

    func testWebTransportRoundTripsAndRanksBelowWiFi() throws {
        let message = Message.subscribe(SubscribeInfo(transport: .web, hostName: "MacBook"))
        XCTAssertEqual(try Message.decode(message.encoded()), message)
        XCTAssertLessThan(LinkTransport.wifi.priority, LinkTransport.web.priority)
        XCTAssertLessThan(LinkTransport.web.priority, LinkTransport.bluetooth.priority)
    }

    // MARK: Helpers

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func data(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
}
