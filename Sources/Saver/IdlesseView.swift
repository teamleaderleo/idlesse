import AppKit
import ScreenSaver

@objc(IdlesseView)
final class IdlesseView: ScreenSaverView {
    private static let configureController = ConfigureSheetController(
        preferences: IdlessePreferences.shared,
        onSave: {}
    )

    // Tahoe may create several ScreenSaverView instances while the Wallpaper pane
    // is open. Keep first-run presentation process-wide so those instances cannot
    // pile up duplicate Settings windows behind System Settings.
    private static var didAutoPresentTahoeSettings = false
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
    private let preferences = IdlessePreferences.shared

    private lazy var library = ImageLibrary(preferences: preferences)

    private var displayTimer: Timer?
    private var fadeTimer: Timer?
    private var libraryRefreshTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var tahoeSettingsWorkItem: DispatchWorkItem?
    private var fadeStartedAt: TimeInterval = 0
    private var currentURL: URL?
    private var nextURL: URL?
    private var running = false

    override init(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)!
        commonInit()
        diagnostic("init(frame:isPreview:)")
    }

    required init?(coder: NSCoder) {
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
        return Self.configureController.window
    }

    override func startAnimation() {
        super.startAnimation()
        diagnostic("startAnimation")

        // Tahoe reliably starts the selected-saver preview, but its Options button
        // may never call configureSheet. Use this only as first-run onboarding. Once
        // a folder exists, selecting Idlesse never spawns a Settings window by itself.
        if #available(macOS 26.0, *), preferences.folderDisplayPath == nil {
            scheduleTahoeFirstRunSettings()
        }

        guard !running else { return }
        running = true
        restartSlideshow()
    }

    override func stopAnimation() {
        diagnostic("stopAnimation")
        running = false
        stopTimers()
        library.stopAccess()
        super.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        diagnostic(window == nil ? "viewDidMoveToWindow(nil)" : "viewDidMoveToWindow(window)")
    }

    /// Used by the standalone development preview after its settings window saves.
    func reloadFromPreferences() {
        restartSlideshow()
    }

    deinit {
        diagnostic("deinit")
        tahoeSettingsWorkItem?.cancel()
        stopTimers()
        library.stopAccess()
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
        }
    }

    private func commonInit() {
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

    @available(macOS 26.0, *)
    private func scheduleTahoeFirstRunSettings() {
        guard ProcessInfo.processInfo.processName.lowercased().contains("legacyscreensaver") else {
            return
        }
        guard !Self.didAutoPresentTahoeSettings else {
            diagnostic("first-run Settings already claimed by another instance")
            return
        }

        Self.didAutoPresentTahoeSettings = true
        diagnostic("scheduling first-run Settings")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" else {
                self.diagnostic("first-run Settings skipped: System Settings not frontmost")
                return
            }

            let settingsWindow = Self.configureController.window
            guard !settingsWindow.isVisible else {
                self.diagnostic("first-run Settings already visible")
                return
            }

            self.diagnostic("presenting first-run Settings")
            Self.configureController.reload()

            // Keep this above legacyScreenSaver during first-run onboarding. The
            // standard configureSheet path remains untouched for systems where the
            // native Options button works.
            settingsWindow.level = NSWindow.Level(
                rawValue: NSWindow.Level.screenSaver.rawValue + 10
            )
            settingsWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            settingsWindow.center()
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
        }

        tahoeSettingsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.diagnosticURL, options: .atomic)
        }
    }

    private func restartSlideshow() {
        stopTimers()
        preferences.reloadFromDisk()

        library.playbackOffset = preferences.multiDisplayMode == .different ? currentDisplayIndex : 0
        library.reload()

        currentURL = nil
        nextURL = nil
        canvas.currentImage = nil
        canvas.nextImage = nil
        canvas.transitionProgress = 0
        canvas.scalingMode = preferences.scalingMode
        canvas.backdropColor = preferences.backgroundColor
        canvas.message = library.lastError

        if running {
            scheduleLibraryRefresh()
        }

        guard let first = library.next(excluding: nil) else {
            canvas.message = library.lastError ?? "Choose a folder in Idlesse Settings."
            return
        }

        currentURL = first.url
        canvas.currentImage = first.image
        canvas.message = nil

        if running {
            scheduleNextImage()
        }
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
        libraryRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshLibrary() {
        guard running else { return }
        guard library.refreshIfChanged(currentURL: currentURL) else { return }

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

        if canvas.currentImage == nil, let first = library.next(excluding: nil) {
            currentURL = first.url
            canvas.currentImage = first.image
            scheduleNextImage()
        }
    }

    private func beginTransition() {
        guard running else { return }

        guard let next = library.next(excluding: currentURL) else {
            canvas.message = library.lastError
            scheduleNextImage()
            return
        }

        if next.url == currentURL {
            scheduleNextImage()
            return
        }

        nextURL = next.url
        canvas.nextImage = next.image
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
        displayTimer?.invalidate()
        fadeTimer?.invalidate()
        libraryRefreshTimer?.invalidate()
        displayTimer = nil
        fadeTimer = nil
        libraryRefreshTimer = nil
    }
}
