import Foundation

public enum MouseButton: Hashable, Sendable {
    case left, right, middle
}

public enum GesturePhase: Equatable, Sendable {
    case began, changed, ended
}

public enum ScrollPhase: Equatable, Sendable {
    case began, changed, ended
    case momentumBegan, momentum, momentumEnded
}

public enum SystemAction: String, Equatable, Sendable {
    case missionControl
    case appExpose
    /// Show the Space to the left (fingers swiped right).
    case spaceLeft
    /// Show the Space to the right (fingers swiped left).
    case spaceRight
    case lookUp
}

/// What the Mac should do. Pointer and scroll values are Mac points.
/// `scroll` uses the CGEvent wheel convention: positive dy scrolls up (content moves down),
/// positive dx scrolls left (content moves right). Natural scrolling is already applied.
public enum TrackpadAction: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case buttonDown(MouseButton, clickCount: Int)
    case buttonUp(MouseButton, clickCount: Int)
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    /// Relative change, e.g. 0.05 = 5% bigger (same meaning as NSEvent.magnification).
    case magnify(Double, GesturePhase)
    /// Degrees, counter-clockwise positive (same meaning as NSEvent.rotation).
    case rotate(Double, GesturePhase)
    case system(SystemAction)
}

struct Vec2: Equatable {
    var x: Double
    var y: Double

    static let zero = Vec2(x: 0, y: 0)

    var length: Double { (x * x + y * y).squareRoot() }

    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    static func / (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x / s, y: a.y / s) }
}

/// Turns raw multi-touch frames into Magic Trackpad style actions.
///
/// A "session" lasts from the first finger landing until the last finger lifts.
/// While undecided the engine watches how the fingers move; the first threshold crossed
/// decides the gesture (pointer, scroll, pinch/rotate, three-finger drag, swipe) and the
/// session stays in that gesture until every finger is up. Taps are decided on lift.
///
/// Not thread-safe: call it from one serial queue.
public final class GestureEngine {
    public var settings: GestureSettings
    public var tuning: GestureTuning

    public init(settings: GestureSettings = GestureSettings(), tuning: GestureTuning = GestureTuning()) {
        self.settings = settings
        self.tuning = tuning
    }

    /// True while inertial scrolling is running; call `tick(dt:)` at display rate until it turns false.
    public var needsTick: Bool { momentum != nil }

    // MARK: State

    private enum Mode: Equatable {
        case idle
        case pointer
        case tapDrag(UInt8)
        /// Tap, touch again and keep that finger down (the "held button"); any other finger drags.
        case holdDrag(UInt8)
        case scroll
        case transform
        case threeFingerDrag
        /// A gesture already ran (or a swipe fired); ignore movement until all fingers lift.
        case finished
    }

    private struct Finger {
        var start: Vec2
        var pos: Vec2
        var startTime: Double
    }

    private struct Momentum {
        var velocity: Vec2
        var started: Bool
    }

    private struct ClickRecord {
        var button: MouseButton
        var time: Double
        var count: Int
    }

    private struct ScrollSample {
        var time: Double
        var delta: Vec2
    }

    private var fingers: [UInt8: Finger] = [:]
    private var lastSeq: UInt32?
    private var lastTimestamp: Double?

    private var sessionActive = false
    private var sessionStart = 0.0
    private var maxFingers = 0
    private var maxTravel = 0.0
    private var mode: Mode = .idle
    private var tapDragArmed = false

    // Reference for classifying multi-finger movement.
    private var refIDs: [UInt8] = []
    private var refTime = 0.0
    private var refSpread = 0.0
    private var refAngle = 0.0
    private var accumulated = Vec2.zero

    // Pinch / rotate.
    private var pairIDs: [UInt8] = []
    private var pairSpread = 0.0
    private var pairAngle = 0.0
    private var magnifyActive = false
    private var rotateActive = false
    private var pendingRotation = 0.0

    private var scrollSamples: [ScrollSample] = []
    private var momentum: Momentum?

    private var lastClick: ClickRecord?
    private var travelSinceClick = 0.0
    private var lastSingleTapEnd: Double?
    private var leftHeld = false

    // MARK: Input

