import AppKit
import ScreenSaver

@objc(IdlesseView)
final class IdlesseView: ScreenSaverView {
    private static let configureController = ConfigureSheetController(
        preferences: IdlessePreferences.shared,
        onSave: {}
    )

    // Tahoe may create several ScreenSaverView instances while the Wallpaper pane
    // is open. Keep the settings controller process-wide so every Options click
    // resolves to the same long-lived window instead of creating duplicates.
    private static var nextInstanceID = 0

    private static let diagnosticURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("idlesse-diag.log")

    private static let diagnosticFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let instanceID: Int = {
        IdlesseView.nextInstanceID += 1
        return IdlesseView.nextInstanceID
    }()

    private let canvas = ImageCanvasView(frame: .zero)
    private let preferences: IdlessePreferences

    private lazy var library = ImageLibrary(preferences: preferences)

    private var displayTimer: Timer?
    private var fadeTimer: Timer?
    private var libraryRefreshTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var fadeStartedAt: TimeInterval = 0
    private var currentURL: URL?
    private var nextURL: URL?
    private let sceneSource: SceneSource = LocalSceneSource()
    private var imageLoad: Task<Void, Never>?
    private var imageGeneration = 0

    private var running = false
    private(set) var isPlaybackPaused = false
    var displayedFileURL: URL? { currentURL }
    var retainedImageCount: Int {
        (canvas.currentImage == nil ? 0 : 1) + (canvas.nextImage == nil ? 0 : 1)
    }

    /// Preview controls never intercept keys in the system screen saver.
    func togglePlaybackPause() {
        guard running else { return }
        isPlaybackPaused.toggle()
        if isPlaybackPaused {
            displayTimer?.invalidate()
            displayTimer = nil
            if canvas.nextImage != nil {
                fadeTimer?.invalidate()
                fadeTimer = nil
                finishTransition()
            }
        } else {
            scheduleNextImage()
        }
    }

    func showNextImage() {
        guard running else { return }
        displayTimer?.invalidate()
        fadeTimer?.invalidate()
        displayTimer = nil
        fadeTimer = nil
        if canvas.nextImage != nil { finishTransition() }
        displayTimer?.invalidate()
        displayTimer = nil
        beginTransition()
    }

    override init(frame: NSRect, isPreview: Bool) {
        preferences = .shared
        super.init(frame: frame, isPreview: isPreview)!
        commonInit()
        diagnostic("init(frame:isPreview:)")
    }

    init(frame: NSRect, preferences: IdlessePreferences) {
        self.preferences = preferences
        super.init(frame: frame, isPreview: false)!
        commonInit()
    }

    required init?(coder: NSCoder) {
        preferences = .shared
        super.init(coder: coder)
        commonInit()
        diagnostic("init(coder:)")
    }

    override var hasConfigureSheet: Bool {
        diagnostic("hasConfigureSheet")
        return true
    }

