import AppKit
import ScreenSaver

@objc(IdlesseView)
final class IdlesseView: ScreenSaverView {
    private let canvas = ImageCanvasView(frame: .zero)
    private let preferences = IdlessePreferences.shared

    private lazy var library = ImageLibrary(preferences: preferences)
    private lazy var configureController = ConfigureSheetController(preferences: preferences) { [weak self] in
        self?.restartSlideshow()
    }

    private var displayTimer: Timer?
    private var fadeTimer: Timer?
    private var libraryRefreshTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var fadeStartedAt: TimeInterval = 0
    private var currentURL: URL?
    private var nextURL: URL?
    private var running = false
    private var didScheduleTahoeSettingsPresentation = false

    override init(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)!
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var hasConfigureSheet: Bool {
        NSLog("Idlesse: hasConfigureSheet requested")

        // Tahoe currently draws the Options button for legacy `.saver` bundles but
        // can fail to call configureSheet when that button is pressed. This getter is
        // still queried by the host to decide whether the button should exist, so on
        // Tahoe we use it to schedule a settings window from inside legacyScreenSaver.
        // The size/frontmost-app checks keep this out of full-screen activation.
        if #available(macOS 26.0, *) {
            scheduleTahoeSettingsPresentation()
        }

        return true
    }

    override var configureSheet: NSWindow? {
        NSLog("Idlesse: configureSheet requested")
        configureController.reload()
        return configureController.window
    }

    override func startAnimation() {
        super.startAnimation()
        guard !running else { return }
        running = true
        restartSlideshow()
    }

    override func stopAnimation() {
        running = false
        stopTimers()
        library.stopAccess()
        super.stopAnimation()
    }

    /// Used by the standalone development preview after its settings window saves.
    func reloadFromPreferences() {
        restartSlideshow()
    }

    deinit {
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
            self.preferences.reloadFromDisk()
            if self.running {
                self.restartSlideshow()
            }
        }
    }

    @available(macOS 26.0, *)
    private func scheduleTahoeSettingsPresentation() {
        guard !didScheduleTahoeSettingsPresentation else { return }
        didScheduleTahoeSettingsPresentation = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self else { return }

            // The Wallpaper pane's selected-saver preview is small. A real screen
            // saver window is screen-sized, so never surface settings there.
            let size = self.bounds.size
            guard size.width > 120,
                  size.height > 80,
                  size.width < 900,
                  size.height < 700 else {
                return
            }

            let frontmost = NSWorkspace.shared.frontmostApplication
            let isSystemSettings = frontmost?.bundleIdentifier == "com.apple.systempreferences"
                || frontmost?.localizedName == "System Settings"
            guard isSystemSettings else { return }

            NSLog("Idlesse: presenting Tahoe settings fallback from legacyScreenSaver")
            self.configureController.reload()
            let settingsWindow = self.configureController.window
            settingsWindow.level = .floating
            settingsWindow.center()
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
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
