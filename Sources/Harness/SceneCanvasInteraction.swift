import AppKit

/// Outline-only manipulation: no player rebuilds until a gesture finishes.
final class SceneDragOverlay: NSView {
    var transform: SceneNode.Transform = .identity { didSet { needsDisplay = true } }
    var nodes: [SceneNode] = []
    var selected = 0
    var isEnabled = true
    var onSelect: ((Int) -> Void)?
    var onTransform: ((SceneNode.Transform, String) -> Void)?
    var onNudge: ((Double, Double) -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    private var sceneRect: NSRect { bounds.insetBy(dx: 40, dy: 40) }
    private enum Gesture { case move, scale, rotate }
    private var gesture = Gesture.move
    private var origin: NSPoint?
    private var initial = SceneNode.Transform.identity
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isEnabled ? super.hitTest(point) : nil }
    private func center(_ t: SceneNode.Transform) -> NSPoint {
        NSPoint(x: sceneRect.minX + sceneRect.width * (0.5 + (t.x ?? 0)), y: sceneRect.minY + sceneRect.height * (0.5 + (t.y ?? 0)))
    }
    private func point(_ x: CGFloat, _ y: CGFloat, _ t: SceneNode.Transform) -> NSPoint {
        let a = CGFloat(t.rotation ?? 0) * .pi / 180
        let c = center(t)
        return .init(x: c.x + x * cos(a) - y * sin(a), y: c.y + x * sin(a) + y * cos(a))
    }
    private func corners(_ t: SceneNode.Transform) -> [NSPoint] {
        let w = sceneRect.width * (t.scale ?? 1) / 2
        let h = sceneRect.height * (t.scale ?? 1) / 2
        return [point(-w, -h, t), point(w, -h, t), point(w, h, t), point(-w, h, t)]
    }
    private func rotationHandle(_ t: SceneNode.Transform) -> NSPoint {
        point(0, sceneRect.height * (t.scale ?? 1) / 2 + 24, t)
    }
    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func contains(_ point: NSPoint, transform t: SceneNode.Transform) -> Bool {
        let c = center(t), a = -(t.rotation ?? 0) * .pi / 180
        let dx = point.x - c.x, dy = point.y - c.y
        return abs(dx * cos(a) - dy * sin(a)) <= sceneRect.width * (t.scale ?? 1) / 2 &&
               abs(dx * sin(a) + dy * cos(a)) <= sceneRect.height * (t.scale ?? 1) / 2
    }
    override func draw(_ dirtyRect: NSRect) {
        let corners = corners(transform)
        let path = NSBezierPath()
        path.move(to: corners[0])
        corners.dropFirst().forEach { path.line(to: $0) }
        path.close()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        NSColor.controlAccentColor.setFill()
        for corner in corners { NSBezierPath(rect: NSRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)).fill() }
        let handle = rotationHandle(transform)
        let stem = NSBezierPath()
        stem.move(to: point(0, sceneRect.height * (transform.scale ?? 1) / 2, transform))
        stem.line(to: handle)
        stem.stroke()
        NSBezierPath(ovalIn: NSRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if distance(p, rotationHandle(transform)) < 12 { gesture = .rotate }
        else if corners(transform).contains(where: { distance(p, $0) < 12 }) { gesture = .scale }
        else {
            // Option-click cycles through overlapping rectangles; normal click selects frontmost.
            let hits = nodes.indices.reversed().filter { nodes[$0].opacity > 0 && contains(p, transform: nodes[$0].transform) }
            if let first = hits.first {
                let index: Int
                if event.modifierFlags.contains(.option), let position = hits.firstIndex(of: selected) {
                    index = hits[(position + 1) % hits.count]
                } else { index = first }
                onSelect?(index)
            } else { return }
            gesture = .move
        }
        initial = transform
        origin = p
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, sceneRect.width > 0, sceneRect.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .move:
            transform = .init(x: min(2, max(-2, (initial.x ?? 0) + (p.x - origin.x) / sceneRect.width)),
                              y: min(2, max(-2, (initial.y ?? 0) + (p.y - origin.y) / sceneRect.height)), scale: initial.scale, rotation: initial.rotation)
        case .scale:
            let c = center(initial)
            let scale = min(4, max(0.05, (initial.scale ?? 1) * distance(p, c) / max(1, distance(origin, c))))
            transform = .init(x: initial.x, y: initial.y, scale: scale, rotation: initial.rotation)
        case .rotate:
            let c = center(initial)
            var degrees = (initial.rotation ?? 0) + (atan2(p.y - c.y, p.x - c.x) - atan2(origin.y - c.y, origin.x - c.x)) * 180 / .pi
            if event.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
            degrees = degrees.truncatingRemainder(dividingBy: 360)
            transform = .init(x: initial.x, y: initial.y, scale: initial.scale, rotation: degrees)
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        mouseDragged(with: event)
        origin = nil
        if (transform.x ?? 0) != (initial.x ?? 0) || (transform.y ?? 0) != (initial.y ?? 0) || (transform.scale ?? 1) != (initial.scale ?? 1) || (transform.rotation ?? 0) != (initial.rotation ?? 0) {
            onTransform?(transform, gesture == .move ? "Move Layer" : gesture == .scale ? "Resize Layer" : "Rotate Layer")
        }
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch event.keyCode {
        case 123: onNudge?(-step / max(1, sceneRect.width), 0)
        case 124: onNudge?(step / max(1, sceneRect.width), 0)
        case 125: onNudge?(0, -step / max(1, sceneRect.height))
        case 126: onNudge?(0, step / max(1, sceneRect.height))
        case 51, 117: onDelete?()
        default: super.keyDown(with: event)
        }
    }
}
