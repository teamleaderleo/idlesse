import AppKit

/// Studio-only transport UI. Shares the host's existing status tick; owns no timer.
final class SceneTimelineView: NSStackView {
    private let label = NSTextField(labelWithString: "SCENE TIME")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 8, target: nil, action: nil)
    private let markers = TimelineMarkers()
    private let loop = NSButton(title: "Loop Range", target: nil, action: nil)
    var onSeek: ((Double) -> Void)?
    var onLoop: ((Double) -> Void)?
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
        markers.times = scene.bindings.filter { $0.target.nodeID == selectedID }
            .flatMap { $0.keyframes?.keys.map(\.time) ?? [] }
        markers.end = end; markers.needsDisplay = true
    }
    @objc private func scrub() { onSeek?(slider.doubleValue) }
    @objc private func loopRange() { onLoop?(slider.maxValue) }
}

private final class TimelineMarkers: NSView {
    var times: [Double] = []
    var end: Double = 8
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: 9)); line.line(to: NSPoint(x: bounds.width, y: 9)); line.stroke()
        NSColor.controlAccentColor.setFill()
        for time in Set(times) {
            let x = CGFloat(time / end) * max(0, bounds.width - 8) + 4
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: x, y: 14)); diamond.line(to: NSPoint(x: x + 4, y: 9))
            diamond.line(to: NSPoint(x: x, y: 4)); diamond.line(to: NSPoint(x: x - 4, y: 9))
            diamond.close(); diamond.fill()
        }
    }
}

/// Keeps sheet-local controls and their callback out of the window controller's state.
final class StudioControlAction: NSObject {
    var perform: () -> Void = {}
    @objc func changed() { perform() }
}
