import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// Crops and adjusts a plain picture or video by writing its framing sidecar,
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
    /// One slider per picture adjustment, in the order they read best.
    private let adjustments: [Adjustment] = [
        Adjustment(title: "Exposure", key: \.exposure, range: -1.5...1, format: "%+.2f EV"),
        Adjustment(title: "Highlights", key: \.soften, range: 0...1, format: "−%.2f"),
        Adjustment(title: "Contrast", key: \.contrast, range: -1...1, format: "%+.2f"),
        Adjustment(title: "Saturation", key: \.saturation, range: -1...1, format: "%+.2f")
    ]
    private let compare = NSButton(checkboxWithTitle: "Show original", target: nil, action: nil)
    private final class Adjustment {
        let title: String
        let key: WritableKeyPath<SceneTone, Double>
        let format: String
        let slider: NSSlider
        let value = NSTextField(labelWithString: "")
        init(title: String, key: WritableKeyPath<SceneTone, Double>, range: ClosedRange<Double>, format: String) {
            self.title = title; self.key = key; self.format = format
            slider = NSSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        }
    }
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let rerenderButton = NSButton(title: "Re-render Camera…", target: nil, action: nil)
    private var rerender: Process?
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

        let grid = NSGridView()
        grid.columnSpacing = 10
        grid.rowSpacing = 6
        for adjustment in adjustments {
            adjustment.slider.target = self
            adjustment.slider.action = #selector(adjustmentMoved(_:))
            adjustment.slider.isContinuous = true
            adjustment.slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
            adjustment.value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            adjustment.value.widthAnchor.constraint(equalToConstant: 72).isActive = true
            grid.addRow(with: [NSTextField(labelWithString: adjustment.title), adjustment.slider, adjustment.value])
        }
        compare.target = self
        compare.action = #selector(compareToggled)
        compare.toolTip = "Preview without the adjustments; nothing is saved"
        grid.addRow(with: [NSGridCell.emptyContentView, compare, NSGridCell.emptyContentView])
        syncSliders()
        let softenRow = grid
        if !isVideo {
            // The wallpaper applies adjustments to video only; offering them for
            // a still would preview a change that never reaches the desktop.
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
        resetButton.toolTip = "Remove the crop, focus and adjustments"
        revertButton.toolTip = "Go back to the last saved framing"
        rerenderButton.target = self
        rerenderButton.action = #selector(rerenderCamera)
        rerenderButton.bezelStyle = .rounded
        rerenderButton.toolTip = "Render the video again with the crop box as its camera, for full sharpness"
        rerenderButton.isHidden = Pipeline.current(for: media) == nil
        let buttons = NSStackView(views: [resetButton, revertButton, NSView(), rerenderButton, saveButton])
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

    // MARK: Re-render

    /// The export pipeline, when this Mac has one and the file came out of it.
    /// `ingest.py` records its own paths in the app's defaults each time it runs.
    struct Pipeline {
        let interpreter: URL
        let script: URL
        let workspace: URL
        static func current(for media: URL) -> Pipeline? {
            let defaults = UserDefaults.standard
            guard let interpreter = defaults.string(forKey: "IdlessePipelineInterpreter"),
                  let script = defaults.string(forKey: "IdlessePipelineScript"),
                  let workspace = defaults.string(forKey: "IdlessePipelineWorkspace"),
                  FileManager.default.isExecutableFile(atPath: interpreter),
                  FileManager.default.fileExists(atPath: script) else { return nil }
            let receipt = media.deletingPathExtension().appendingPathExtension("source.json")
            guard let data = try? Data(contentsOf: receipt),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["asset"] is String, object["animation"] is String else { return nil }
            return Pipeline(interpreter: URL(fileURLWithPath: interpreter), script: URL(fileURLWithPath: script),
                            workspace: URL(fileURLWithPath: workspace))
        }
    }

    @objc private func rerenderCamera() {
        if let rerender {
            rerender.terminate()
            return
        }
        guard let pipeline = Pipeline.current(for: media), let window else { return }
        guard !(framing.bleed?.clamped.isEmpty ?? true) else {
            summary.stringValue = "Draw a crop box first; the re-render makes that box the whole frame."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Re-render with this crop as the camera?"
        alert.informativeText = "The video is rendered again on this Mac from its upscaled textures, so the crop keeps full detail. The current file is archived first, and the crop box and focus are cleared afterwards because the new video is already cropped. Adjustments are kept.\n\nIf this scene was never upscaled, nothing is rendered or billed; the pipeline stops and says so."
        alert.addButton(withTitle: "Re-render")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if self.saveButton.isEnabled { self.save() }
            guard !self.saveButton.isEnabled else { return }
            self.startRerender(pipeline)
        }
    }

    private func startRerender(_ pipeline: Pipeline) {
        let process = Process()
        process.executableURL = pipeline.interpreter
        process.arguments = [pipeline.script.path, "--reframe", media.path, "--from-sidecar", "--workspace", pipeline.workspace.path]
        process.currentDirectoryURL = pipeline.workspace
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let line = output.append(data)
            DispatchQueue.main.async { if let line { self?.summary.stringValue = line } }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.finishRerender(finished, output: output.text) }
        }
        do {
            try process.run()
        } catch {
            summary.stringValue = "Couldn’t start the pipeline: " + error.localizedDescription
            return
        }
        rerender = process
        rerenderButton.title = "Stop Re-render"
        for control in [saveButton, revertButton, resetButton] { control.isEnabled = false }
        canvas.isEditable = false
        adjustments.forEach { $0.slider.isEnabled = false }
        summary.stringValue = "Rendering a preview…"
    }

    private func finishRerender(_ process: Process, output: String) {
        rerender = nil
        rerenderButton.title = "Re-render Camera…"
        canvas.isEditable = true
        adjustments.forEach { $0.slider.isEnabled = true }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            framingChanged()
            let alert = NSAlert()
            alert.messageText = process.terminationReason == .uncaughtSignal ? "Re-render stopped" : "Re-render didn’t finish"
            alert.informativeText = output.split(separator: "\n").suffix(12).joined(separator: "\n")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        // The pipeline replaced the file in place and cleared the crop it used.
        saved = (try? SceneFraming.beside(media)) ?? nil ?? SceneFraming()
        framing = saved
        onSaved(media)
        looper?.disableLooping(); looper = nil; player?.pause(); player = nil
        canvas.setContent(size: nil)
        load()
        summary.stringValue = "Re-rendered. " + (output.split(separator: "\n").last(where: { $0.hasPrefix("Installed") }).map(String.init) ?? "")
    }

    /// Collects pipeline output from the reading thread; hands back the latest whole line.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        func append(_ chunk: Data) -> String? {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
            if data.count > 256_000 { data.removeFirst(data.count - 256_000) }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
        }
    }

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
                // Reads the sliders through the box on every frame, so dragging
                // one re-adjusts the loop live with no composition rebuilt.
                item.videoComposition = AVMutableVideoComposition(asset: asset) { request in
                    request.finish(with: tone.value.apply(to: request.sourceImage), context: nil)
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

    @objc private func adjustmentMoved(_ sender: NSSlider) {
        guard let adjustment = adjustments.first(where: { $0.slider === sender }) else { return }
        if NSApp.currentEvent?.type == .leftMouseDown { registerUndo(from: framing) }
        var value = framing.tone ?? SceneTone()
        value[keyPath: adjustment.key] = (sender.doubleValue * 100).rounded() / 100
        framing.tone = value.isNeutral ? nil : value
    }

    @objc private func compareToggled() { framingChanged() }

    private func syncSliders() {
        let value = framing.tone?.clamped ?? SceneTone()
        for adjustment in adjustments {
            let amount = value[keyPath: adjustment.key]
            adjustment.slider.doubleValue = amount
            adjustment.value.stringValue = amount == 0 ? "—" : String(format: adjustment.format, amount)
        }
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
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    private func framingChanged() {
        canvas.focus = framing.focus ?? .centre
        canvas.bleed = framing.bleed?.clamped ?? SceneBleed()
        tone.value = compare.state == .on ? SceneTone() : (framing.tone ?? SceneTone())
        syncSliders()
        player.map { if $0.rate == 0 { $0.seek(to: $0.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) } }
        summary.stringValue = describe()
        updateButtons()
    }

    private func updateButtons() {
        let dirty = normalized(framing) != normalized(saved)
        guard rerender == nil else { return }
        saveButton.isEnabled = dirty
        revertButton.isEnabled = dirty
        resetButton.isEnabled = normalized(framing) != normalized(SceneFraming())
        saveButton.title = isOnDesktop() ? "Save & Update Wallpaper" : "Save"
        window?.isDocumentEdited = dirty
    }

    private func normalized(_ value: SceneFraming) -> [Double] {
        let focus = value.focus?.clamped ?? .centre
        let bleed = value.bleed?.clamped ?? SceneBleed()
        return [focus.x, focus.y, bleed.top, bleed.left, bleed.bottom, bleed.right, value.tone?.clamped.soften ?? 0, value.tone?.clamped.exposure ?? 0,
                value.tone?.clamped.contrast ?? 0, value.tone?.clamped.saturation ?? 0]
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
        if rerender != nil {
            summary.stringValue = "Stop the re-render before closing."
            NSSound.beep()
            return false
        }
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
        rerender?.terminate()
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
    /// The adjustments as the composition handler reads them, off the main thread.
    private final class ToneBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = SceneTone()
        var value: SceneTone {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
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
        framing.tone = SceneTone(soften: 0.3, exposure: -0.25)
        try framing.write(beside: media)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
        precondition(written["note"] as? String == "kept", "unknown sidecar keys must survive")
        precondition(written["focus"] == nil, "a centred focus is not written")
        let read = try SceneFraming.beside(media)!
        precondition(read.bleed == SceneBleed(top: 0.1, right: 0.05) && read.tone == SceneTone(soften: 0.3, exposure: -0.25))
        let tone = written["tone"] as! [String: Double]
        precondition(tone.keys.sorted() == ["exposure", "soften"], "neutral adjustments are not written")
        // Resetting drops what it owns; a sidecar with nothing left goes away.
        try SceneFraming().write(beside: media)
        precondition(FileManager.default.fileExists(atPath: sidecar.path), "the foreign key keeps the file")
        try #"{"bleed":{"right":0.05}}"#.data(using: .utf8)!.write(to: sidecar)
        try SceneFraming(focus: .centre, bleed: SceneBleed(), tone: SceneTone(soften: 0)).write(beside: media)
        precondition(!FileManager.default.fileExists(atPath: sidecar.path), "a neutral framing removes the sidecar")

        // Adjustments run in Core Image's linear working space, between the
        // decode and encode the video handler performs; this context does the same.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: srgb)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let managed = CIContext(options: [.outputColorSpace: srgb])
        func level(_ tone: SceneTone) -> Double {
            var pixel = [Float](repeating: 0, count: 4)
            managed.render(tone.apply(to: grey), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: srgb)
            return Double(pixel[0])
        }
        precondition(abs(level(SceneTone()) - 0.5) < 0.002, "neutral leaves pixels alone")
        precondition(abs(level(SceneTone(exposure: -1)) - 0.3613) < 0.01, "one stop down halves linear light: \(level(SceneTone(exposure: -1)))")
        precondition(abs(level(SceneTone(saturation: 1)) - 0.5) < 0.002, "grey has no saturation to change")
        precondition(abs(level(SceneTone(soften: 1)) - 0.48) < 0.01, "soften barely moves mid-grey: \(level(SceneTone(soften: 1)))")
        let decoded = try JSONDecoder().decode(SceneTone.self, from: #"{"exposure":-0.3,"contrast":9}"#.data(using: .utf8)!)
        precondition(decoded.exposure == -0.3 && decoded.clamped.contrast == 1 && decoded.soften == 0 && !decoded.isNeutral)

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

        // Real mouse handling, driven through the overlay as AppKit would.
        let window = controller.window!
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.canvas.layoutSubtreeIfNeeded()
        // No event loop runs here, so close the implicit group the steps above
        // opened, and group each gesture the way one event would.
        controller.undo.removeAllActions()
        controller.undo.groupsByEvent = false
        controller.undo.beginUndoGrouping(); controller.reset(); controller.undo.endUndoGrouping()
        let overlay = controller.canvas.overlay
        func at(_ u: Double, _ v: Double) -> NSPoint {
            let r = controller.canvas.contentRect
            return overlay.convert(NSPoint(x: r.minX + CGFloat(u) * r.width, y: r.minY + CGFloat(v) * r.height), to: nil)
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func drag(from a: (Double, Double), to b: (Double, Double)) {
            controller.undo.beginUndoGrouping(); defer { controller.undo.endUndoGrouping() }
            overlay.mouseDown(with: event(.leftMouseDown, at(a.0, a.1)))
            overlay.mouseDragged(with: event(.leftMouseDragged, at((a.0 + b.0) / 2, (a.1 + b.1) / 2)))
            overlay.mouseDragged(with: event(.leftMouseDragged, at(b.0, b.1)))
            overlay.mouseUp(with: event(.leftMouseUp, at(b.0, b.1)))
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
        precondition(overlay.isFlipped && controller.canvas.contentRect.width > 100, "canvas laid out")
        drag(from: (0.2, 0.1), to: (0.8, 0.7))
        var b = controller.canvas.bleed
        precondition(near(b.left, 0.2) && near(b.top, 0.1) && near(b.right, 0.2) && near(b.bottom, 0.3),
                     "the first drag draws a box: \(b)")
        drag(from: (0.2, 0.4), to: (0.1, 0.4))
        b = controller.canvas.bleed
        precondition(near(b.left, 0.1) && near(b.right, 0.2), "dragging the left edge moves only that edge: \(b)")
        drag(from: (0.5, 0.4), to: (0.55, 0.35))
        b = controller.canvas.bleed
        precondition(near(b.left, 0.15) && near(b.right, 0.15) && near(b.top, 0.05) && near(b.bottom, 0.35),
                     "dragging inside slides the box without resizing: \(b)")
        drag(from: (0.5, 0.4), to: (-0.5, 0.4))
        b = controller.canvas.bleed
        precondition(b.left >= 0 && near(1 - b.left - b.right, 0.7), "sliding stops at the frame edge: \(b)")
        let point = at(0.3, 0.6)
        controller.undo.beginUndoGrouping()
        overlay.mouseDown(with: event(.leftMouseDown, point, clicks: 2))
        overlay.mouseUp(with: event(.leftMouseUp, point, clicks: 2))
        controller.undo.endUndoGrouping()
        precondition(near(controller.framing.focus?.x ?? 0, 0.3) && near(controller.framing.focus?.y ?? 0, 0.6),
                     "double-click sets the focus: \(String(describing: controller.framing.focus))")
        controller.undo.undo()
        precondition(controller.framing.focus == nil || controller.framing.focus == .centre, "focus change undoes")
        controller.undo.undo()
        precondition(near(controller.canvas.bleed.left, 0.15), "each drag is one undo step: \(controller.canvas.bleed)")
        precondition(controller.summary.stringValue.contains("% of the frame"), "per-display summary is shown")
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
    /// Off while a re-render uses the saved crop, so the box cannot drift from it.
    var isEditable = true
    /// Focus, bleed, and the framing before the gesture when one just finished.
    var onChange: ((SceneFocus, SceneBleed, SceneFraming?) -> Void)?

    private let host = NSView()
    fileprivate let overlay = Overlay()
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

    fileprivate final class Overlay: NSView {
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
            // Without a crop the box is the whole frame, so there is nothing to
            // move: a drag inside it draws the first box instead.
            if r.contains(p) { return canvas.bleed.clamped.isEmpty ? .draw(origin: p) : .move }
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
            guard let canvas, canvas.isEditable else { return }
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
