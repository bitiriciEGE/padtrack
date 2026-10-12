import XCTest
@testable import PadTrackCore

/// Feeds synthetic touch frames into the engine with a 120 Hz clock.
private final class Pad {
    let engine: GestureEngine
    var seq: UInt32 = 0
    var time = 100.0
    var collected: [TrackpadAction] = []

    init(_ settings: GestureSettings = GestureSettings()) {
        engine = GestureEngine(settings: settings)
    }

    @discardableResult
    func frame(_ points: [(UInt8, Double, Double)], after seconds: Double = 1.0 / 120.0) -> [TrackpadAction] {
        seq += 1
        time += seconds
        let touches = points.map { TouchPoint(id: $0.0, x: Float($0.1), y: Float($0.2)) }
        let actions = engine.process(TouchFrame(seq: seq, timestamp: time, touches: touches))
        collected += actions
        return actions
    }

    func up(after seconds: Double = 1.0 / 120.0) -> [TrackpadAction] {
        frame([], after: seconds)
    }

    /// Moves every listed finger by (dx, dy) per frame, `steps` times.
    func drag(_ start: [(UInt8, Double, Double)], dx: Double, dy: Double, steps: Int) -> [(UInt8, Double, Double)] {
        var points = start
        for _ in 0..<steps {
            points = points.map { ($0.0, $0.1 + dx, $0.2 + dy) }
            frame(points)
        }
        return points
    }
}

final class GestureEngineTests: XCTestCase {
    func testSingleTapClicks() {
        let f = Pad()
        f.frame([(0, 100, 100)])
        let actions = f.up(after: 0.08)
        XCTAssertEqual(actions, [.buttonDown(.left, clickCount: 1), .buttonUp(.left, clickCount: 1)])
    }

    func testTwoQuickTapsMakeADoubleClick() {
        let f = Pad()
        f.frame([(0, 100, 100)])
        f.up(after: 0.07)
        f.frame([(1, 300, 300)], after: 0.10)
        let actions = f.up(after: 0.07)
        XCTAssertEqual(actions, [.buttonDown(.left, clickCount: 2), .buttonUp(.left, clickCount: 2)])
    }

    func testLongPressIsNotATap() {
        let f = Pad()
        f.frame([(0, 100, 100)])
        XCTAssertEqual(f.up(after: 0.6), [])
    }

    func testTwoFingerTapIsRightClick() {
        let f = Pad()
        f.frame([(0, 100, 100)])
        f.frame([(0, 100, 100), (1, 180, 100)], after: 0.02)
        let actions = f.up(after: 0.08)
        XCTAssertEqual(actions, [.buttonDown(.right, clickCount: 1), .buttonUp(.right, clickCount: 1)])
    }

    func testThreeFingerTapUsesSetting() {
        var settings = GestureSettings()
        settings.threeFingerTap = .lookUp
        let f = Pad(settings)
        f.frame([(0, 100, 100), (1, 150, 100), (2, 200, 100)])
        XCTAssertEqual(f.up(after: 0.1), [.system(.lookUp)])
    }

    func testOneFingerMovesPointerWithoutClicking() {
        let f = Pad()
        let start = [(UInt8(0), 100.0, 100.0)]
        f.frame(start)
        _ = f.drag(start, dx: 4, dy: 0, steps: 20)
        let lift = f.up()
        XCTAssertTrue(lift.isEmpty, "a long movement must not end with a click")

        let moves = f.collected.compactMap { action -> Double? in
            if case let .move(dx, dy) = action { XCTAssertEqual(dy, 0, accuracy: 1e-9); return dx }
            return nil
        }
        XCTAssertFalse(moves.isEmpty)
        XCTAssertTrue(moves.allSatisfy { $0 > 0 })
    }

    func testFasterMovementMovesFartherForSameDistance() {
        func distance(stepsFor80Points steps: Int) -> Double {
            let f = Pad()
            let start = [(UInt8(0), 100.0, 100.0)]
            f.frame(start)
            _ = f.drag(start, dx: 80.0 / Double(steps), dy: 0, steps: steps)
            return f.collected.reduce(0.0) { (sum: Double, action: TrackpadAction) -> Double in
                if case let .move(dx, _) = action { return sum + dx }
                return sum
            }
        }
        XCTAssertGreaterThan(distance(stepsFor80Points: 4), distance(stepsFor80Points: 40))
    }

    func testTapThenTouchAndMoveDrags() {
        let f = Pad()
        f.frame([(0, 100, 100)])
        f.up(after: 0.07)
        let start = [(UInt8(1), 300.0, 300.0)]
        f.frame(start, after: 0.12)
        f.collected.removeAll()
        _ = f.drag(start, dx: 5, dy: 0, steps: 6)
        _ = f.up()
        XCTAssertEqual(f.collected.first, .buttonDown(.left, clickCount: 1))
        XCTAssertEqual(f.collected.last, .buttonUp(.left, clickCount: 1))
        XCTAssertTrue(f.collected.contains { if case .move = $0 { return true } else { return false } })
    }

