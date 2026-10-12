import Foundation
import PadTrackCore
import PadTrackWeb

/// The iPad's Safari page, over the WebSocket it opened to this Mac. The page speaks the
/// same binary messages as the iPad app; the web server already checked its QR key or
/// device token before this link exists.
final class WebLink: TrackpadLink {
    var onMessage: ((Message) -> Void)?
    var onClose: ((String) -> Void)?

    private let session: WebSession
    private let queue: DispatchQueue
    private var closed = false

    init(session: WebSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    func start() {
        session.onBinary = { [weak self] data in
            guard let self, !self.closed, let message = try? Message.decode(data) else { return }
            self.onMessage?(message)
        }
        session.onClose = { [weak self] reason in
            self?.fail(reason)
        }
        if !session.isOpen {
            // The page left between being listed and being picked.
            queue.async { [weak self] in self?.fail("Safari bağlantısı kapandı") }
        }
    }

    func send(_ message: Message) {
        guard !closed else { return }
        session.send(message.encoded())
    }

    func close() {
        guard !closed else { return }
        closed = true
        session.onBinary = nil
        session.onClose = nil
        session.close()
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        session.onBinary = nil
        session.onClose = nil
        onClose?(reason)
    }
}
