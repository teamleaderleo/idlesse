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
    private var fadeStartedAt: TimeInterval = 0
    private var currentURL: URL?
    private var nextURL: URL?
    private var running = false

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
        return true
    }

    override var configureSheet: NSWindow? {
        NSLog("Idlesse: configureSheet requested")
        configureController.reload()

        let optionsWindow = configureController.window

        // Tahoe has a known legacyScreenSaver regression where System Settings can
        // ask a saver for its configuration window but then fail to present that
        // window. Keep this best-effort path for older/fixed systems; Idlesse.app is
        // the canonical settings surface on Tahoe.
        if #available(macOS 26.0, *) {
            optionsWindow.level = .floating

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak optionsWindow] in
                guard let optionsWindow else { return }

                if optionsWindow.sheetParent == nil {
                    NSLog("Idlesse: Tahoe host did not attach configureSheet; presenting fallback window")
                    optionsWindow.center()
                    optionsWindow.makeKeyAndOrderFront(nil)
                    optionsWindow.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    NSLog("Idlesse: configureSheet attached by host")
                }
            }
        }

        return optionsWindow
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

    /// Used by the companion app after its settings window saves.
    func reloadFromPreferences() {
        restartSlideshow()
    }

    deinit {
        stopTimers()
        library.stopAccess()
    }

    private func commonInit() {
        autoresizesSubviews = true
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
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

        // If the saver had been sitting on an empty folder, begin as soon as an image
        // appears. Otherwise keep the currently rendered image until its normal timer ends.
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
