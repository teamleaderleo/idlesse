import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// Crops and softens a plain picture or video by writing its framing sidecar,
/// without re-exporting anything.
///
/// The crop box is the scene's bleed: everything outside it is never shown, and
/// each display fills itself from what is inside, keeping the focus point in
/// view. Outlines show exactly what every connected display ends up with, so a
/// crop that suits the wide panel but chops the laptop is visible before saving
/// instead of after. The sidecar is the whole result, so closing without saving
/// or resetting and saving leaves the file exactly as it was.
final class MediaFramingController: NSWindowController, NSWindowDelegate {
    private let media: URL
    private let access: AnyObject?
    private let onSaved: (URL) -> Void
    private let isVideo: Bool
    private var saved: SceneFraming
    private var framing: SceneFraming { didSet { framingChanged() } }
    private let canvas = MediaFramingCanvas()
    private let soften = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let softenValue = NSTextField(labelWithString: "Off")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let tone = ToneBox()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadTask: Task<Void, Never>?
    private let undo = UndoManager()
    /// Whether saving should also reload the desktop, asked once the window opens
    /// so the button can say so rather than surprising anyone.
    var isOnDesktop: () -> Bool = { false } { didSet { updateButtons() } }

    static func canFrame(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .image)
    }

    init(media: URL, access: AnyObject? = nil, onSaved: @escaping (URL) -> Void) {
        self.media = media
        self.access = access
        self.onSaved = onSaved
        let type = UTType(filenameExtension: media.pathExtension.lowercased())
        isVideo = type?.conforms(to: .audiovisualContent) ?? false
        let existing = (try? SceneFraming.beside(media)) ?? nil
        saved = existing ?? SceneFraming()
        framing = saved
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false))
        window?.title = "Framing — " + SceneLibraryController.displayTitle(media.deletingPathExtension().lastPathComponent)
        window?.minSize = NSSize(width: 720, height: 520)
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        window?.center()
        setup()
        load()
        framingChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        guard let root = window?.contentView else { return }
        canvas.onChange = { [weak self] focus, bleed, committed in
            guard let self else { return }
            if let committed {
                // The canvas only knows focus and bleed; keep the tone as it is.
                var previous = self.framing
                previous.focus = committed.focus
                previous.bleed = committed.bleed
                self.registerUndo(from: previous)
            }
            self.framing.focus = focus
            self.framing.bleed = bleed
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false

        soften.target = self
        soften.action = #selector(softenMoved)
        soften.isContinuous = true
        soften.doubleValue = framing.tone?.clamped.soften ?? 0
        tone.soften = soften.doubleValue
        let softenLabel = NSTextField(labelWithString: "Soften highlights")
        softenValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        softenValue.alignment = .right
        let softenRow = NSStackView(views: [softenLabel, soften, softenValue])
        softenRow.spacing = 8
        soften.widthAnchor.constraint(equalToConstant: 220).isActive = true
        softenValue.widthAnchor.constraint(equalToConstant: 36).isActive = true
        if !isVideo {
            // The wallpaper applies tone to video only; offering it for a still
            // would preview a change that never reaches the desktop.
            softenRow.isHidden = true
        }

        let hint = NSTextField(wrappingLabelWithString:
            "Drag to draw a crop box, or drag its edges. Everything outside the box stays off screen. Double-click to set the point each display keeps in view.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor

        for (button, action) in [(saveButton, #selector(save)), (revertButton, #selector(revert)), (resetButton, #selector(reset))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        saveButton.keyEquivalent = "\r"
        resetButton.toolTip = "Remove the crop, focus and softening"
        revertButton.toolTip = "Go back to the last saved framing"
        let buttons = NSStackView(views: [resetButton, revertButton, NSView(), saveButton])
        buttons.spacing = 10

        let controls = NSStackView(views: [hint, softenRow, summary, buttons])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        root.addSubview(controls)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            hint.widthAnchor.constraint(equalTo: controls.widthAnchor),
            summary.widthAnchor.constraint(equalTo: controls.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: controls.widthAnchor)
        ])
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        controls.setContentHuggingPriority(.required, for: .vertical)
        controls.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Media

    private func load() {
        canvas.displays = MediaFramingCanvas.connectedDisplays()
        if isVideo { loadVideo() } else { loadStill() }
    }

    private func loadVideo() {
        let asset = AVURLAsset(url: media)
        loadTask = Task { @MainActor [weak self] in
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw WallpaperError.noVideo }
                let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
                let size = CGRect(origin: .zero, size: natural).applying(transform).size
                guard let self, !Task.isCancelled else { return }
                let tone = self.tone
                let item = AVPlayerItem(asset: asset)
                // Reads the slider through the box on every frame, so dragging it
                // re-tones the loop live with no composition rebuilt.
                item.videoComposition = AVMutableVideoComposition(asset: asset) { request in
                    let source = request.sourceImage
                    let points = SceneTone(soften: tone.soften).curve.map { CIVector(x: $0.x, y: $0.y) }
                    let toned = tone.soften <= 0 ? source : source.applyingFilter("CIToneCurve", parameters: [
                        "inputPoint0": points[0], "inputPoint1": points[1], "inputPoint2": points[2],
                        "inputPoint3": points[3], "inputPoint4": points[4]]).cropped(to: source.extent)
                    request.finish(with: toned, context: nil)
                }
                let player = AVQueuePlayer()
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = false
                self.looper = AVPlayerLooper(player: player, templateItem: item)
                self.player = player
                self.canvas.setContent(size: size, player: player)
                player.play()
                self.framingChanged()
            } catch {
                self?.summary.stringValue = "This video could not be opened: " + error.localizedDescription
            }
        }
    }

    private func loadStill() {
        let url = media
        loadTask = Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGSize)? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 2400]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                var width = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? CGFloat(image.width)
                var height = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? CGFloat(image.height)
                if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
                return (image, CGSize(width: width, height: height))
            }.value
            guard let self, !Task.isCancelled else { return }
            guard let (image, size) = loaded else {
                self.summary.stringValue = "This picture could not be opened."
                return
            }
            self.canvas.setContent(size: size, image: image)
            self.framingChanged()
        }
    }

    // MARK: Editing

    @objc private func softenMoved() {
        let value = (soften.doubleValue * 100).rounded() / 100
        if NSApp.currentEvent?.type == .leftMouseDown { registerUndo(from: framing) }
        tone.soften = value
        framing.tone = value > 0 ? SceneTone(soften: value) : nil
    }

    private func registerUndo(from previous: SceneFraming) {
        undo.registerUndo(withTarget: self) { target in
            let current = target.framing
            target.apply(previous)
            target.registerUndo(from: current)
        }
        undo.setActionName("Change Framing")
    }

    private func apply(_ value: SceneFraming) {
        framing = value
        soften.doubleValue = value.tone?.clamped.soften ?? 0
        tone.soften = soften.doubleValue
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    private func framingChanged() {
        canvas.focus = framing.focus ?? .centre
        canvas.bleed = framing.bleed?.clamped ?? SceneBleed()
        let amount = framing.tone?.clamped.soften ?? 0
        softenValue.stringValue = amount > 0 ? String(format: "%.2f", amount) : "Off"
        summary.stringValue = describe()
        updateButtons()
    }

    private func updateButtons() {
        let dirty = normalized(framing) != normalized(saved)
        saveButton.isEnabled = dirty
        revertButton.isEnabled = dirty
        resetButton.isEnabled = normalized(framing) != normalized(SceneFraming())
        saveButton.title = isOnDesktop() ? "Save & Update Wallpaper" : "Save"
        window?.isDocumentEdited = dirty
    }

    private func normalized(_ value: SceneFraming) -> [Double] {
        let focus = value.focus?.clamped ?? .centre
        let bleed = value.bleed?.clamped ?? SceneBleed()
        return [focus.x, focus.y, bleed.top, bleed.left, bleed.bottom, bleed.right, value.tone?.clamped.soften ?? 0]
            .map { ($0 * 10000).rounded() / 10000 }
    }

    /// One line per display: how much of the frame it keeps, and whether the crop
    /// enlarges it past what the uncropped frame already needs on that panel.
    /// A 4K export on a 5K panel is always enlarged a little; only the part the
    /// crop adds is worth a warning, since that is what a re-rendered camera fixes.
    private func describe() -> String {
        guard let content = canvas.contentSize else { return "Loading…" }
        let bleed = framing.bleed?.clamped
        let focus = framing.focus ?? .centre
        var lines: [String] = []
        for display in canvas.displays {
            let region = focus.visibleRegion(content: content, display: display.points, bleed: bleed)
            let uncropped = SceneFocus.centre.visibleRegion(content: content, display: display.points)
            let enlargement = uncropped.width / max(region.width, 0.0001)
            var line = "\(display.name): shows \(Int((region.width * 100).rounded()))% × \(Int((region.height * 100).rounded()))% of the frame"
            if enlargement > 1.25 {
                line += String(format: ", enlarged %.1f× by the crop — a re-rendered camera would be sharper", enlargement)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    @objc private func revert() {
        registerUndo(from: framing)
        apply(saved)
    }

    @objc private func reset() {
        registerUndo(from: framing)
        apply(SceneFraming())
    }

    @objc private func save() {
        do {
            try framing.write(beside: media)
            saved = (try? SceneFraming.beside(media)) ?? nil ?? SceneFraming()
            framingChanged()
            onSaved(media)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t save the framing"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard saveButton.isEnabled else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the framing changes?"
        alert.informativeText = "Closing without saving leaves the file framed as it was."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !saveButton.isEnabled
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        canvas.setContent(size: nil)
        onClose?()
    }
    var onClose: (() -> Void)?
    deinit { withExtendedLifetime(access) {} }

    /// The slider's value as the composition handler reads it, off the main thread.
    private final class ToneBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        var soften: Double {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    static func smokeTest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framing-editor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("clip.mp4")
        try Data().write(to: media)
        let sidecar = SceneFraming.url(for: media)
        // Keys the editor does not own survive a save.
        try #"{"bleed":{"right":0.05},"note":"kept"}"#.data(using: .utf8)!.write(to: sidecar)
        var framing = try SceneFraming.beside(media)!
        framing.bleed = SceneBleed(top: 0.1, right: 0.05)
        framing.tone = SceneTone(soften: 0.3)
        try framing.write(beside: media)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
        precondition(written["note"] as? String == "kept", "unknown sidecar keys must survive")
        precondition(written["focus"] == nil, "a centred focus is not written")
        let read = try SceneFraming.beside(media)!
        precondition(read.bleed == SceneBleed(top: 0.1, right: 0.05) && read.tone == SceneTone(soften: 0.3))
        // Resetting drops what it owns; a sidecar with nothing left goes away.
        try SceneFraming().write(beside: media)
        precondition(FileManager.default.fileExists(atPath: sidecar.path), "the foreign key keeps the file")
        try #"{"bleed":{"right":0.05}}"#.data(using: .utf8)!.write(to: sidecar)
        try SceneFraming(focus: .centre, bleed: SceneBleed(), tone: SceneTone(soften: 0)).write(beside: media)
        precondition(!FileManager.default.fileExists(atPath: sidecar.path), "a neutral framing removes the sidecar")

        // The outline for a display is filledFrame read backwards.
        let content = CGSize(width: 3840, height: 2160)
        let laptop = CGSize(width: 1440, height: 932)
        let centred = SceneFocus.centre.visibleRegion(content: content, display: laptop)
        precondition(abs(centred.height - 1) < 1e-9 && abs(centred.midX - 0.5) < 1e-9,
            "a narrow display keeps the full height, centred")
        precondition(abs(centred.width - (2160.0 * 1440 / 932) / 3840) < 1e-9)
        let wide = SceneFocus.centre.visibleRegion(content: content, display: CGSize(width: 2560, height: 1440),
                                                   bleed: SceneBleed(top: 0.1))
        precondition(abs(wide.minY - 0.1) < 1e-9 && abs(wide.maxY - 1) < 1e-9,
            "a top margin keeps the top off screen and pins the bottom edge")
        let left = SceneFocus(x: 0, y: 0.5).visibleRegion(content: content, display: laptop)
        precondition(abs(left.minX) < 1e-9, "a focus at the left edge shows the left edge")

        let controller = MediaFramingController(media: media) { _ in }
        controller.canvas.setContent(size: content, image: nil)
        controller.framing.bleed = SceneBleed(left: 0.2)
        precondition(controller.saveButton.isEnabled && controller.canvas.bleed.left == 0.2)
        controller.reset()
        precondition(!controller.resetButton.isEnabled && !controller.saveButton.isEnabled)
        controller.undo.undo()
        precondition(controller.framing.bleed == SceneBleed(left: 0.2), "reset is undoable")
        controller.saveButton.isEnabled = false
        controller.close()
        print("Media framing smoke test passed")
    }
}

/// The frame, the crop box and one outline per display.
final class MediaFramingCanvas: NSView {
    struct Display {
        let name: String
        let points: CGSize
        let pixels: CGSize
    }
    var displays: [Display] = [] { didSet { overlay.needsDisplay = true } }
    var focus = SceneFocus.centre { didSet { overlay.needsDisplay = true } }
    var bleed = SceneBleed() { didSet { overlay.needsDisplay = true } }
    private(set) var contentSize: CGSize?
    /// Focus, bleed, and the framing before the gesture when one just finished.
    var onChange: ((SceneFocus, SceneBleed, SceneFraming?) -> Void)?

    private let host = NSView()
    private let overlay = Overlay()
    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius = 8
        host.wantsLayer = true
        overlay.canvas = self
        for view in [host, overlay] {
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Framing canvas; drag to crop, double-click to set the focus")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func connectedDisplays() -> [Display] {
        var seen = Set<String>()
        return NSScreen.screens.compactMap { screen in
            let points = screen.frame.size
            let pixels = CGSize(width: points.width * screen.backingScaleFactor, height: points.height * screen.backingScaleFactor)
            let key = "\(Int(points.width))x\(Int(points.height))"
            guard seen.insert(key).inserted else { return nil }
            return Display(name: screen.localizedName, points: points, pixels: pixels)
        }
    }

    func setContent(size: CGSize?, player: AVPlayer? = nil, image: CGImage? = nil) {
        playerLayer?.removeFromSuperlayer(); playerLayer = nil
        imageLayer?.removeFromSuperlayer(); imageLayer = nil
        contentSize = size
        if let player {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resize
            host.layer?.addSublayer(layer)
            playerLayer = layer
        } else if let image {
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            host.layer?.addSublayer(layer)
            imageLayer = layer
        }
        needsLayout = true
        overlay.needsDisplay = true
    }

    /// The frame fitted inside the canvas, in view coordinates.
    var contentRect: CGRect {
        guard let size = contentSize, size.width > 0, size.height > 0 else { return .zero }
        let area = bounds.insetBy(dx: 18, dy: 18)
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = contentRect
        imageLayer?.frame = contentRect
        CATransaction.commit()
        overlay.needsDisplay = true
    }

    private final class Overlay: NSView {
        weak var canvas: MediaFramingCanvas?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        private enum Drag {
            case edges(left: Bool, right: Bool, top: Bool, bottom: Bool)
            case move
            case draw(origin: CGPoint)
            case focus
        }
        private var drag: Drag?
        private var startPoint = CGPoint.zero
        private var startBleed = SceneBleed()
        private var startFraming: SceneFraming?
        private let minimumSpan = 0.1
        private let colours: [NSColor] = [.systemYellow, .systemTeal, .systemPink, .systemGreen]

        // Unit coordinates (top-left origin) <-> view points.
        private func point(_ u: Double, _ v: Double) -> CGPoint {
            let r = canvas?.contentRect ?? .zero
            return CGPoint(x: r.minX + CGFloat(u) * r.width, y: r.minY + CGFloat(v) * r.height)
        }
        private func unit(_ p: CGPoint) -> (Double, Double) {
            let r = canvas?.contentRect ?? .zero
            guard r.width > 0, r.height > 0 else { return (0.5, 0.5) }
            return (Double((p.x - r.minX) / r.width), Double((p.y - r.minY) / r.height))
        }
        private func rect(_ region: CGRect) -> CGRect {
            let a = point(region.minX, region.minY), b = point(region.maxX, region.maxY)
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        private var cropRect: CGRect {
            guard let canvas else { return .zero }
            let b = canvas.bleed
            return rect(CGRect(x: b.left, y: b.top, width: 1 - b.left - b.right, height: 1 - b.top - b.bottom))
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let canvas, canvas.contentSize != nil else { return }
            let content = canvas.contentRect
            let crop = cropRect
            // Shade what never reaches a display.
            let shade = NSBezierPath(rect: content)
            shade.append(NSBezierPath(rect: crop))
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.6).setFill()
            shade.fill()

            if let size = canvas.contentSize {
                for (index, display) in canvas.displays.enumerated() {
                    let colour = colours[index % colours.count]
                    let region = rect(canvas.focus.visibleRegion(content: size, display: display.points, bleed: canvas.bleed))
                    let outline = NSBezierPath(rect: region.insetBy(dx: 1, dy: 1))
                    outline.lineWidth = 2
                    outline.setLineDash([7, 4], count: 2, phase: CGFloat(index) * 5)
                    colour.setStroke()
                    outline.stroke()
                    let label = NSAttributedString(string: " \(display.name) ", attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: NSColor.black,
                        .backgroundColor: colour])
                    let labelSize = label.size()
                    let y = index % 2 == 0 ? region.minY + 4 : region.maxY - labelSize.height - 4
                    label.draw(at: CGPoint(x: region.minX + 4, y: y))
                }
            }

            let border = NSBezierPath(rect: crop)
            border.lineWidth = 1.5
            NSColor.white.setStroke()
            border.stroke()
            NSColor.white.setFill()
            for handle in handles(of: crop) { NSBezierPath(rect: CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8)).fill() }

            let f = point(canvas.focus.clamped.x, canvas.focus.clamped.y)
            let ring = NSBezierPath(ovalIn: CGRect(x: f.x - 9, y: f.y - 9, width: 18, height: 18))
            ring.lineWidth = 2
            NSColor.white.setStroke()
            ring.stroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: f.x - 14, y: f.y)); cross.line(to: CGPoint(x: f.x + 14, y: f.y))
            cross.move(to: CGPoint(x: f.x, y: f.y - 14)); cross.line(to: CGPoint(x: f.x, y: f.y + 14))
            cross.lineWidth = 1
            cross.stroke()
        }

        private func handles(of r: CGRect) -> [CGPoint] {
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
             CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        }

        private func hit(_ p: CGPoint) -> Drag? {
            guard let canvas, canvas.contentSize != nil else { return nil }
            let f = point(canvas.focus.clamped.x, canvas.focus.clamped.y)
            if hypot(p.x - f.x, p.y - f.y) <= 12 { return .focus }
            let r = cropRect, slop: CGFloat = 7
            let withinX = p.x >= r.minX - slop && p.x <= r.maxX + slop
            let withinY = p.y >= r.minY - slop && p.y <= r.maxY + slop
            let left = withinY && abs(p.x - r.minX) <= slop, right = withinY && abs(p.x - r.maxX) <= slop
            let top = withinX && abs(p.y - r.minY) <= slop, bottom = withinX && abs(p.y - r.maxY) <= slop
            if left || right || top || bottom { return .edges(left: left, right: right, top: top, bottom: bottom) }
            if r.contains(p) { return .move }
            return canvas.contentRect.insetBy(dx: -slop, dy: -slop).contains(p) ? .draw(origin: p) : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            switch hit(convert(event.locationInWindow, from: nil)) {
            case .edges(let l, let r, let t, let b)?:
                if (l || r) && !(t || b) { NSCursor.resizeLeftRight.set() }
                else if (t || b) && !(l || r) { NSCursor.resizeUpDown.set() }
                else { NSCursor.crosshair.set() }
            case .move?: NSCursor.openHand.set()
            case .focus?: NSCursor.pointingHand.set()
            case .draw?: NSCursor.crosshair.set()
            case nil: NSCursor.arrow.set()
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let canvas else { return }
            let p = convert(event.locationInWindow, from: nil)
            startFraming = SceneFraming(focus: canvas.focus, bleed: canvas.bleed)
            if event.clickCount == 2, canvas.contentRect.contains(p) {
                let (u, v) = unit(p)
                emit(focus: SceneFocus(x: u, y: v).clamped, bleed: canvas.bleed, committed: true)
                drag = nil
                return
            }
            drag = hit(p)
            startPoint = p
            startBleed = canvas.bleed
            if case .move? = drag { NSCursor.closedHand.set() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let canvas, let drag else { return }
            let p = convert(event.locationInWindow, from: nil)
            let (u, v) = unit(p)
            let (u0, v0) = unit(startPoint)
            var b = startBleed
            let limit = 0.45
            func clampUnit(_ x: Double) -> Double { min(max(x, 0), 1) }
            switch drag {
            case .focus:
                emit(focus: SceneFocus(x: clampUnit(u), y: clampUnit(v)), bleed: b, committed: false)
                return
            case .edges(let left, let right, let top, let bottom):
                if left { b.left = min(max(clampUnit(u), 0), min(limit, 1 - b.right - minimumSpan)) }
                if right { b.right = min(max(1 - clampUnit(u), 0), min(limit, 1 - b.left - minimumSpan)) }
                if top { b.top = min(max(clampUnit(v), 0), min(limit, 1 - b.bottom - minimumSpan)) }
                if bottom { b.bottom = min(max(1 - clampUnit(v), 0), min(limit, 1 - b.top - minimumSpan)) }
            case .move:
                // Slide the box whole; each margin stays within what the renderer honours.
                let width = 1 - startBleed.left - startBleed.right, height = 1 - startBleed.top - startBleed.bottom
                func slide(_ start: Double, by delta: Double, span: Double) -> Double {
                    min(max(start + delta, max(0, 1 - span - limit)), min(limit, 1 - span))
                }
                b.left = slide(startBleed.left, by: u - u0, span: width); b.right = 1 - width - b.left
                b.top = slide(startBleed.top, by: v - v0, span: height); b.bottom = 1 - height - b.top
            case .draw(let origin):
                let (ou, ov) = unit(origin)
                let x0 = clampUnit(min(ou, u)), x1 = clampUnit(max(ou, u))
                let y0 = clampUnit(min(ov, v)), y1 = clampUnit(max(ov, v))
                guard x1 - x0 >= 0.02 || y1 - y0 >= 0.02 else { return }
                b = SceneBleed(top: min(y0, limit), left: min(x0, limit),
                               bottom: min(1 - max(y1, y0 + minimumSpan), limit),
                               right: min(1 - max(x1, x0 + minimumSpan), limit))
            }
            for edge in [\SceneBleed.top, \.left, \.bottom, \.right] { b[keyPath: edge] = max(0, b[keyPath: edge]) }
            emit(focus: canvas.focus, bleed: b, committed: false)
        }

        override func mouseUp(with event: NSEvent) {
            guard let canvas, drag != nil else { return }
            drag = nil
            emit(focus: canvas.focus, bleed: canvas.bleed, committed: true)
            mouseMoved(with: event)
        }

        private func emit(focus: SceneFocus, bleed: SceneBleed, committed: Bool) {
            guard let canvas else { return }
            let rounded = { (x: Double) in (x * 10000).rounded() / 10000 }
            let b = SceneBleed(top: rounded(bleed.top), left: rounded(bleed.left),
                               bottom: rounded(bleed.bottom), right: rounded(bleed.right))
            let f = SceneFocus(x: rounded(focus.x), y: rounded(focus.y))
            let before = committed ? startFraming : nil
            if committed, let before, before.focus == f, before.bleed == b { canvas.onChange?(f, b, nil); return }
            canvas.onChange?(f, b, before)
        }
    }
}