    public func process(_ frame: TouchFrame) -> [TrackpadAction] {
        // Drop duplicates and frames that arrive out of order (UDP).
        if let last = lastSeq {
            let ahead = frame.seq &- last
            if ahead == 0 || ahead > UInt32.max / 2 { return [] }
        }
        lastSeq = frame.seq

        let dt: Double
        if let previous = lastTimestamp {
            dt = min(max(frame.timestamp - previous, tuning.minFrameInterval), tuning.maxFrameInterval)
        } else {
            dt = 1.0 / 120.0
        }
        lastTimestamp = frame.timestamp
        let now = frame.timestamp

        var out: [TrackpadAction] = []

        // 1. Update the finger table and collect per-finger movement since the previous frame.
        //    Only fingers present in both frames contribute, so fingers landing or lifting never
        //    make the centroid jump.
        var deltas: [UInt8: Vec2] = [:]
        var present = Set<UInt8>()
        for touch in frame.touches {
            let p = Vec2(x: Double(touch.x), y: Double(touch.y))
            present.insert(touch.id)
            if var finger = fingers[touch.id] {
                let d = p - finger.pos
                if d.length > tuning.maxJump {
                    fingers[touch.id] = Finger(start: p, pos: p, startTime: frame.timestamp)
                } else {
                    finger.pos = p
                    fingers[touch.id] = finger
                    deltas[touch.id] = d
                }
            } else {
                fingers[touch.id] = Finger(start: p, pos: p, startTime: frame.timestamp)
            }
        }
        let removed = fingers.keys.filter { !present.contains($0) }
        for id in removed { fingers[id] = nil }
        let count = fingers.count
        let setChanged = !removed.isEmpty || deltas.count != count

        // 2. Session bookkeeping.
        if !sessionActive {
            guard count > 0 else { return out }
            out += stopMomentum()
            beginSession(at: now)
        }
        maxFingers = max(maxFingers, count)
        for finger in fingers.values {
            maxTravel = max(maxTravel, (finger.pos - finger.start).length)
        }

        let mean = Self.mean(of: deltas)
        let meanSpeed = mean.length / dt

        // 3. Continue the running gesture, or try to recognize one.
        switch mode {
        case .idle:
            out += classify(count: count, deltas: deltas, mean: mean, setChanged: setChanged, dt: dt, now: now)

        case .pointer:
            if count == 1, let d = deltas.values.first {
                out += movePointer(d, speed: d.length / dt)
            } else if count >= 2 {
                mode = .idle
                resetReference(at: now)
            }

        case .tapDrag(let id):
            if let d = deltas[id] {
                out += movePointer(d, speed: d.length / dt)
            } else if fingers[id] == nil {
                out += releaseLeft()
                mode = .finished
            }

        case .holdDrag(let anchor):
            if fingers[anchor] == nil {
                out += releaseLeft()
                mode = .finished
            } else {
                // Other fingers drive the drag; if only the held finger moves, it drives it.
                let movers = deltas.filter { $0.key != anchor }
                let driving = movers.isEmpty ? deltas : movers
                if !driving.isEmpty {
                    let m = Self.mean(of: driving)
                    out += movePointer(m, speed: m.length / dt)
                }
            }

        case .scroll:
            if count >= 2 {
                if !deltas.isEmpty {
                    out += scrollStep(mean, speed: meanSpeed, phase: .changed, now: now)
                }
            } else {
                out += endScroll(at: now)
                mode = .finished
            }

        case .transform:
            if count >= 2 {
                out += transformStep()
            } else {
                out += endTransform()
                mode = .finished
            }

        case .threeFingerDrag:
            if count >= 2 {
                if !deltas.isEmpty { out += movePointer(mean, speed: meanSpeed) }
            } else {
                out += releaseLeft()
                mode = .finished
            }

        case .finished:
            break
        }

        // 4. Last finger lifted: close the session and decide taps.
        if count == 0 {
            out += endSession(at: now)
        }
        return out
    }

    /// Advances inertial scrolling. `dt` is seconds since the previous tick (Mac clock).
    public func tick(dt: Double) -> [TrackpadAction] {
        guard var m = momentum else { return [] }
        let step = min(max(dt, 0.001), 0.05)
        let d = m.velocity * step
        m.velocity = m.velocity * pow(tuning.momentumFrictionPerMs, step * 1000)
        var out: [TrackpadAction] = [.scroll(dx: d.x, dy: d.y, phase: m.started ? .momentum : .momentumBegan)]
        m.started = true
        if m.velocity.length < tuning.momentumStopSpeed {
            out.append(.scroll(dx: 0, dy: 0, phase: .momentumEnded))
            momentum = nil
        } else {
            momentum = m
        }
        return out
    }

