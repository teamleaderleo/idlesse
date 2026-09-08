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
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 3
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(scrub)
        slider.setAccessibilityLabel("Scene playhead in seconds")
        slider.toolTip = "Scrub scene motion; pauses playback. Videos keep independent time."
        loop.target = self; loop.action = #selector(loopRange)
        let row = NSStackView(views: [label, slider, loop])
        row.spacing = 12
        addArrangedSubview(row)
        trackPicker.addItem(withTitle: "No keyframe tracks")
        trackPicker.target = self; trackPicker.action = #selector(selectTrack)
        trackPicker.setAccessibilityLabel("Timeline property track")
        trackPicker.toolTip = "Choose a property, then drag its keys. Arrow keys nudge a selected key; Escape cancels a drag."
        addArrangedSubview(trackPicker)
        markers.onMove = { [weak self] index, time in
            guard let self, let target = self.chosenTarget else { return }
            self.onMoveKey?(target, index, time)
        }
        let markerRow = NSView()
        markers.translatesAutoresizingMaskIntoConstraints = false
        markerRow.addSubview(markers); addArrangedSubview(markerRow)
        markerRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        markerRow.heightAnchor.constraint(equalToConstant: 18).isActive = true
        markers.leadingAnchor.constraint(equalTo: slider.leadingAnchor).isActive = true
        markers.trailingAnchor.constraint(equalTo: slider.trailingAnchor).isActive = true
        markers.topAnchor.constraint(equalTo: markerRow.topAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        markers.heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(scene: SceneDescriptor, selectedID: UUID?, time: Double, enabled: Bool) {
        let tracks = scene.bindings.compactMap(\.keyframes)
        let end = max(0.01, tracks.compactMap { $0.keys.last?.time }.max() ?? 8)
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

private final class TimelineMarkers: NSView {
    var track: SceneKeyframeTrack? {
        didSet {
            if oldValue != track { dragTime = nil }
            if let selected, track?.keys.indices.contains(selected) != true { self.selected = nil }
        }
    }
    var editable = false
    var end: Double = 8
    var onMove: ((Int, Double) -> Void)?
    private var selected: Int?
    private var dragTime: Double?
    private var dragEnd: Double = 8
    override var acceptsFirstResponder: Bool { true }
    func cancelDrag() { dragTime = nil; selected = nil; needsDisplay = true }
    private func x(_ time: Double) -> CGFloat { CGFloat(time / (dragTime == nil ? end : dragEnd)) * max(1, bounds.width - 8) + 4 }
    override func mouseDown(with event: NSEvent) {
        guard editable, let track else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        selected = track.keys.indices.min { abs(x(track.keys[$0].time) - point.x) < abs(x(track.keys[$1].time) - point.x) }
        guard let selected, abs(x(track.keys[selected].time) - point.x) <= 9 else { cancelDrag(); return }
        dragEnd = end; dragTime = track.keys[selected].time; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard editable, let selected, dragTime != nil, let track else { return }
        let point = convert(event.locationInWindow, from: nil)
        let time = min(dragEnd, max(0, Double((point.x - 4) / max(1, bounds.width - 8)) * dragEnd))
        dragTime = (try? track.movingKey(at: selected, to: (time * 1000).rounded() / 1000))?.keys[selected].time
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let selected, let time = dragTime, let track, track.keys.indices.contains(selected) else { return }
        dragTime = nil
        if time != track.keys[selected].time { onMove?(selected, time) }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag(); return }
        guard editable, let selected, let track, track.keys.indices.contains(selected),
              event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
        onMove?(selected, track.keys[selected].time + (event.keyCode == 123 ? -step : step))
        window?.makeFirstResponder(self)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: 9)); line.line(to: NSPoint(x: bounds.width, y: 9)); line.stroke()
        guard let track else { return }
        for (index, key) in track.keys.enumerated() {
            (index == selected ? NSColor.labelColor : NSColor.controlAccentColor).setFill()
            let position = x(index == selected ? dragTime ?? key.time : key.time)
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: position, y: 14)); diamond.line(to: NSPoint(x: position + 4, y: 9))
            diamond.line(to: NSPoint(x: position, y: 4)); diamond.line(to: NSPoint(x: position - 4, y: 9))
            diamond.close(); diamond.fill()
        }
    }
}

/// Keeps sheet-local controls and their callback out of the window controller's state.
final class StudioControlAction: NSObject {
    var perform: () -> Void = {}
    @objc func changed() { perform() }
}
