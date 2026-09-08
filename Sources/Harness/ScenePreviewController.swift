import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A small scene workbench. Previewing never changes the running desktop scene.
final class ScenePreviewController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let canvas = NSView()
    private let titleLabel = NSTextField(labelWithString: "Aurora")
    private let performanceLabel = NSTextField(labelWithString: "")
    private var performanceTimer: Timer?
    private let measureButton = NSButton(title: "Measure 10s", target: nil, action: nil)
    private var measurement: (time: Double, count: Int, gpuSeconds: Double, gpuFrames: Int)?
    private var measurementResult: String?
    private var presentationSample = PresentationRateSample()
    private let detailLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let engine = NSPopUpButton()
    private let frameRate = NSPopUpButton()
    private let applyButton = NSButton(title: "Use on Desktop", target: nil, action: nil)
    private var renderer: SceneRenderer?
    private var scene = SceneDescriptor(title: "Aurora", nodes: [SceneNode(content: .gradient)])
    private var selectedURL: URL?
    private var scopedURL: URL?
    private var watcher: SceneWatcher?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var paused = false
    private var asleep = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let clock = SceneClock()
    private let apply: (URL) -> Void
    var onClose: (() -> Void)?

    init(apply: @escaping (URL) -> Void) {
        self.apply = apply
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Idlesse · Scene Preview"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 480)
        window.delegate = self
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = sleeping
                self?.updatePlayback()
            }
            observers.append((workspace, token))
        }
        let token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main) { [weak self] _ in self?.updatePlayback() }
        observers.append((NotificationCenter.default, token))
        window.center()
        let root = window.contentView!
        frameRate.addItems(withTitles: SceneFrameRate.allCases.map { $0.title })
        frameRate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        frameRate.target = self
        frameRate.action = #selector(changeFrameRate)
        frameRate.toolTip = "Scene redraw rate for preview and desktop. Videos retain their source frame rate. Auto uses the renderer default."
        let rateToken = NotificationCenter.default.addObserver(forName: SceneFrameRate.changed,
            object: nil, queue: .main) { [weak self] _ in self?.updateFrameRate() }
        observers.append((NotificationCenter.default, rateToken))
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        performanceLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        performanceLabel.textColor = .secondaryLabelColor
        performanceLabel.toolTip = "Measured Metal drawable presentations per second. Video source frames may repeat. Native video and multiple standard layers are not measured."
        let heading = NSStackView(views: [titleLabel, detailLabel, performanceLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        let open = NSButton(title: "Open Scene…", target: self, action: #selector(choose))
        let sample = NSButton(title: "Aurora", target: self, action: #selector(showSample))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.toolTip = "Pause or resume this preview"
        engine.addItems(withTitles: ["Standard", "Metal · Experimental"])
        engine.target = self
        engine.action = #selector(changeEngine)
        engine.toolTip = "Compare the same scene using the two renderers"
        applyButton.target = self
        applyButton.action = #selector(useOnDesktop)
        applyButton.isEnabled = false
        measureButton.target = self
        measureButton.action = #selector(measure)
        measureButton.toolTip = "Measure this preview for ten seconds without changing the scene. GPU time excludes display scheduling and other apps."
        let controls = NSStackView(views: [open, sample, pauseButton, engine, measureButton, applyButton])
        controls.spacing = 10
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.black.cgColor
        canvas.layer?.cornerRadius = 12
        canvas.layer?.masksToBounds = true
        for child in [heading, canvas, controls, frameRate] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: frameRate.leadingAnchor, constant: -16),
            frameRate.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            frameRate.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            canvas.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            canvas.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -18),
            controls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
    }
    func show() {
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        if renderer == nil { rebuild() }
        watchPackage()
        updatePlayback()
        NSApp.activate(ignoringOtherApps: true)
    }
    private func rebuild() {
        let next: SceneRenderer
        let onError: (String) -> Void = { [weak self] message in self?.detailLabel.stringValue = message }
        do {
            let bounds = NSRect(origin: .zero, size: canvas.bounds.size)
            guard bounds.width > 0, bounds.height > 0 else { return }
            if engine.indexOfSelectedItem == 1 {
                next = try MetalSceneRenderer(playable: scene, bounds: bounds,
                    scale: window.backingScaleFactor, clock: clock, onError: onError)
            } else {
                next = try LayeredSceneRenderer(playable: scene, bounds: bounds,
                    scale: window.backingScaleFactor, clock: clock, onError: onError)
            }
        } catch {
            detailLabel.stringValue = error.localizedDescription
            return
        }
        renderer?.releaseResources()
        canvas.subviews.forEach { $0.removeFromSuperview() }
        next.view.autoresizingMask = [.width, .height]
        canvas.addSubview(next.view)
        cancelMeasurement()
        renderer = next
        presentationSample = PresentationRateSample()
        updateFrameRate()
        titleLabel.stringValue = scene.title
        detailLabel.stringValue = "\(scene.nodes.count) layer\(scene.nodes.count == 1 ? "" : "s") · \(engine.indexOfSelectedItem == 1 ? "Experimental SDR preview" : "Standard preview")"
        updatePlayback()
    }
    @objc private func changeFrameRate() {
        cancelMeasurement()
        SceneFrameRate.selected = SceneFrameRate.allCases[frameRate.indexOfSelectedItem]
    }
    private func updateFrameRate() {
        let maximum = window.screen?.maximumFramesPerSecond ?? 60
        frameRate.item(at: 1)?.title = "Match Display (\(maximum) Hz)"
        frameRate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        renderer?.setPreferredFrameRate(SceneFrameRate.selected.requested(maximum: maximum))
    }
    func windowDidChangeScreen(_ notification: Notification) { cancelMeasurement(); updateFrameRate() }
    private func updatePlayback() {
        let stopped = paused || asleep || ProcessInfo.processInfo.isLowPowerModeEnabled || !window.isVisible || window.isMiniaturized || NSApp.isHidden
        if stopped { cancelMeasurement() }
        clock.setPaused(stopped)
        renderer?.setPaused(stopped)
        pauseButton.title = paused ? "Resume" : "Pause"
        performanceTimer?.invalidate()
        performanceTimer = nil
        presentationSample = PresentationRateSample()
        updatePerformance()
        if !stopped && renderer?.diagnostics.animated == true && renderer?.presentedFrameCount != nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updatePerformance() }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            performanceTimer = timer
        }
    }
    private func cancelMeasurement() {
        measurement = nil
        measurementResult = nil
        measureButton.title = "Measure 10s"
    }
    @objc private func measure() {
        guard let renderer, renderer.diagnostics.state == .running,
              let count = renderer.presentedFrameCount, let gpu = renderer.gpuTotals else { return }
        measurementResult = nil
        measurement = (ProcessInfo.processInfo.systemUptime, count, gpu.seconds, gpu.frames)
        measureButton.isEnabled = false
        measureButton.title = "Measuring…"
    }
    private func updatePerformance() {
        measureButton.isEnabled = measurement == nil && renderer?.diagnostics.state == .running && renderer?.diagnostics.animated == true && renderer?.gpuTotals != nil

        guard let renderer else { performanceLabel.stringValue = ""; return }
        guard renderer.diagnostics.state == .running else {
            performanceLabel.stringValue = "Paused · no continuous rendering"
            return
        }
        guard renderer.diagnostics.animated else {
            performanceLabel.stringValue = "Still image · redraws only when needed"
            return
        }
        guard let count = renderer.presentedFrameCount else {
            performanceLabel.stringValue = "Presentation rate unavailable for this renderer"
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let measurement, let gpu = renderer.gpuTotals {
            let elapsed = now - measurement.time
            if elapsed >= 10 {
                let frames = gpu.frames - measurement.gpuFrames
                let rate = Double(count - measurement.count) / elapsed
                if frames > 0 {
                    let milliseconds = (gpu.seconds - measurement.gpuSeconds) * 1000 / Double(frames)
                    measurementResult = String(format: "10s sample: %.1f fps · GPU %.2f ms/frame", rate, milliseconds)
                } else {
                    measurementResult = "10s sample: no completed GPU frames"
                }
                self.measurement = nil
                measureButton.title = "Measure Again"
                measureButton.isEnabled = true
            }
        }
        if let measurementResult { performanceLabel.stringValue = measurementResult; return }
        if let rate = presentationSample.sample(count: count, time: now) {
            performanceLabel.stringValue = String(format: "%.0f presented fps", rate)
        } else {
            performanceLabel.stringValue = "Measuring presentation rate…"
        }
    }
    @objc private func togglePause() { paused.toggle(); updatePlayback() }
    @objc private func changeEngine() {
        let previous = renderer
        rebuild()
        if renderer === previous { engine.selectItem(at: engine.indexOfSelectedItem == 1 ? 0 : 1) }
    }
    @objc private func useOnDesktop() {
        guard let selectedURL else { return }
        window.close()
        apply(selectedURL)
    }
    @objc private func showSample() {
        cancelLoading()
        watcher = nil
        renderer?.releaseResources()
        renderer = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        selectedURL = nil
        applyButton.isEnabled = false
        scene = SceneDescriptor(title: "Aurora", nodes: [SceneNode(content: .gradient)])
        rebuild()
    }
    @objc private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Preview a scene"
        panel.prompt = "Preview"
        panel.allowedContentTypes = [.jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie,
            UTType(exportedAs: "com.teamleaderleo.idlesse.scene", conformingTo: .package)]
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }
    private func cancelLoading() { generation += 1; loadTask?.cancel(); loadTask = nil }
    private func load(_ url: URL) {
        cancelLoading()
        let request = generation
        detailLabel.stringValue = "Opening \(url.lastPathComponent)…"
        loadTask = Task { @MainActor [weak self] in
            let accessed = url.startAccessingSecurityScopedResource()
            var adopted = false
            defer { if accessed && !adopted { url.stopAccessingSecurityScopedResource() } }
            do {
                let next = try await LocalSceneSource().resolve(url)
                for node in next.nodes {
                    if case .video(let videoURL) = node.content {
                        let asset = AVURLAsset(url: videoURL)
                        let playable = try await asset.load(.isPlayable)
                        let duration = try await asset.load(.duration)
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        guard playable, duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else {
                            throw SceneError.invalid("That video could not be played.")
                        }
                    }
                }
                try Task.checkCancellation()
                guard let self, request == self.generation else { return }
                let previous = self.scene
                let previousRenderer = self.renderer
                self.scene = next
                self.rebuild()
                guard self.renderer !== previousRenderer else { self.scene = previous; return }
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = accessed ? url : nil
                adopted = true
                self.selectedURL = url
                self.applyButton.isEnabled = true
                self.loadTask = nil
                self.watchPackage()
            } catch {
                guard let self, request == self.generation, !Task.isCancelled else { return }
                self.detailLabel.stringValue = error.localizedDescription
                self.loadTask = nil
            }
        }
    }
    private func watchPackage() {
        watcher = nil
        guard let url = selectedURL, url.pathExtension.lowercased() == "idlesse", window.isVisible else { return }
        watcher = SceneWatcher(package: url, assets: scene.nodes.compactMap { $0.assetURL }) { [weak self] in
            self?.load(url)
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) { rebuild() }
    func windowDidChangeBackingProperties(_ notification: Notification) { rebuild() }
    func windowDidMiniaturize(_ notification: Notification) { updatePlayback() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePlayback() }
    func windowWillClose(_ notification: Notification) {
        cancelLoading()
        cancelMeasurement()
        watcher = nil
        clock.setPaused(true)
        performanceTimer?.invalidate()
        performanceTimer = nil
        renderer?.releaseResources()
        renderer = nil
        onClose?()
    }
    func applicationVisibilityChanged() { updatePlayback() }
    deinit {
        performanceTimer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
        loadTask?.cancel()
        renderer?.releaseResources()
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
