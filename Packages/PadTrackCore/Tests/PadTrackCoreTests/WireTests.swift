import XCTest
@testable import PadTrackCore

final class WireTests: XCTestCase {
    func testRoundTripEveryMessage() throws {
        let messages: [Message] = [
            .hello(HelloInfo(deviceName: "Test iPad", deviceID: "6F1C2B9A-0D7E-4A51-9C33-2E8B1F0A7D64",
                             surfaceWidth: 1366, surfaceHeight: 1024)),
            .frame(TouchFrame(seq: 42, timestamp: 12345.678, touches: [
                TouchPoint(id: 0, x: 10.5, y: 20.25),
                TouchPoint(id: 7, x: 900, y: 700),
            ])),
            .frame(TouchFrame(seq: UInt32.max, timestamp: 0, touches: [])),
            .ping(0xDEAD_BEEF_0123_4567),
            .pong(1),
            .subscribe(SubscribeInfo(transport: .usb, hostName: "MacBook")),
            .bye,
        ]
        for message in messages {
            XCTAssertEqual(try Message.decode(message.encoded()), message)
        }
    }

    func testFiveFingerFrameIsSmall() {
        let touches = (0..<5).map { TouchPoint(id: UInt8($0), x: 1, y: 2) }
        let data = Message.frame(TouchFrame(seq: 1, timestamp: 1, touches: touches)).encoded()
        XCTAssertEqual(data.count, 1 + 4 + 8 + 1 + 5 * 9)
    }

    func testTruncatedDataThrows() {
        let data = Message.ping(5).encoded().dropLast()
        XCTAssertThrowsError(try Message.decode(Data(data)))
    }

    func testHelloFromOlderBuildWithoutDeviceIDStillDecodes() throws {
        var w = ByteWriter()
        w.u8(1); w.u8(1); w.f32(800); w.f32(600); w.string("iPad")
        let decoded = try Message.decode(w.data)
        XCTAssertEqual(decoded, .hello(HelloInfo(deviceName: "iPad", deviceID: "", surfaceWidth: 800, surfaceHeight: 600)))
    }

    func testUnknownTypeThrows() {
        XCTAssertThrowsError(try Message.decode(Data([0xFF])))
    }

    func testDeframerHandlesSplitAndMergedChunks() {
        let a = Message.ping(1).encoded()
        let b = Message.bye.encoded()
        var stream = StreamFraming.frame(a)
        stream.append(StreamFraming.frame(b))

        var deframer = StreamDeframer()
        var received: [Data] = []
        // Feed one byte at a time to exercise partial reads.
        for byte in stream {
            received += deframer.push(Data([byte]))
        }
        XCTAssertEqual(received, [a, b])

        // And everything at once.
        var second = StreamDeframer()
        XCTAssertEqual(second.push(stream), [a, b])
    }
}
