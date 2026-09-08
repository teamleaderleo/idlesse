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

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
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

    /// Used by the standalone preview harness after its own options window saves.
    /// The real screen saver host continues to use configureSheet above.
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
        library.reload()

        currentURL = nil
        nextURL = nil
        canvas.currentImage = nil
        canvas.nextImage = nil
        canvas.transitionProgress = 0
        canvas.scalingMode = preferences.scalingMode
        canvas.message = library.lastError

        guard let first = library.next(excluding: nil) else {
            canvas.message = library.lastError ?? "Choose a folder in Options…"
            return
        }

        currentURL = first.url
        canvas.currentImage = first.image
        canvas.message = nil

        if running {
            scheduleNextImage()
        }
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
        displayTimer = nil
        fadeTimer = nil
    }
}
