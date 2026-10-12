import Foundation
import CoreGraphics
import Darwin
import PadTrackCore

/// Mission Control, App Exposé, Spaces and Look Up.
enum SystemActions {
    // CoreDockSendNotification is a private Dock call that has existed for many macOS
    // versions. It is looked up at runtime so a missing symbol only disables the shortcut.
    private typealias DockNotify = @convention(c) (CFString, Int32) -> Void

    private static let dockNotify: DockNotify? = {
        let candidates: [UnsafeMutableRawPointer?] = [
            UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
            dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
        ]
        for handle in candidates {
            if let symbol = dlsym(handle, "CoreDockSendNotification") {
                return unsafeBitCast(symbol, to: DockNotify.self)
            }
        }
        return nil
    }()

    /// Keyboard shortcuts use a private event source, so the modifier keys they press can never
    /// end up in the shared HID state. A Control that stays "held" there turns every later click
    /// into a Control-click, which macOS treats as a right-click.
    private static let keySource = CGEventSource(stateID: .privateState)

    // Virtual key codes (Carbon kVK_*).
    private static let leftArrow: CGKeyCode = 123
    private static let rightArrow: CGKeyCode = 124
    private static let downArrow: CGKeyCode = 125
    private static let upArrow: CGKeyCode = 126
    private static let keyD: CGKeyCode = 2

    /// Arrow keys carry the Fn and numeric-pad flags when typed on a real keyboard.
    private static let arrowExtraFlags: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]

    private enum Modifier {
        case control, command

        var keyCode: CGKeyCode {
            switch self {
            case .control: return 59 // kVK_Control
            case .command: return 55 // kVK_Command
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .control: return .maskControl
            case .command: return .maskCommand
            }
        }
    }

    static func perform(_ action: SystemAction) {
        switch action {
        case .missionControl:
            if !dock("com.apple.expose.awake") { chord(upArrow, modifiers: [.control], keyFlags: arrowExtraFlags) }
        case .appExpose:
            if !dock("com.apple.expose.front.awake") { chord(downArrow, modifiers: [.control], keyFlags: arrowExtraFlags) }
        case .spaceLeft:
            // Default shortcut "Move left a space" (⌃←).
            chord(leftArrow, modifiers: [.control], keyFlags: arrowExtraFlags)
        case .spaceRight:
            chord(rightArrow, modifiers: [.control], keyFlags: arrowExtraFlags)
        case .lookUp:
            // "Look up & data detectors" (⌃⌘D).
            chord(keyD, modifiers: [.control, .command], keyFlags: [])
        }
    }

    /// Releases modifiers an earlier build may have left "held" in the shared HID state.
    /// Called once at launch.
    static func releaseStuckModifiers() {
        let shared = CGEventSource(stateID: .hidSystemState)
        for modifier in [Modifier.control, Modifier.command] {
            guard let event = CGEvent(keyboardEventSource: shared, virtualKey: modifier.keyCode, keyDown: false) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    private static func dock(_ notification: String) -> Bool {
        guard let notify = dockNotify else { return false }
        notify(notification as CFString, 0)
        return true
    }

    /// Presses the modifiers, taps the key, then releases the modifiers in reverse order, the way
    /// a person would, so nothing is left held afterwards.
    private static func chord(_ key: CGKeyCode, modifiers: [Modifier], keyFlags: CGEventFlags) {
        var held: CGEventFlags = []
        for modifier in modifiers {
            held.insert(modifier.flag)
            post(modifier.keyCode, down: true, flags: held)
        }
        post(key, down: true, flags: held.union(keyFlags))
        post(key, down: false, flags: held.union(keyFlags))
        for modifier in modifiers.reversed() {
            held.remove(modifier.flag)
            post(modifier.keyCode, down: false, flags: held)
        }
    }

    private static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
