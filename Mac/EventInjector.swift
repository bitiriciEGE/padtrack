import Foundation
import CoreGraphics
import PadTrackCore

/// Posts synthetic input events into macOS at the HID level, as if they came from a real
/// trackpad. Requires the Accessibility permission (CGPreflightPostEventAccess).
/// Used only from the core queue.
final class EventInjector {
    private let source: CGEventSource?
    private var held = Set<MouseButton>()

    // The window server updates the cursor asynchronously, so reading the cursor right after
    // posting can return a stale position. We keep our own position while we are driving the
    // pointer and only re-read the real one after a pause (someone may have used a mouse).
    private var pointer: CGPoint?
    private var lastPostTime: TimeInterval = 0

    private var scrollCarryX = 0.0
    private var scrollCarryY = 0.0

    private var displayBounds: [CGRect] = []
    private var displaysCheckedAt: TimeInterval = 0

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Do not mute the real mouse/keyboard for 0.25 s after each synthetic event.
        source?.localEventsSuppressionInterval = 0
        SystemActions.releaseStuckModifiers()
    }

    func perform(_ action: TrackpadAction) {
        switch action {
        case let .move(dx, dy):
            move(dx: dx, dy: dy)
        case let .buttonDown(button, clickCount):
            post(button: button, down: true, clickCount: clickCount)
        case let .buttonUp(button, clickCount):
            post(button: button, down: false, clickCount: clickCount)
        case let .scroll(dx, dy, phase):
            scroll(dx: dx, dy: dy, phase: phase)
        case let .magnify(value, phase):
            postGesture(hidType: 8, phase: phase) { $0.setDoubleValueField(Self.field(113), value: value) }
        case let .rotate(degrees, phase):
            postGesture(hidType: 5, phase: phase) { $0.setDoubleValueField(Self.field(114), value: degrees) }
        case let .system(systemAction):
            SystemActions.perform(systemAction)
        }
    }

    // MARK: Pointer

    private func currentPointer() -> CGPoint {
        let now = ProcessInfo.processInfo.systemUptime
        if let pointer, now - lastPostTime < 0.15 { return pointer }
        return CGEvent(source: nil)?.location ?? .zero
    }

    private func move(dx: Double, dy: Double) {
        let from = currentPointer()
        let target = clampToDisplays(CGPoint(x: from.x + dx, y: from.y + dy), from: from)
        let (type, button) = moveEventKind()
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.flags = userModifiers()
        // Games and 3D apps read raw deltas instead of positions.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event.post(tap: .cghidEventTap)
        remember(target)
    }

    /// While a button is held, movement must be a "dragged" event or drag-and-drop breaks.
    private func moveEventKind() -> (CGEventType, CGMouseButton) {
        if held.contains(.left) { return (.leftMouseDragged, .left) }
        if held.contains(.right) { return (.rightMouseDragged, .right) }
        if held.contains(.middle) { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    private func post(button: MouseButton, down: Bool, clickCount: Int) {
        let position = currentPointer()
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:
            type = down ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case .right:
            type = down ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        case .middle:
            type = down ? .otherMouseDown : .otherMouseUp
            cgButton = .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: cgButton) else { return }
        // Set the modifiers explicitly: an inherited Control would make this a right-click.
        event.flags = userModifiers()
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.post(tap: .cghidEventTap)
        if down { held.insert(button) } else { held.remove(button) }
        remember(position)
    }

    /// Only the modifier keys the user is really holding on the Mac keyboard (so ⇧-click and
    /// ⌘-click still work), never anything left over from synthesized shortcuts.
    private func userModifiers() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    private func remember(_ point: CGPoint) {
        pointer = point
        lastPostTime = ProcessInfo.processInfo.systemUptime
    }

    /// Keeps the cursor on screen. Moving onto another display is allowed when the target
    /// lies inside it; otherwise the cursor stops at the edge of the display it is on.
    private func clampToDisplays(_ point: CGPoint, from: CGPoint) -> CGPoint {
        let now = ProcessInfo.processInfo.systemUptime
        if displayBounds.isEmpty || now - displaysCheckedAt > 2 {
            displayBounds = Self.activeDisplayBounds()
            displaysCheckedAt = now
        }
        if displayBounds.isEmpty || displayBounds.contains(where: { $0.contains(point) }) { return point }
        let home = displayBounds.first(where: { $0.contains(from) }) ?? displayBounds[0]
        return CGPoint(x: min(max(point.x, home.minX), home.maxX - 1),
                       y: min(max(point.y, home.minY), home.maxY - 1))
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    // MARK: Scrolling

    /// Pixel-precise "continuous" scroll events with phases, like a real trackpad, so apps
    /// get smooth scrolling, rubber-banding and momentum.
    private func scroll(dx: Double, dy: Double, phase: ScrollPhase) {
        if phase == .began {
            scrollCarryX = 0
            scrollCarryY = 0
        }
        scrollCarryX += dx
        scrollCarryY += dy
        let wholeX = scrollCarryX.rounded(.towardZero)
        let wholeY = scrollCarryY.rounded(.towardZero)
        scrollCarryX -= wholeX
        scrollCarryY -= wholeY

        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: Int(wholeY)),
                                  wheel2: Int32(clamping: Int(wholeX)),
                                  wheel3: 0) else { return }
        let phases = Self.phaseValues(phase)
        event.flags = userModifiers()
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phases.scroll)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phases.momentum)
        event.post(tap: .cghidEventTap)
    }

    /// kCGScrollPhase: began 1, changed 2, ended 4. kCGMomentumScrollPhase: begin 1, continue 2, end 3.
    private static func phaseValues(_ phase: ScrollPhase) -> (scroll: Int64, momentum: Int64) {
        switch phase {
        case .began: return (1, 0)
        case .changed: return (2, 0)
        case .ended: return (4, 0)
        case .momentumBegan: return (0, 1)
        case .momentum: return (0, 2)
        case .momentumEnded: return (0, 3)
        }
    }

    // MARK: Pinch / rotate (undocumented)

    // macOS has no public API for synthesizing magnify/rotate gestures. These field numbers come
    // from reverse engineering (the same approach open-source tools such as Mac Mouse Fix use):
    //   55  = event type          -> 29 (NSEventTypeGesture)
    //   110 = IOHIDEventType      -> 8 zoom, 5 rotation
    //   132 = gesture phase       -> 1 began, 2 changed, 4 ended
    //   113 = magnification delta, 114 = rotation delta (degrees)
    // They may change in a future macOS; turn the gestures off in the menu if they misbehave.
    private static func field(_ raw: UInt32) -> CGEventField {
        CGEventField(rawValue: raw) ?? unsafeBitCast(raw, to: CGEventField.self)
    }

    private func postGesture(hidType: Int64, phase: GesturePhase, configure: (CGEvent) -> Void) {
        guard let event = CGEvent(source: nil) else { return }
        let phaseBits: Int64
        switch phase {
        case .began: phaseBits = 1
        case .changed: phaseBits = 2
        case .ended: phaseBits = 4
        }
        event.setIntegerValueField(Self.field(55), value: 29)
        event.setIntegerValueField(Self.field(110), value: hidType)
        event.setIntegerValueField(Self.field(132), value: phaseBits)
        configure(event)
        event.post(tap: .cghidEventTap)
    }
}
