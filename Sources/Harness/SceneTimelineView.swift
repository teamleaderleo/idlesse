import AppKit

/// Studio-only transport UI. Shares the host's existing status tick; owns no timer.
final class SceneTimelineView: NSStackView {
    private let label = NSTextField(labelWithString: "SCENE TIME")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 8, target: nil, action: nil)
    private let markers = TimelineMarkers()
    private let trackPicker = NSPopUpButton()
    private var targets: [ScenePropertyAddress] = []
    private var tracks: [SceneKeyframeTrack] = []
    private var chosenTarget: ScenePropertyAddress?
    private let loop = NSButton(title: "Loop Range", target: nil, action: nil)
    var onSeek: ((Double) -> Void)?
    var onLoop: ((Double) -> Void)?
    var onMoveKey: ((ScenePropertyAddress, Int, Double) -> Void)?
    var onEditTrack: ((ScenePropertyAddress, SceneKeyframeTrack, String) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 3
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(scrub)
        slider.setAccessibilityLabel("Scene playhead in seconds")
        slider.toolTip = "Scrub motion and opted-in videos; pauses playback."
        loop.target = self; loop.action = #selector(loopRange)
        let row = NSStackView(views: [label, slider, loop])
        row.spacing = 12
        addArrangedSubview(row)
        trackPicker.addItem(withTitle: "No keyframe tracks")
        trackPicker.target = self; trackPicker.action = #selector(selectTrack)
        trackPicker.setAccessibilityLabel("Timeline property track")
        trackPicker.toolTip = "Drag keys to edit time and value. Return edits exact values; arrows nudge time/value (Shift for larger steps). Double-click adds; Delete removes. ⌘C/⌘V copies and pastes a track."
        addArrangedSubview(trackPicker)
        markers.onMove = { [weak self] index, time in
            guard let self, let target = self.chosenTarget else { return }
            self.onMoveKey?(target, index, time)
        }
        markers.onEdit = { [weak self] track, name in
            guard let self, let target = self.chosenTarget else { return }
            self.onEditTrack?(target, track, name)
        }
        let markerRow = NSView()
        markers.translatesAutoresizingMaskIntoConstraints = false
        markerRow.addSubview(markers); addArrangedSubview(markerRow)
        markerRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        markerRow.heightAnchor.constraint(equalToConstant: 100).isActive = true
        markers.leadingAnchor.constraint(equalTo: slider.leadingAnchor).isActive = true
        markers.trailingAnchor.constraint(equalTo: slider.trailingAnchor).isActive = true
        markers.topAnchor.constraint(equalTo: markerRow.topAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        markers.heightAnchor.constraint(equalToConstant: 100).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(scene: SceneDescriptor, selectedID: UUID?, time: Double, enabled: Bool) {
        let tracks = scene.bindings.compactMap(\.keyframes)
        let end = max(0.01, scene.timeline?.duration ?? tracks.compactMap { $0.keys.last?.time }.max() ?? 8)
        slider.maxValue = end; slider.doubleValue = min(end, time)
        slider.isEnabled = enabled; loop.isEnabled = enabled
        label.stringValue = String(format: "%.2f s  /  %.2f s", time, end)
        let bindings = scene.bindings.filter { $0.target.nodeID == selectedID && $0.keyframes != nil }
        let nextTargets = bindings.map(\.target)
        if nextTargets != targets {
            targets = nextTargets
            trackPicker.removeAllItems()
            trackPicker.addItems(withTitles: targets.isEmpty ? ["No keyframe tracks"] : targets.map { $0.property.rawValue })
            if let chosenTarget, let index = targets.firstIndex(of: chosenTarget) { trackPicker.selectItem(at: index) }
            chosenTarget = targets.indices.contains(trackPicker.indexOfSelectedItem) ? targets[trackPicker.indexOfSelectedItem] : nil
            markers.cancelDrag()
        }
        self.tracks = bindings.compactMap(\.keyframes)
        trackPicker.isEnabled = !targets.isEmpty
        markers.editable = enabled && scene.allNodes.first(where: { $0.id == selectedID })?.locked == false
        markers.end = end
        updateMarkers()
    }
    private func updateMarkers() {
        let index = trackPicker.indexOfSelectedItem
        markers.track = tracks.indices.contains(index) ? tracks[index] : nil
        markers.needsDisplay = true
    }
    @objc private func selectTrack() {
        markers.cancelDrag()
        let index = trackPicker.indexOfSelectedItem
        chosenTarget = targets.indices.contains(index) ? targets[index] : nil
        updateMarkers()
    }
    @objc private func scrub() { onSeek?(slider.doubleValue) }
    @objc private func loopRange() { onLoop?(slider.maxValue) }
}

private final class TimelineMarkers: NSView, NSUserInterfaceValidations {
    var track: SceneKeyframeTrack? {
        didSet {
            if oldValue != track { draft = nil }
            if let selected, track?.keys.indices.contains(selected) != true { self.selected = nil }
        }
    }
    var editable = false
    var end: Double = 8
    var onMove: ((Int, Double) -> Void)?
    var onEdit: ((SceneKeyframeTrack, String) -> Void)?
    private var selected: Int?
    private var draft: SceneKeyframeTrack?
    private var dragEnd: Double = 8
    private var dragRange: ClosedRange<Double> = -1...1
    override var acceptsFirstResponder: Bool { true }
    func cancelDrag() { draft = nil; selected = nil; needsDisplay = true }
    private var valueRange: ClosedRange<Double> {
        if draft != nil { return dragRange }
        let values = track?.keys.map(\.value) ?? [0]
        let lower = values.min() ?? 0, upper = values.max() ?? 1
        let padding = max(0.01, max((upper - lower) * 0.15, abs(lower) * 0.05))
        return (lower - padding)...(upper + padding)
    }
    private func x(_ time: Double) -> CGFloat { CGFloat(time / (draft == nil ? end : dragEnd)) * max(1, bounds.width - 8) + 4 }
    private func y(_ value: Double) -> CGFloat {
        let range = valueRange
        return 8 + CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * max(1, bounds.height - 20)
    }
    private func time(at point: NSPoint, snap: Bool) -> Double {
        let limit = draft == nil ? end : dragEnd
        let value = min(limit, max(0, Double((point.x - 4) / max(1, bounds.width - 8)) * limit))
        return snap ? min(limit, value.rounded()) : (value * 1000).rounded() / 1000
    }
    override func mouseDown(with event: NSEvent) {
        guard editable, let track else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let nearest = track.keys.indices.min {
            hypot(x(track.keys[$0].time) - point.x, y(track.keys[$0].value) - point.y) <
            hypot(x(track.keys[$1].time) - point.x, y(track.keys[$1].value) - point.y)
        }
        if let nearest, hypot(x(track.keys[nearest].time) - point.x, y(track.keys[nearest].value) - point.y) <= 10 {
            selected = nearest; dragEnd = end; dragRange = valueRange; draft = track
        } else if event.clickCount == 2 {
            let position = time(at: point, snap: event.modifierFlags.contains(.shift))
            guard track.keys.count < 128, !track.keys.contains(where: { abs($0.time - position) < 0.001 }) else { return }
            var next = track
            next.keys.append(.init(time: position, value: (try? track.sample(at: position)) ?? 0))
            next.keys.sort { $0.time < $1.time }
            onEdit?(next, "Add Keyframe")
            selected = next.keys.firstIndex { $0.time == position }
            window?.makeFirstResponder(self)
        } else { cancelDrag() }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard editable, let selected, draft != nil, let track else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard var next = try? track.movingKey(at: selected, to: time(at: point, snap: event.modifierFlags.contains(.shift))) else { return }
        let fraction = Double((point.y - 8) / max(1, bounds.height - 20))
        let value = dragRange.lowerBound + fraction * (dragRange.upperBound - dragRange.lowerBound)
        next.keys[selected].value = min(1_000_000, max(-1_000_000, (value * 1000).rounded() / 1000))
        draft = next; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let draft, let track else { return }
        self.draft = nil
        if draft != track { onEdit?(draft, "Move Keyframe") }
        window?.makeFirstResponder(self); needsDisplay = true
    }
    @objc func copy(_ sender: Any?) {
        if let track, let data = try? JSONEncoder().encode(track) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .init("app.idlesse.keyframe-track"))
        }
    }
    @objc func paste(_ sender: Any?) {
        guard editable else { return }
            guard let data = NSPasteboard.general.data(forType: .init("app.idlesse.keyframe-track")), data.count <= 65_536,
                  let next = try? JSONDecoder().decode(SceneKeyframeTrack.self, from: data),
                  (try? next.sample(at: 0)) != nil else { NSSound.beep(); return }
            selected = nil
            onEdit?(next, "Paste Keyframe Track")
    }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return track != nil }
        if item.action == #selector(paste(_:)) { return editable && NSPasteboard.general.availableType(from: [.init("app.idlesse.keyframe-track")]) != nil }
        return false
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copy(nil); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" { paste(nil); return }
        guard editable, let selected, let track, track.keys.indices.contains(selected) else { super.keyDown(with: event); return }
        if event.keyCode == 36 {
            let alert = NSAlert()
            alert.messageText = "Edit Keyframe"
            alert.informativeText = "Time in seconds and source value, before binding modifiers."
            let time = NSTextField(string: String(track.keys[selected].time))
            let value = NSTextField(string: String(track.keys[selected].value))
            time.setAccessibilityLabel("Keyframe time in seconds")
            value.setAccessibilityLabel("Keyframe source value")
            let fields = NSStackView(views: [NSTextField(labelWithString: "Time"), time, NSTextField(labelWithString: "Value"), value])
            fields.orientation = .vertical; fields.alignment = .leading
            fields.frame = NSRect(x: 0, y: 0, width: 260, height: 104)
            time.widthAnchor.constraint(equalToConstant: 260).isActive = true
            value.widthAnchor.constraint(equalToConstant: 260).isActive = true
            alert.accessoryView = fields
            alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let seconds = Double(time.stringValue), let amount = Double(value.stringValue),
                  seconds.isFinite, amount.isFinite, abs(amount) <= 1_000_000 else { NSSound.beep(); return }
            var next = track
            next.keys[selected] = .init(time: seconds, value: amount)
            guard (try? next.sample(at: 0)) != nil else { NSSound.beep(); return }
            if next != track { onEdit?(next, "Edit Keyframe") }
        } else if event.keyCode == 125 || event.keyCode == 126 {
            var next = track
            let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.01
            next.keys[selected].value = min(1_000_000, max(-1_000_000, next.keys[selected].value + (event.keyCode == 126 ? step : -step)))
            onEdit?(next, "Nudge Keyframe Value")
        } else if event.keyCode == 51 || event.keyCode == 117 {
            guard track.keys.count > 1 else { NSSound.beep(); return }
            var next = track; next.keys.remove(at: selected)
            self.selected = nil; onEdit?(next, "Delete Keyframe")
        } else if event.keyCode == 123 || event.keyCode == 124 {
            let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
            onMove?(selected, track.keys[selected].time + (event.keyCode == 123 ? -step : step))
        } else { super.keyDown(with: event); return }
        window?.makeFirstResponder(self)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let track = draft ?? track else { return }
        NSColor.separatorColor.setStroke()
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: 0, y: 8)); axis.line(to: NSPoint(x: bounds.width, y: 8)); axis.stroke()
        let curve = NSBezierPath()
        let limit = draft == nil ? end : dragEnd
        // Bounded sampling visualizes hold, linear and ease-in-out without a display timer.
        for index in 0...256 {
            let time = Double(index) / 256 * limit
            let point = NSPoint(x: x(time), y: y((try? track.sample(at: time, validating: false)) ?? 0))
            if index == 0 { curve.move(to: point) } else { curve.line(to: point) }
        }
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke(); curve.stroke()
        for (index, key) in track.keys.enumerated() {
            (index == selected ? NSColor.labelColor : NSColor.controlAccentColor).setFill()
            let position = NSPoint(x: x(key.time), y: y(key.value))
            NSBezierPath(ovalIn: NSRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8)).fill()
        }
        if let selected, track.keys.indices.contains(selected) {
            let key = track.keys[selected]
            let text = String(format: "%.3f s · %.3f", key.time, key.value)
            (text as NSString).draw(at: NSPoint(x: 4, y: bounds.height - 13), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

/// Keeps sheet-local controls and their callback out of the window controller's state.
final class StudioControlAction: NSObject {
    var perform: () -> Void = {}
    @objc func changed() { perform() }
}
