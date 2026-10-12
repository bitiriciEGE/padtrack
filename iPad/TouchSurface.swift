import SwiftUI
import UIKit
import PadTrackCore

/// Full-screen multi-touch surface. Every touch change produces one frame holding all fingers.
struct TouchSurface: UIViewRepresentable {
    var showTouches: Bool
    var onFrame: ([TouchPoint], TimeInterval, Bool) -> Void
    var onResize: (CGSize) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onFrame = onFrame
        view.onResize = onResize
        view.showTouches = showTouches
    }
}

final class TouchSurfaceView: UIView {
    /// (fingers, event timestamp, structural). Structural = a finger landed or lifted;
    /// such frames must never be dropped by a congested link, plain moves may be coalesced.
    var onFrame: (([TouchPoint], TimeInterval, Bool) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var showTouches = true {
        didSet { if !showTouches { removeAllDots() } }
    }

    private var ids: [ObjectIdentifier: UInt8] = [:]
    private var nextID: UInt8 = 0
    private var dots: [UInt8: CALayer] = [:]
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?(bounds.size)
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { assignID(to: touch) }
        emit(event, ending: [], structural: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(event, ending: [], structural: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(event, ending: touches, structural: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(event, ending: touches, structural: true)
    }

    /// IDs rotate instead of being reused right away, so a lost "finger lifted" datagram
    /// can never make a new finger look like an old one teleporting across the screen.
    private func assignID(to touch: UITouch) {
        let key = ObjectIdentifier(touch)
        guard ids[key] == nil else { return }
        let used = Set(ids.values)
        var candidate = nextID
        for _ in 0..<256 where used.contains(candidate) {
            candidate = candidate &+ 1
        }
        ids[key] = candidate
        nextID = candidate &+ 1
    }

    private func emit(_ event: UIEvent?, ending: Set<UITouch>, structural: Bool) {
        let all = event?.touches(for: self) ?? []
        var points: [TouchPoint] = []
        for touch in all {
            if ending.contains(touch) || touch.phase == .ended || touch.phase == .cancelled { continue }
            guard let id = ids[ObjectIdentifier(touch)] else { continue }
            let p = touch.preciseLocation(in: self)
            points.append(TouchPoint(id: id, x: Float(p.x), y: Float(p.y)))
        }
        for touch in ending { ids[ObjectIdentifier(touch)] = nil }
        if points.isEmpty { ids.removeAll() }

        points.sort { $0.id < $1.id }
        if points.count > PadTrackProtocol.maxTouchesPerFrame {
            points = Array(points.prefix(PadTrackProtocol.maxTouchesPerFrame))
        }
        let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        onFrame?(points, timestamp, structural)
        if showTouches { updateDots(points) }
    }

    // MARK: Finger feedback

    private func updateDots(_ points: [TouchPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var alive = Set<UInt8>()
        for point in points {
            alive.insert(point.id)
            let dot = dots[point.id] ?? makeDot(for: point.id)
            dot.position = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        for (id, dot) in dots where !alive.contains(id) {
            dot.removeFromSuperlayer()
            dots[id] = nil
        }
        CATransaction.commit()
    }

    private func makeDot(for id: UInt8) -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        dot.cornerRadius = 28
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.08).cgColor
        dot.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        dot.borderWidth = 1
        layer.addSublayer(dot)
        dots[id] = dot
        return dot
    }

    private func removeAllDots() {
        for dot in dots.values { dot.removeFromSuperlayer() }
        dots.removeAll()
    }
}