    func testTapThenHoldWithOneFingerAndDragWithAnother() {
        let f = Pad()
        f.frame([(0, 300, 300)])
        f.up(after: 0.07)                               // tap: selects the window
        f.frame([(1, 300, 300)], after: 0.12)           // touch again and keep it down
        f.collected.removeAll()
        f.frame([(1, 300, 300), (2, 500, 400)], after: 0.4) // second finger joins
        var x = 500.0
        for _ in 0..<8 { x += 6; f.frame([(1, 300, 300), (2, x, 400)]) }
        f.frame([(1, 300, 300)])                        // moving finger lifts: still held
        XCTAssertFalse(f.collected.contains(.buttonUp(.left, clickCount: 1)))
        _ = f.up()                                      // held finger lifts: drop
        XCTAssertEqual(f.collected.first, .buttonDown(.left, clickCount: 1))
        XCTAssertEqual(f.collected.last, .buttonUp(.left, clickCount: 1))
        XCTAssertTrue(f.collected.contains { if case let .move(dx, _) = $0 { return dx > 0 } else { return false } })
        XCTAssertFalse(f.collected.contains { if case .scroll = $0 { return true } else { return false } })
    }

    func testTwoFingerTapRightAfterATapIsStillRightClick() {
        let f = Pad()
        f.frame([(0, 300, 300)])
        f.up(after: 0.07)
        f.frame([(1, 300, 300)], after: 0.15)
        f.frame([(1, 300, 300), (2, 380, 300)], after: 0.02)
        XCTAssertEqual(f.up(after: 0.06), [.buttonDown(.right, clickCount: 1), .buttonUp(.right, clickCount: 1)])
    }