    /// Ends every running gesture and releases held buttons (call when the link changes or drops).
    @discardableResult
    public func reset() -> [TrackpadAction] {
        var out: [TrackpadAction] = []
        switch mode {
        case .scroll: out.append(.scroll(dx: 0, dy: 0, phase: .ended))
        case .transform: out += endTransform()
        default: break
        }
        out += releaseLeft()
        out += stopMomentum()
        fingers.removeAll()
        sessionActive = false
        mode = .idle
        tapDragArmed = false
        lastSeq = nil
        lastTimestamp = nil
        lastSingleTapEnd = nil
        lastClick = nil
        scrollSamples.removeAll()
        accumulated = .zero
        return out
    }

    // MARK: Recognition

    private func beginSession(at now: Double) {
        sessionActive = true
        sessionStart = now
        maxFingers = 0
        maxTravel = 0
        mode = .idle
        let recentTap = lastSingleTapEnd.map { now - $0 <= tuning.tapDragWindow } ?? false
        tapDragArmed = settings.tapToClick && settings.tapToDrag && recentTap
        resetReference(at: now)
    }

    private func classify(count: Int, deltas: [UInt8: Vec2], mean: Vec2, setChanged: Bool, dt: Double, now: Double) -> [TrackpadAction] {
        if setChanged {
            // Tap, then touch again and hold: that finger keeps the button pressed and a second
            // finger moves the pointer (same as pressing a Magic Trackpad with one finger and
            // dragging with another).
            if count == 2, tapDragArmed, maxFingers <= 2, let anchor = tapDragAnchor(now: now) {
                mode = .holdDrag(anchor)
                return pressLeft()
            }
            resetReference(at: now)
            return []
        }

        switch count {
        case 1:
            guard let entry = deltas.first, let finger = fingers[entry.key] else { return [] }
            let travel = (finger.pos - finger.start).length
            if tapDragArmed && maxFingers == 1 {
                // Second touch right after a tap: hold the pointer still until it is clearly a drag,
                // so a quick second tap stays a clean double-click.
                guard travel > tuning.tapDragStartTravel else { return [] }
                mode = .tapDrag(entry.key)
                var out = pressLeft()
                out += movePointer(finger.pos - finger.start, speed: entry.value.length / dt)
                return out
            }
            guard travel > tuning.pointerDeadzone else { return [] }
            mode = .pointer
            return movePointer(entry.value, speed: entry.value.length / dt)

        case 2:
            guard refIDs.count == 2, let a = fingers[refIDs[0]], let b = fingers[refIDs[1]] else {
                resetReference(at: now)
                return []
            }
            accumulated = accumulated + mean
            let spread = (b.pos - a.pos).length
            let angle = atan2(b.pos.y - a.pos.y, b.pos.x - a.pos.x)
            let spreadChange = spread - refSpread
            let rotation = Self.rotationDegrees(from: refAngle, to: angle)
            let translation = accumulated.length

            if settings.pinchToZoom, abs(spreadChange) > tuning.pinchStartDistance, abs(spreadChange) > translation {
                let magnification = refSpread > 1 ? spread / refSpread - 1 : 0
                return beginTransform(spread: spread, angle: angle, magnification: magnification, rotation: rotation, startedByRotation: false)
            }
            let arc = abs(rotation) * Double.pi / 180 * spread / 2
            if settings.rotate, abs(rotation) > tuning.rotateStartDegrees, arc > translation {
                return beginTransform(spread: spread, angle: angle, magnification: 0, rotation: rotation, startedByRotation: true)
            }
            if translation > tuning.scrollStartDistance {
                mode = .scroll
                scrollSamples.removeAll()
                let elapsed = max(now - refTime, dt)
                return scrollStep(accumulated, speed: translation / elapsed, phase: .began, now: now)
            }
            return []

        case 3, 4:
            accumulated = accumulated + mean
            let translation = accumulated.length
            if count == 3 && settings.threeFingerDrag {
                guard translation > tuning.threeFingerDragStart else { return [] }
                mode = .threeFingerDrag
                var out = pressLeft()
                out += movePointer(accumulated, speed: translation / max(now - refTime, dt))
                return out
            }
            guard settings.swipeGestures, translation > tuning.swipeDistance else { return [] }
            let ax = abs(accumulated.x)
            let ay = abs(accumulated.y)
            let action: SystemAction
            if ax > ay * tuning.swipeDominance {
                action = accumulated.x < 0 ? .spaceRight : .spaceLeft
            } else if ay > ax * tuning.swipeDominance {
                action = accumulated.y < 0 ? .missionControl : .appExpose
            } else {
                return []
            }
            mode = .finished
            return [.system(action)]

        default:
            return []
        }
    }

