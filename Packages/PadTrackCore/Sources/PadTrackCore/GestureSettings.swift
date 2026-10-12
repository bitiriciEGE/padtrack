import Foundation

public enum ThreeFingerTapAction: String, Codable, CaseIterable, Sendable {
    case off
    case middleClick
    case lookUp
}

/// User-facing options. They live on the Mac; the iPad only streams raw touches.
public struct GestureSettings: Codable, Equatable, Sendable {
    public var pointerSpeed: Double = 1.0
    public var pointerAcceleration: Double = 1.0
    public var scrollSpeed: Double = 1.0
    public var naturalScrolling = true
    public var momentumScrolling = true
    public var tapToClick = true
    public var twoFingerSecondaryClick = true
    public var tapToDrag = true
    public var threeFingerDrag = false
    public var threeFingerTap: ThreeFingerTapAction = .middleClick
    /// 3/4-finger swipes: Mission Control, App Exposé, switch Spaces.
    public var swipeGestures = true
    /// Uses undocumented macOS gesture events (see EventInjector).
    public var pinchToZoom = true
    public var rotate = false
    /// Copied from NSEvent.doubleClickInterval on the Mac.
    public var doubleClickInterval: Double = 0.5

    public init() {}

    /// Tolerant decoding: settings saved by an older build (missing keys) keep the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureSettings()
        pointerSpeed = try c.decodeIfPresent(Double.self, forKey: .pointerSpeed) ?? d.pointerSpeed
        pointerAcceleration = try c.decodeIfPresent(Double.self, forKey: .pointerAcceleration) ?? d.pointerAcceleration
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? d.scrollSpeed
        naturalScrolling = try c.decodeIfPresent(Bool.self, forKey: .naturalScrolling) ?? d.naturalScrolling
        momentumScrolling = try c.decodeIfPresent(Bool.self, forKey: .momentumScrolling) ?? d.momentumScrolling
        tapToClick = try c.decodeIfPresent(Bool.self, forKey: .tapToClick) ?? d.tapToClick
        twoFingerSecondaryClick = try c.decodeIfPresent(Bool.self, forKey: .twoFingerSecondaryClick) ?? d.twoFingerSecondaryClick
        tapToDrag = try c.decodeIfPresent(Bool.self, forKey: .tapToDrag) ?? d.tapToDrag
        threeFingerDrag = try c.decodeIfPresent(Bool.self, forKey: .threeFingerDrag) ?? d.threeFingerDrag
        threeFingerTap = (try? c.decodeIfPresent(ThreeFingerTapAction.self, forKey: .threeFingerTap)) ?? d.threeFingerTap
        swipeGestures = try c.decodeIfPresent(Bool.self, forKey: .swipeGestures) ?? d.swipeGestures
        pinchToZoom = try c.decodeIfPresent(Bool.self, forKey: .pinchToZoom) ?? d.pinchToZoom
        rotate = try c.decodeIfPresent(Bool.self, forKey: .rotate) ?? d.rotate
        doubleClickInterval = try c.decodeIfPresent(Double.self, forKey: .doubleClickInterval) ?? d.doubleClickInterval
    }
}

/// Thresholds of the recognizer. Distances are iPad points, speeds iPad points per second,
/// times seconds. Pointer and scroll outputs are Mac points.
public struct GestureTuning: Sendable {
    public var minFrameInterval = 1.0 / 500.0
    public var maxFrameInterval = 0.1
    /// A finger that "moves" farther than this in one frame is treated as a new finger.
    public var maxJump = 180.0

    public var tapMaxDuration = 0.30
    public var tapMaxTravel = 10.0
    /// After a one-finger tap, touching again within this window and moving starts a drag.
    public var tapDragWindow = 0.30
    public var tapDragStartTravel = 6.0
    /// During a tap-drag, a second finger landing at least this long after the held one
    /// starts a two-finger drag (sooner means a normal two-finger tap/scroll).
    public var secondFingerDelay = 0.12
    public var pointerDeadzone = 1.5
    /// Mac points the pointer may move between two taps and still count as a double-click.
    public var doubleClickSlop = 8.0

    public var scrollStartDistance = 4.0
    public var pinchStartDistance = 12.0
    public var rotateStartDegrees = 14.0
    public var swipeDistance = 55.0
    public var swipeDominance = 1.5
    public var threeFingerDragStart = 5.0

    // Pointer gain = speed * (base + acceleration * accelGain * smoothstep(low, high, fingerSpeed))
    public var pointerBaseGain = 0.9
    public var pointerAccelGain = 2.2
    public var accelLowSpeed = 60.0
    public var accelHighSpeed = 1400.0

    public var scrollAccelGain = 0.6
    public var scrollAccelLowSpeed = 200.0
    public var scrollAccelHighSpeed = 2500.0

    // Momentum (inertial scrolling), in Mac points per second.
    public var momentumMinSpeed = 120.0
    public var momentumMaxSpeed = 7000.0
    public var momentumStopSpeed = 12.0
    /// Velocity multiplier per millisecond, same idea as UIScrollView's deceleration rate.
    public var momentumFrictionPerMs = 0.998
    /// Fingers that rested this long before lifting do not fling.
    public var momentumMaxIdle = 0.06
    public var velocityWindow = 0.08

    public init() {}
}