    func testRestingFingerWithoutTapStillScrolls() {
        let f = Pad()
        f.frame([(0, 100, 100)])
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 200.0, 100.0)]
        f.frame(start, after: 0.6)
        _ = f.drag(start, dx: 0, dy: 10, steps: 5)
        XCTAssertFalse(f.collected.contains { if case .buttonDown = $0 { return true } else { return false } })
    }

    func testQuickTwoFingerLandingStillScrolls() {
        let f = Pad()
        f.frame([(0, 100, 100)])
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 200.0, 100.0)]
        f.frame(start, after: 0.05)
        _ = f.drag(start, dx: 0, dy: 10, steps: 5)
        XCTAssertTrue(f.collected.contains { if case .scroll(_, _, .began) = $0 { return true } else { return false } })
        XCTAssertFalse(f.collected.contains { if case .buttonDown = $0 { return true } else { return false } })
    }

    func testTwoFingerScrollNaturalDirectionAndMomentum() {
        let f = Pad()
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 200.0, 100.0)]
        f.frame(start)
        _ = f.drag(start, dx: 0, dy: 12, steps: 10)
        let lift = f.up()

        let scrolls = f.collected.compactMap { action -> (Double, ScrollPhase)? in
            if case let .scroll(_, dy, phase) = action { return (dy, phase) }
            return nil
        }
        XCTAssertEqual(scrolls.first?.1, .began)
        XCTAssertTrue(scrolls.filter { $0.1 == .changed }.allSatisfy { $0.0 > 0 }, "fingers moving down scroll content down (natural)")
        XCTAssertTrue(lift.contains(.scroll(dx: 0, dy: 0, phase: .ended)))
        XCTAssertFalse(lift.contains { if case .buttonDown = $0 { return true } else { return false } })

        XCTAssertTrue(f.engine.needsTick, "a fast flick should start inertial scrolling")
        var phases: [ScrollPhase] = []
        var guardCounter = 0
        while f.engine.needsTick && guardCounter < 2000 {
            for action in f.engine.tick(dt: 1.0 / 120.0) {
                if case let .scroll(_, _, phase) = action { phases.append(phase) }
            }
            guardCounter += 1
        }
        XCTAssertEqual(phases.first, .momentumBegan)
        XCTAssertEqual(phases.last, .momentumEnded)
        XCTAssertFalse(f.engine.needsTick)
    }

    func testTraditionalScrollingInvertsDirection() {
        var settings = GestureSettings()
        settings.naturalScrolling = false
        settings.momentumScrolling = false
        let f = Pad(settings)
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 200.0, 100.0)]
        f.frame(start)
        _ = f.drag(start, dx: 0, dy: 5, steps: 5)
        let dys = f.collected.compactMap { action -> Double? in
            if case let .scroll(_, dy, phase) = action, phase != .ended { return dy }
            return nil
        }
        XCTAssertFalse(dys.isEmpty)
        XCTAssertTrue(dys.allSatisfy { $0 < 0 })
    }

    func testRestingBeforeLiftDoesNotFling() {
        let f = Pad()
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 200.0, 100.0)]
        f.frame(start)
        let end = f.drag(start, dx: 0, dy: 12, steps: 10)
        f.frame(end, after: 0.2) // fingers stay still
        _ = f.up()
        XCTAssertFalse(f.engine.needsTick)
    }

    func testTouchStopsMomentum() {
        let f = Pad()
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 200.0, 100.0)]
        f.frame(start)
        _ = f.drag(start, dx: 0, dy: 15, steps: 8)
        _ = f.up()
        _ = f.engine.tick(dt: 1.0 / 120.0)
        XCTAssertTrue(f.engine.needsTick)
        let actions = f.frame([(2, 500, 500)])
        XCTAssertEqual(actions, [.scroll(dx: 0, dy: 0, phase: .momentumEnded)])
        XCTAssertFalse(f.engine.needsTick)
    }

    func testPinchOutMagnifies() {
        let f = Pad()
        f.frame([(0, 300, 300), (1, 400, 300)])
        var a = 300.0, b = 400.0
        for _ in 0..<6 {
            a -= 4; b += 4
            f.frame([(0, a, 300), (1, b, 300)])
        }
        let lift = f.up()
        let magnify = f.collected.compactMap { action -> (Double, GesturePhase)? in
            if case let .magnify(value, phase) = action { return (value, phase) }
            return nil
        }
        XCTAssertEqual(magnify.first?.1, .began)
        XCTAssertGreaterThan(magnify.first?.0 ?? 0, 0)
        XCTAssertTrue(lift.contains(.magnify(0, .ended)))
        XCTAssertFalse(f.collected.contains { if case .scroll = $0 { return true } else { return false } })
    }

    func testThreeFingerSwipeUpOpensMissionControl() {
        let f = Pad()
        let start = [(UInt8(0), 100.0, 500.0), (UInt8(1), 160.0, 500.0), (UInt8(2), 220.0, 500.0)]
        f.frame(start)
        _ = f.drag(start, dx: 0, dy: -10, steps: 10)
        _ = f.up()
        XCTAssertEqual(f.collected.filter { if case .system = $0 { return true } else { return false } }, [.system(.missionControl)])
    }

    func testFourFingerSwipeLeftGoesToSpaceOnTheRight() {
        let f = Pad()
        let start = [(UInt8(0), 500.0, 300.0), (UInt8(1), 560.0, 300.0), (UInt8(2), 620.0, 300.0), (UInt8(3), 680.0, 300.0)]
        f.frame(start)
        _ = f.drag(start, dx: -12, dy: 0, steps: 8)
        _ = f.up()
        XCTAssertTrue(f.collected.contains(.system(.spaceRight)))
    }

    func testThreeFingerDragHoldsLeftButton() {
        var settings = GestureSettings()
        settings.threeFingerDrag = true
        let f = Pad(settings)
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 160.0, 100.0), (UInt8(2), 220.0, 100.0)]
        f.frame(start)
        _ = f.drag(start, dx: 6, dy: 0, steps: 5)
        _ = f.up()
        XCTAssertEqual(f.collected.first, .buttonDown(.left, clickCount: 1))
        XCTAssertEqual(f.collected.last, .buttonUp(.left, clickCount: 1))
        XCTAssertFalse(f.collected.contains { if case .system = $0 { return true } else { return false } })
    }

    func testOutOfOrderAndDuplicateFramesAreIgnored() {
        let engine = GestureEngine()
        _ = engine.process(TouchFrame(seq: 10, timestamp: 1, touches: [TouchPoint(id: 0, x: 100, y: 100)]))
        XCTAssertEqual(engine.process(TouchFrame(seq: 10, timestamp: 1.01, touches: [])), [])
        XCTAssertEqual(engine.process(TouchFrame(seq: 9, timestamp: 1.02, touches: [])), [])
        // The real release still produces the tap.
        XCTAssertEqual(engine.process(TouchFrame(seq: 11, timestamp: 1.05, touches: [])),
                       [.buttonDown(.left, clickCount: 1), .buttonUp(.left, clickCount: 1)])
    }

    func testResetReleasesHeldButton() {
        var settings = GestureSettings()
        settings.threeFingerDrag = true
        let f = Pad(settings)
        let start = [(UInt8(0), 100.0, 100.0), (UInt8(1), 160.0, 100.0), (UInt8(2), 220.0, 100.0)]
        f.frame(start)
        _ = f.drag(start, dx: 6, dy: 0, steps: 3)
        XCTAssertEqual(f.engine.reset(), [.buttonUp(.left, clickCount: 1)])
    }

    func testRotationSignIsCounterClockwisePositive() {
        // In y-down coordinates the angle going from 0 to -10° is a counter-clockwise turn on screen.
        XCTAssertEqual(GestureEngine.rotationDegrees(from: 0, to: -10 * Double.pi / 180), 10, accuracy: 1e-9)
        XCTAssertEqual(GestureEngine.rotationDegrees(from: Double.pi - 0.01, to: -Double.pi + 0.01), -(0.02 * 180 / Double.pi), accuracy: 1e-9)
    }
}