    private func endSession(at now: Double) -> [TrackpadAction] {
        var out: [TrackpadAction] = []
        // Safety net; the mode handlers normally closed these already.
        switch mode {
        case .tapDrag, .holdDrag, .threeFingerDrag: out += releaseLeft()
        case .scroll: out += endScroll(at: now)
        case .transform: out += endTransform()
        default: break
        }

        let duration = now - sessionStart
        let tapEligible = settings.tapToClick
            && (mode == .idle || mode == .pointer)
            && duration <= tuning.tapMaxDuration
            && maxTravel <= tuning.tapMaxTravel

        lastSingleTapEnd = nil
        if tapEligible {
            switch maxFingers {
            case 1:
                out += click(.left, at: now)
                lastSingleTapEnd = now
            case 2:
                if settings.twoFingerSecondaryClick { out += click(.right, at: now) }
            case 3:
                switch settings.threeFingerTap {
                case .middleClick: out += click(.middle, at: now)
                case .lookUp: out.append(.system(.lookUp))
                case .off: break
                }
            default:
                break
            }
        }

        sessionActive = false
        mode = .idle
        tapDragArmed = false
        accumulated = .zero
        return out
    }

    /// The finger that opened this tap-drag session, if a second finger has just joined it.
    /// The gap filter keeps a normal two-finger tap/scroll (both fingers land together) unchanged.
    private func tapDragAnchor(now: Double) -> UInt8? {
        let first = fingers.filter { $0.value.startTime <= sessionStart }
        let joined = fingers.filter { $0.value.startTime > sessionStart }
        guard first.count == 1, joined.count == 1, let anchor = first.first, let other = joined.first else { return nil }
        guard other.value.startTime - anchor.value.startTime >= tuning.secondFingerDelay else { return nil }
        return anchor.key
    }

    private func resetReference(at now: Double) {
        refIDs = Array(fingers.keys.sorted().prefix(2))
        refTime = now
        accumulated = .zero
        if refIDs.count == 2, let a = fingers[refIDs[0]], let b = fingers[refIDs[1]] {
            refSpread = (b.pos - a.pos).length
            refAngle = atan2(b.pos.y - a.pos.y, b.pos.x - a.pos.x)
        } else {
            refSpread = 0
            refAngle = 0
        }
    }

    // MARK: Pointer and clicks

    private func movePointer(_ fingerDelta: Vec2, speed: Double) -> [TrackpadAction] {
        let t = Self.smoothstep(tuning.accelLowSpeed, tuning.accelHighSpeed, speed)
        let gain = settings.pointerSpeed * (tuning.pointerBaseGain + settings.pointerAcceleration * tuning.pointerAccelGain * t)
        let d = fingerDelta * gain
        guard d != .zero else { return [] }
        travelSinceClick += d.length
        return [.move(dx: d.x, dy: d.y)]
    }

    private func click(_ button: MouseButton, at time: Double) -> [TrackpadAction] {
        var count = 1
        if let previous = lastClick,
           previous.button == button,
           time - previous.time <= settings.doubleClickInterval,
           travelSinceClick <= tuning.doubleClickSlop {
            count = min(previous.count + 1, 3)
        }
        lastClick = ClickRecord(button: button, time: time, count: count)
        travelSinceClick = 0
        return [.buttonDown(button, clickCount: count), .buttonUp(button, clickCount: count)]
    }

    private func pressLeft() -> [TrackpadAction] {
        leftHeld = true
        lastClick = nil
        return [.buttonDown(.left, clickCount: 1)]
    }

    private func releaseLeft() -> [TrackpadAction] {
        guard leftHeld else { return [] }
        leftHeld = false
        return [.buttonUp(.left, clickCount: 1)]
    }

    // MARK: Scrolling

    private func scrollStep(_ fingerDelta: Vec2, speed: Double, phase: ScrollPhase, now: Double) -> [TrackpadAction] {
        let t = Self.smoothstep(tuning.scrollAccelLowSpeed, tuning.scrollAccelHighSpeed, speed)
        let direction: Double = settings.naturalScrolling ? 1 : -1
        let gain = settings.scrollSpeed * (1 + tuning.scrollAccelGain * t) * direction
        let d = fingerDelta * gain
        scrollSamples.append(ScrollSample(time: now, delta: d))
        if let first = scrollSamples.first, now - first.time > 0.25 {
            scrollSamples.removeAll { now - $0.time > 0.25 }
        }
        if phase == .changed && d == .zero { return [] }
        return [.scroll(dx: d.x, dy: d.y, phase: phase)]
    }

