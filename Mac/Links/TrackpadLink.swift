import Foundation
import PadTrackCore

/// One connection to an iPad. Implementations deliver callbacks on the core queue.
///
/// Contract: `close()` is silent (no `onClose` callback). `onClose` fires at most once,
/// only when the link fails or the far side goes away.
protocol TrackpadLink: AnyObject {
    var onMessage: ((Message) -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    func start()
    /// Best effort; messages sent before the link is ready are dropped.
    func send(_ message: Message)
    func close()
}
