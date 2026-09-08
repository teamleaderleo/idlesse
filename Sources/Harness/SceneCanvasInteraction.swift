import AppKit

/// Live manipulation with one document commit per gesture.
final class SceneDragOverlay: NSView {
    var transform: SceneNode.Transform = .identity { didSet { needsDisplay = true } }
    var roots: [SceneNode] = []
    var nodes: [SceneNode] { roots.flatMap { $0.descendants } }
    var selected = 0
    var isEnabled = true
    var onSelect: ((Int) -> Void)?
    var onPreviewTransform: ((SceneNode.Transform) -> Void)?
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
    private func ancestors(of index: Int) -> [SceneNode] {
        guard nodes.indices.contains(index) else { return [] }
        let id = nodes[index].id
        func find(_ list: [SceneNode], _ path: [SceneNode]) -> [SceneNode]? {
            for node in list {
                if node.id == id { return path }
                if let result = find(node.children, path + [node]) { return result }
            }
            return nil
        }
        return find(roots, []) ?? []
    }
    private func eligible(_ index: Int) -> Bool {
        nodes.indices.contains(index) && (ancestors(of: index) + [nodes[index]]).allSatisfy {
            $0.visible && !$0.locked && $0.opacity > 0
        }
    }
    // Compose in canvas points: normalized X and Y differ on a wide display.
    private func through(_ p: NSPoint, _ t: SceneNode.Transform, inverse: Bool = false) -> NSPoint {
        let c = NSPoint(x: sceneRect.midX, y: sceneRect.midY)
        let target = center(t), scale = CGFloat(t.scale ?? 1)
        let a = CGFloat(t.rotation ?? 0) * .pi / 180 * (inverse ? -1 : 1)
        let x = p.x - (inverse ? target.x : c.x), y = p.y - (inverse ? target.y : c.y)
        let factor = inverse ? 1 / scale : scale
        return NSPoint(x: (inverse ? c.x : target.x) + (x * cos(a) - y * sin(a)) * factor,
                       y: (inverse ? c.y : target.y) + (x * sin(a) + y * cos(a)) * factor)
    }
    private func local(_ p: NSPoint, index: Int) -> NSPoint {
        ancestors(of: index).reduce(p) { through($0, $1.transform, inverse: true) }
    }
    private func world(_ p: NSPoint) -> NSPoint {
        ancestors(of: selected).reversed().reduce(p) { through($0, $1.transform) }
    }
    func hitIndices(at p: NSPoint) -> [Int] {
        nodes.indices.reversed().filter { index in
            guard eligible(index) else { return false }
            var point = p
            for parent in ancestors(of: index) {
                guard contains(point, transform: parent.transform) else { return false }
                point = through(point, parent.transform, inverse: true)
                if parent.style.mask == .ellipse {
                    let x = (point.x - sceneRect.midX) / (sceneRect.width / 2)
                    let y = (point.y - sceneRect.midY) / (sceneRect.height / 2)
                    if x * x + y * y > 1 { return false }
                }
            }
            guard contains(point, transform: nodes[index].transform) else { return false }
            if nodes[index].style.mask == .ellipse {
                let untransformed = through(point, nodes[index].transform, inverse: true)
                let x = (untransformed.x - sceneRect.midX) / (sceneRect.width / 2)
                let y = (untransformed.y - sceneRect.midY) / (sceneRect.height / 2)
                return x * x + y * y <= 1
            }
            return true
        }
    }
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
        guard eligible(selected) else { return }
        let corners = corners(transform).map { world($0) }
        let path = NSBezierPath()
        path.move(to: corners[0])
        corners.dropFirst().forEach { path.line(to: $0) }
        path.close()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        NSColor.controlAccentColor.setFill()
        for corner in corners { NSBezierPath(rect: NSRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)).fill() }
        let handle = world(rotationHandle(transform))
        let stem = NSBezierPath()
        stem.move(to: world(point(0, sceneRect.height * (transform.scale ?? 1) / 2, transform)))
        stem.line(to: handle)
        stem.stroke()
        NSBezierPath(ovalIn: NSRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let editable = eligible(selected)
        if editable && distance(p, world(rotationHandle(transform))) < 12 { gesture = .rotate }
        else if editable && corners(transform).contains(where: { distance(p, world($0)) < 12 }) { gesture = .scale }
        else {
            // Option-click cycles through overlapping rectangles; normal click selects frontmost.
            let hits = hitIndices(at: p)
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
        origin = local(p, index: selected)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, sceneRect.width > 0, sceneRect.height > 0 else { return }
        let p = local(convert(event.locationInWindow, from: nil), index: selected)
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
        onPreviewTransform?(transform)
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
        guard isEnabled, eligible(selected) else { return }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let zero = local(.zero, index: selected)
        func nudge(_ x: Double, _ y: Double) {
            let delta = local(NSPoint(x: x, y: y), index: selected)
            onNudge?((delta.x - zero.x) / max(1, sceneRect.width), (delta.y - zero.y) / max(1, sceneRect.height))
        }
        switch event.keyCode {
        case 123: nudge(-step, 0)
        case 124: nudge(step, 0)
        case 125: nudge(0, -step)
        case 126: nudge(0, step)
        case 51, 117: onDelete?()
        default: super.keyDown(with: event)
        }
    }

    static func smokeTestNestedGeometry() {
        let overlay = SceneDragOverlay(frame: NSRect(x: 0, y: 0, width: 880, height: 480))
        let leaf = SceneNode(content: .gradient, transform: .init(x: 0.1, y: -0.1, scale: 0.3, rotation: 15))
        let inner = SceneNode(content: .group([leaf]), transform: .init(x: -0.1, y: 0.1, scale: 0.6, rotation: -30))
        let outer = SceneNode(content: .group([inner]), transform: .init(x: 0.1, y: 0, scale: 0.7, rotation: 90))
        overlay.roots = [outer]; overlay.selected = 2; overlay.transform = leaf.transform
        precondition(overlay.nodes.count == 3)
        let localPoint = overlay.center(leaf.transform)
        let screenPoint = overlay.world(localPoint)
        let roundTrip = overlay.local(screenPoint, index: 2)
        precondition(overlay.distance(localPoint, roundTrip) < 0.00001)
        precondition(overlay.hitIndices(at: screenPoint).first == 2)
        // A point in an overflowing child still cannot escape the parent canvas.
        let overflowing = SceneNode(content: .gradient, transform: .init(x: 1, y: 0, scale: 1, rotation: 0))
        overlay.roots = [SceneNode(content: .group([overflowing]))]
        precondition(!overlay.hitIndices(at: NSPoint(x: 900, y: 240)).contains(1))
        overlay.roots[0].locked = true
        precondition(overlay.hitIndices(at: NSPoint(x: 800, y: 240)).isEmpty)
        overlay.roots = [outer]
        var delta = NSPoint.zero
        overlay.onNudge = { delta = NSPoint(x: $0, y: $1) }
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        overlay.keyDown(with: right)
        let shifted = overlay.world(NSPoint(x: localPoint.x + delta.x * 800, y: localPoint.y + delta.y * 400))
        precondition(abs(shifted.x - screenPoint.x - 1) < 0.00001 && abs(shifted.y - screenPoint.y) < 0.00001)
    }
}