    private func endScroll(at now: Double) -> [TrackpadAction] {
        let out: [TrackpadAction] = [.scroll(dx: 0, dy: 0, phase: .ended)]
        if settings.momentumScrolling, var v = releaseVelocity(at: now) {
            let speed = v.length
            if speed >= tuning.momentumMinSpeed {
                if speed > tuning.momentumMaxSpeed { v = v * (tuning.momentumMaxSpeed / speed) }
                momentum = Momentum(velocity: v, started: false)
            }
        }
        scrollSamples.removeAll()
        return out
    }

    /// Average scroll velocity over the last few frames before the fingers lifted.
    private func releaseVelocity(at now: Double) -> Vec2? {
        guard let last = scrollSamples.last, now - last.time <= tuning.momentumMaxIdle else { return nil }
        let window = scrollSamples.filter { $0.time >= last.time - tuning.velocityWindow }
        guard window.count >= 2, let first = window.first else { return nil }
        let span = last.time - first.time
        guard span > 0.004 else { return nil }
        var sum = Vec2.zero
        for sample in window.dropFirst() { sum = sum + sample.delta }
        return sum / span
    }

    private func stopMomentum() -> [TrackpadAction] {
        guard let m = momentum else { return [] }
        momentum = nil
        return m.started ? [.scroll(dx: 0, dy: 0, phase: .momentumEnded)] : []
    }

    // MARK: Pinch and rotate

    private func beginTransform(spread: Double, angle: Double, magnification: Double, rotation: Double, startedByRotation: Bool) -> [TrackpadAction] {
        mode = .transform
        pairIDs = refIDs
        pairSpread = spread
        pairAngle = angle
        var out: [TrackpadAction] = []
        magnifyActive = settings.pinchToZoom
        if magnifyActive { out.append(.magnify(magnification, .began)) }
        rotateActive = settings.rotate && startedByRotation
        pendingRotation = rotateActive ? 0 : rotation
        if rotateActive { out.append(.rotate(rotation, .began)) }
        return out
    }

    private func transformStep() -> [TrackpadAction] {
        guard pairIDs.count == 2, let a = fingers[pairIDs[0]], let b = fingers[pairIDs[1]] else {
            // One finger of the pair lifted while others stay: re-pair without emitting a jump.
            pairIDs = Array(fingers.keys.sorted().prefix(2))
            if pairIDs.count == 2, let a = fingers[pairIDs[0]], let b = fingers[pairIDs[1]] {
                pairSpread = (b.pos - a.pos).length
                pairAngle = atan2(b.pos.y - a.pos.y, b.pos.x - a.pos.x)
            }
            return []
        }
        let spread = (b.pos - a.pos).length
        let angle = atan2(b.pos.y - a.pos.y, b.pos.x - a.pos.x)
        var out: [TrackpadAction] = []
        if magnifyActive, pairSpread > 1 {
            let m = spread / pairSpread - 1
            if m != 0 { out.append(.magnify(m, .changed)) }
        }
        let r = Self.rotationDegrees(from: pairAngle, to: angle)
        if rotateActive {
            if r != 0 { out.append(.rotate(r, .changed)) }
        } else if settings.rotate {
            pendingRotation += r
            if abs(pendingRotation) > tuning.rotateStartDegrees {
                rotateActive = true
                out.append(.rotate(pendingRotation, .began))
            }
        }
        pairSpread = spread
        pairAngle = angle
        return out
    }

    private func endTransform() -> [TrackpadAction] {
        var out: [TrackpadAction] = []
        if magnifyActive { out.append(.magnify(0, .ended)) }
        if rotateActive { out.append(.rotate(0, .ended)) }
        magnifyActive = false
        rotateActive = false
        pendingRotation = 0
        pairIDs = []
        return out
    }

    // MARK: Math

    private static func mean(of deltas: [UInt8: Vec2]) -> Vec2 {
        guard !deltas.isEmpty else { return .zero }
        var sum = Vec2.zero
        for d in deltas.values { sum = sum + d }
        return sum / Double(deltas.count)
    }

    /// Angles come from a y-down coordinate system, so a visually counter-clockwise turn
    /// makes the angle smaller. Flip the sign to match NSEvent.rotation.
    static func rotationDegrees(from a0: Double, to a1: Double) -> Double {
        var d = (a1 - a0) * 180 / Double.pi
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return -d
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