    override var configureSheet: NSWindow? {
        diagnostic("configureSheet")
        Self.configureController.reload()
        let settingsWindow = Self.configureController.window

        // Keep the ScreenSaver API path completely native. System Settings owns
        // presentation and runs this window as a sheet. This delayed check is only
        // diagnostic and never mutates window state.
        if #available(macOS 26.0, *) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak settingsWindow] in
                guard let self, let settingsWindow else { return }
                if settingsWindow.sheetParent != nil {
                    self.diagnostic("configureSheet attached by host")
                    Self.configureController.captureDiagnosticIfRequested()
                } else if settingsWindow.isVisible {
                    self.diagnostic("configureSheet visible without sheetParent")
                } else {
                    self.diagnostic("configureSheet returned but still hidden")
                }
            }
        }

        return settingsWindow
    }

    override func startAnimation() {
        super.startAnimation()
        diagnostic("startAnimation")

        // Configuration is deliberately tied to the Options button. Selecting
        // Idlesse should never spawn settings windows by itself.
        guard !running else { return }
        running = true
        restartSlideshow()
    }

    override func stopAnimation() {
        diagnostic("stopAnimation")
        running = false
        stopTimers()
        canvas.currentImage = nil
        canvas.nextImage = nil
        currentURL = nil
        nextURL = nil
        canvas.transitionProgress = 0
        library.releaseContents()
        super.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        diagnostic(window == nil ? "viewDidMoveToWindow(nil)" : "viewDidMoveToWindow(window)")
        // Tahoe can detach a view without calling stopAnimation first.
        if window == nil && running { stopAnimation() }
    }

    /// Used by the standalone development preview after its settings window saves.
    func reloadFromPreferences() {
        restartSlideshow()
    }

    deinit {
        diagnostic("deinit")
        stopTimers()
        library.stopAccess()
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
        }
    }

    private func commonInit() {
        // Our display/fade timers own drawing; the host frame callback does no work.
        animationTimeInterval = 3600
        autoresizesSubviews = true
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)

        settingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: IdlessePreferences.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.diagnostic("settingsChanged notification")
            self.preferences.reloadFromDisk()
            if self.running {
                self.restartSlideshow()
            }
        }
    }

    private func diagnostic(_ event: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let windowDescription: String
        if let window {
            windowDescription = "window=\(NSStringFromRect(window.frame)) level=\(window.level.rawValue) visible=\(window.isVisible)"
        } else {
            windowDescription = "window=nil"
        }

        let line = "\(Self.diagnosticFormatter.string(from: Date())) pid=\(getpid()) #\(instanceID) \(event) isPreview=\(isPreview) bounds=\(NSStringFromRect(bounds)) front=\(frontmost) folder=\(preferences.folderDisplayPath ?? "nil") settingsVisible=\(Self.configureController.window.isVisible) \(windowDescription)\n"

        NSLog("Idlesse diag: %@", line.trimmingCharacters(in: .whitespacesAndNewlines))

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.diagnosticURL) {
            defer { try? handle.close() }
            // Keep only a bounded diagnostic history, including in long-lived hosts.
            if let end = try? handle.seekToEnd(), end + UInt64(data.count) > 256 * 1024 {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.diagnosticURL, options: .atomic)
        }
    }

    private func restartSlideshow() {
        stopTimers()
        preferences.reloadFromDisk()
        guard running else { return }

        library.playbackOffset = preferences.multiDisplayMode == .different ? currentDisplayIndex : 0
        // Drop the previous decoded images before scanning a potentially large folder.
        currentURL = nil
        nextURL = nil
        canvas.currentImage = nil
        canvas.nextImage = nil
        canvas.transitionProgress = 0
        library.reload()
        canvas.scalingMode = preferences.scalingMode
        canvas.backdropColor = preferences.backgroundColor
        canvas.message = library.lastError

        if running {
            scheduleLibraryRefresh()
        }

        loadNextImage(first: true)
    }

    private var currentDisplayIndex: Int {
        guard let currentScreen = window?.screen else { return 0 }

        let screens = NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        return screens.firstIndex { screen in
            screenNumber(screen) == screenNumber(currentScreen)
        } ?? 0
    }

    private func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func scheduleNextImage() {
        displayTimer?.invalidate()
        displayTimer = nil

        guard !isPlaybackPaused else { return }
        let timer = Timer(timeInterval: preferences.displayDuration, repeats: false) { [weak self] _ in
            self?.beginTransition()
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleLibraryRefresh() {
        libraryRefreshTimer?.invalidate()

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshLibrary()
        }
        timer.tolerance = 3
        libraryRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshLibrary() {
        guard running else { return }
        guard library.refreshIfChanged(currentURL: currentURL) else { return }
        imageGeneration += 1
        imageLoad?.cancel()
        imageLoad = nil

        if library.count == 0 {
            displayTimer?.invalidate()
            fadeTimer?.invalidate()
            displayTimer = nil
            fadeTimer = nil
            currentURL = nil
            nextURL = nil
            canvas.currentImage = nil
            canvas.nextImage = nil
            canvas.transitionProgress = 0
            canvas.message = library.lastError
            return
        }

        canvas.message = nil

        if canvas.currentImage == nil { loadNextImage(first: true) }
        else if fadeTimer == nil { scheduleNextImage() }
    }

    private func beginTransition() {
        guard running else { return }
        loadNextImage(first: canvas.currentImage == nil)
    }

    private func loadNextImage(first: Bool) {
        guard running, imageLoad == nil else { return }
        let generation = imageGeneration
        let scale = window?.backingScaleFactor ?? 2
        let target = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let mode = preferences.scalingMode
        let scope = library.accessURL
        let limit = library.count
        let requestedWhilePaused = isPlaybackPaused
        imageLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.imageGeneration { self.imageLoad = nil } }
            for _ in 0..<limit {
                guard !Task.isCancelled, generation == self.imageGeneration, self.running,
                      let url = self.library.next(excluding: self.currentURL) else { return }
                do {
                    let playable = try await self.sceneSource.resolve(url)
                    let image = try await ImagePreparation.shared.load(playable, target: target, mode: mode, scope: scope)
                    guard !Task.isCancelled, generation == self.imageGeneration, self.running else { return }
                    guard first || requestedWhilePaused || !self.isPlaybackPaused else { return }
                    self.canvas.message = nil
                    if first {
                        self.currentURL = url
                        self.canvas.currentImage = image
                        self.scheduleNextImage()
                    } else if url == self.currentURL {
                        self.scheduleNextImage()
                    } else {
                        self.startTransition(url: url, image: image)
                    }
                    return
                } catch is CancellationError { return }
                catch { continue }
            }
            guard generation == self.imageGeneration, self.running else { return }
            self.canvas.message = self.library.lastError ?? "No readable images in this folder."
            self.scheduleNextImage()
        }
    }

    private func startTransition(url: URL, image: NSImage) {
        nextURL = url
        canvas.nextImage = image
        canvas.transitionProgress = 0

        let duration = preferences.transitionDuration
        if duration <= 0 {
            finishTransition()
            return
        }

        fadeStartedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            self?.advanceTransition(timer: timer, duration: duration)
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceTransition(timer: Timer, duration: TimeInterval) {
        guard running else {
            timer.invalidate()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - fadeStartedAt
        let progress = min(1, elapsed / duration)
        canvas.transitionProgress = CGFloat(progress)

        if progress >= 1 {
            timer.invalidate()
            fadeTimer = nil
            finishTransition()
        }
    }

    private func finishTransition() {
        currentURL = nextURL
        nextURL = nil
        canvas.currentImage = canvas.nextImage
        canvas.nextImage = nil
        canvas.transitionProgress = 0

        if running {
            scheduleNextImage()
        }
    }

    private func stopTimers() {
        imageGeneration += 1
        imageLoad?.cancel()
        imageLoad = nil
        displayTimer?.invalidate()
        fadeTimer?.invalidate()
        libraryRefreshTimer?.invalidate()
        displayTimer = nil
        fadeTimer = nil
        libraryRefreshTimer = nil
    }
}
