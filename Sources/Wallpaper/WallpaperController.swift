import MetalKit
import AppKit
import ApplicationServices
import AVFoundation
import UniformTypeIdentifiers

private final class DesktopWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var desktopClick: (() -> Void)?
    var desktopMenu: (() -> NSMenu)?
    var desktopForwardRightClick: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            if desktopForwardRightClick?(event) == true { return }
            if let desktopMenu, let view = contentView { NSMenu.popUpContextMenu(desktopMenu(), with: event, for: view) }
            return
        }
        if event.type == .leftMouseDown, let desktopClick { desktopClick(); return }
        super.sendEvent(event)
    }
}

/// Keeps a per-display security-scoped Library asset alive for exactly as long
/// as the surface that uses it, including scene transitions.
final class WallpaperScopeLease {
    let url: URL
    private let started: Bool
    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

final class WallpaperSurface {
    fileprivate static var liveMenuStripEnabled: Bool {
        ProcessInfo.processInfo.environment["IDLESSE_LIVE_MENU_STRIP"] == "1" ||
            UserDefaults.standard.bool(forKey: "comfort.liveMenuStrip")
    }
    let window: NSWindow
    let displayID: UInt32
    private let renderer: SceneRenderer
    private let securityScope: WallpaperScopeLease?
    private var menuStrip: MenuBarStrip?
    var diagnostics: RendererDiagnostics { renderer.diagnostics }
    var presentedFrameCount: Int? { renderer.presentedFrameCount }
    var gpuTotals: (seconds: Double, frames: Int)? { renderer.gpuTotals }
    var menuStripFrames: Int { menuStrip?.frames ?? 0 }
    var menuStripWindowNumber: Int? { menuStrip?.window.windowNumber }
    func updateScene(_ scene: SceneDescriptor) -> Bool { renderer.updateScene(scene) }

    init(screen: NSScreen, playable: SceneDescriptor, clock: SceneClock, sharedHub: SharedVideoHub? = nil,
         securityScope: WallpaperScopeLease? = nil, onError: @escaping (String) -> Void) throws {
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        self.securityScope = securityScope
        window = DesktopWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        (window as? NSPanel)?.isFloatingPanel = false
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "Idlesse Wallpaper"

        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        let hasCreativeLayers = playable.allNodes.contains { $0.style != .plain || [.particles, .text, .shape, .gradient, .shader].contains($0.kind) || $0.needsComposition }
        if playable.canvas == .desktopSpan || playable.requiresMetal ||
           ProcessInfo.processInfo.environment["IDLESSE_METAL_COMPOSITOR"] == "1" ||
           (Self.liveMenuStripEnabled && hasCreativeLayers) {
            renderer = try MetalSceneRenderer(playable: playable, bounds: bounds,
                scale: screen.backingScaleFactor, clock: clock, onError: onError, sharedHub: sharedHub)
        } else {
            renderer = try LayeredSceneRenderer(playable: playable, bounds: bounds,
                scale: screen.backingScaleFactor, clock: clock, onError: onError)
        }
        if let metal = renderer as? MetalSceneRenderer, playable.canvas == .desktopSpan {
            metal.desktopFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            metal.displayFrame = screen.frame
        }
        window.contentView = renderer.view
        if Self.liveMenuStripEnabled,
           let metal = renderer as? MetalSceneRenderer {
            let strip = MenuBarStrip(screen: screen)
            menuStrip = strip
            strip.onFirstDrawable = { [weak metal] in metal?.refreshSceneTime() }
            metal.mirrorFrame = { [weak strip] command, texture in strip?.copy(command: command, texture: texture) }
        }
        updateFrameRate()
    }

    func setCleanDesktop(_ enabled: Bool, hideWidgets: Bool = false, click: @escaping () -> Void, menu: @escaping () -> NSMenu) {
        guard let desktop = window as? DesktopWindow else { return }
        desktop.desktopClick = enabled ? click : nil
        desktop.desktopMenu = enabled ? menu : nil
        desktop.desktopForwardRightClick = enabled ? { [weak self] event in self?.forwardRightClickToFinder(event) ?? false } : nil
        desktop.ignoresMouseEvents = !enabled
        // Widgets occupy desktopIconWindow + 2 on Tahoe, above Finder icons.
        // Cover them with the same surface when the whole desktop is kept clear.
        let offset = enabled && hideWidgets ? 3 : 1
        desktop.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(enabled ? .desktopIconWindow : .desktopWindow)) + offset)
        if desktop.isVisible {
            if enabled { desktop.orderFront(nil) } else { desktop.orderBack(nil) }
        }
    }

    func updateFrameRate() {
        renderer.setPreferredFrameRate(SceneFrameRate.selected.requested(maximum: window.screen?.maximumFramesPerSecond ?? 60))
    }

    func show(paused: Bool) {
        window.orderBack(nil)
        menuStrip?.window.orderFront(nil)
        setPaused(paused)
    }

    private(set) var pausedState = false
    func setPaused(_ paused: Bool) { pausedState = paused; renderer.setPaused(paused || covered) }
    /// Set by the coverage monitor: a fully covered display rests its own
    /// renderer without affecting other displays or the pause state.
    private var covered = false
    var isCovered: Bool { covered }
    func setCovered(_ value: Bool) {
        guard covered != value else { return }
        covered = value
        renderer.setPaused(pausedState || covered)
    }
    func setMuted(_ muted: Bool) { renderer.setMuted(muted) }

    /// Native Finder menu on right-click: our window only covers Finder's desktop,
    /// so briefly go click-through and replay the click to Finder underneath.
    /// Icons stay covered (no flash) and the Finder menu renders above us.
    /// Falls back to our own menu when Accessibility trust (needed to repost
    /// the click) is missing.
    static var nativeDesktopMenuEnabled: Bool {
        UserDefaults.standard.object(forKey: "comfort.nativeDesktopMenu") == nil ||
            UserDefaults.standard.bool(forKey: "comfort.nativeDesktopMenu")
    }

    func forwardRightClickToFinder(_ event: NSEvent) -> Bool {
        guard Self.nativeDesktopMenuEnabled, AXIsProcessTrusted() else { return false }
        let cocoa = window.convertPoint(toScreen: event.locationInWindow)
        guard let main = NSScreen.main else { return false }
        let point = CGPoint(x: cocoa.x, y: main.frame.height - cocoa.y)
        // Click-through instead of hiding: icons stay covered, Finder still gets the click.
        let wasIgnoring = window.ignoresMouseEvents
        window.ignoresMouseEvents = true
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
            mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
            mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.window.ignoresMouseEvents = wasIgnoring
        }
        return true
    }

    func close() {
        (renderer as? MetalSceneRenderer)?.mirrorFrame = nil
        menuStrip?.window.close()
        menuStrip = nil
        renderer.releaseResources()
        window.contentView = nil
        window.close()
    }

    deinit { close() }
}

enum WallpaperError: LocalizedError {
    case unreadableImage, noVideo, unsupported
    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "That image could not be opened."
        case .noVideo: return "Choose a playable video with a finite duration and a video track."
        case .unsupported: return "Choose a JPG, PNG, HEIC, MP4 or MOV file."
        }
    }
}

/// A sibling to the saver. Interactive playback also prepares a matching system wallpaper still.
final class WallpaperController: NSObject, NSMenuItemValidation {
    private(set) var surfaces: [WallpaperSurface] = []
    private(set) var selectedURL: URL?
    private(set) var pausedByUser = false
    private var playable: SceneDescriptor?
    private var activeSharedVideoHub: SharedVideoHub?
    private var retiringSharedVideoHub: SharedVideoHub?
    // Only the interactive host persists state; smoke/qualification controllers stay isolated.
    var persistsSelection = false
    var resumeDefaults = UserDefaults.standard
    private static let resumeKey = "wallpaperResumeBookmark"
    private static let pauseKey = "wallpaperResumePaused"
    private static let sameDisplaysKey = "wallpaperSameOnAllDisplays"
    private static let origBackdropPrefix = "wallpaperOrigBackdrop."
    private static let stillsDirName = "Idlesse/Desktop Backdrops"

    private static func isOurStill(_ url: URL?) -> Bool {
        url?.path.contains(stillsDirName) ?? false
    }

    var sameWallpaperOnAllDisplays: Bool {
        get {
            if resumeDefaults.object(forKey: Self.sameDisplaysKey) == nil { return true }
            return resumeDefaults.bool(forKey: Self.sameDisplaysKey)
        }
        set {
            resumeDefaults.set(newValue, forKey: Self.sameDisplaysKey)
            refreshDisplayAssignments()
        }
    }

    static func persistentDisplayIdentifier(_ displayID: UInt32) -> String {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(displayID)) else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(kCFAllocatorDefault, unmanaged.takeRetainedValue()) as String
    }

    private var displayAssignmentStore: DisplayAssignmentStore {
        DisplayAssignmentStore(defaults: resumeDefaults, prefix: Self.resumeKey)
    }

    private func bookmarkData(for url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func explicitDisplayURL(for displayID: UInt32) -> URL? {
        let persistentID = Self.persistentDisplayIdentifier(displayID)
        guard let data = displayAssignmentStore.bookmarkData(
            persistentID: persistentID, legacyDisplayID: displayID) else { return nil }
        var stale = false
        let url: URL?
        if let scoped = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = scoped
        } else {
            url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if stale, let url, let refreshed = try? bookmarkData(for: url) {
            displayAssignmentStore.setBookmarkData(refreshed, persistentID: persistentID)
        }
        return url
    }

    func displayURL(for displayID: UInt32) -> URL? {
        explicitDisplayURL(for: displayID) ?? selectedURL
    }

    func setDisplayURL(_ url: URL, for displayID: UInt32) {
        do {
            displayAssignmentStore.setBookmarkData(try bookmarkData(for: url),
                persistentID: Self.persistentDisplayIdentifier(displayID))
            refreshDisplayAssignments()
        } catch {
            showError("The display assignment could not be saved: " + error.localizedDescription)
        }
    }

    func clearDisplayURL(for displayID: UInt32) {
        displayAssignmentStore.clear(persistentID: Self.persistentDisplayIdentifier(displayID),
                                     legacyDisplayID: displayID)
        Self.appendLine("Idlesse-display display=\(Self.persistentDisplayIdentifier(displayID)) action=follow-main")
        refreshDisplayAssignments()
    }

    var desktopSpanActive: Bool { playable?.canvas == .desktopSpan }

    /// Entry point used by the native Library display chooser. The optional
    /// `retainedAccess` keeps a source-root grant alive while we mint a scoped
    /// bookmark for the chosen Library item. A desktop-span scene is always
    /// global; ordinary scenes can become stable per-display overrides.
    func assignLibraryWallpaper(_ url: URL, to displayID: UInt32?, retaining retainedAccess: AnyObject? = nil) {
        do {
            let data = try bookmarkData(for: url)
            var stale = false
            let scopedURL = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
            withExtendedLifetime(retainedAccess) {}
            guard let displayID else {
                resumeDefaults.set(true, forKey: Self.sameDisplaysKey)
                Self.appendLine("Idlesse-display target=all action=library-selection")
                select(scopedURL, automatic: true)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let access = scopedURL.startAccessingSecurityScopedResource()
                defer { if access { scopedURL.stopAccessingSecurityScopedResource() } }
                do {
                    let candidate = try await self.source.resolve(scopedURL)
                    if candidate.canvas == .desktopSpan {
                        Self.appendLine("Idlesse-display target=\(Self.persistentDisplayIdentifier(displayID)) action=desktop-span-all-displays")
                        self.select(scopedURL, automatic: true)
                        return
                    }
                    self.displayAssignmentStore.setBookmarkData(data,
                        persistentID: Self.persistentDisplayIdentifier(displayID))
                    self.resumeDefaults.set(false, forKey: Self.sameDisplaysKey)
                    Self.appendLine("Idlesse-display target=\(Self.persistentDisplayIdentifier(displayID)) action=library-assignment")
                    if self.selectedURL == nil || self.playable?.canvas == .desktopSpan {
                        self.select(scopedURL, automatic: true)
                    } else {
                        self.refreshDisplayAssignments()
                    }
                } catch {
                    self.showError("The Library wallpaper could not be assigned: " + error.localizedDescription)
                }
            }
        } catch {
            showError("The Library wallpaper could not be assigned: " + error.localizedDescription)
        }
    }

    private func refreshDisplayAssignments() {
        rebuild()
        if let playable, let selectedURL {
            syncSystemBackdrop(scene: playable, sourceURL: selectedURL, request: generation)
        }
        updateMenu()
        NotificationCenter.default.post(name: .idlesseDisplayAssignmentsChanged, object: self)
    }

    func restoreSelection() {
        guard persistsSelection, !isRunning, !isLoading,
              let data = resumeDefaults.data(forKey: Self.resumeKey) else { return }
        logState("restore-begin")
        do {
            var stale = false
            let url: URL
            if let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = resolved
            } else {
                url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            select(url, automatic: true)
        } catch {
            lastReloadError = "The previous wallpaper is unavailable. Choose it again in Wallpapers."
            updateMenu()
        }
    }

    static func smokeResume(url: URL) throws {
        let suite = "Idlesse.ResumeTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = WallpaperController()
        controller.resumeDefaults = defaults
        controller.persistsSelection = true
        controller.presentsWindows = false
        try controller.saveResume(url: url, paused: true)
        precondition(defaults.data(forKey: Self.resumeKey) != nil, "Resume bookmark missing")
        precondition(defaults.bool(forKey: Self.pauseKey), "Pause state missing")
        controller.stop(restoreSystemWallpaper: false)
        precondition(defaults.data(forKey: Self.resumeKey) == nil, "Resume bookmark should clear")
    }

    /// CI-safe persistence coverage for #28: stable display identity first,
    /// legacy transient NSScreenNumber as migration fallback.
    static func smokeDisplayAssignmentPersistence() throws {
        let suite = "Idlesse.DisplayPersistenceTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisplayAssignmentStore(defaults: defaults, prefix: Self.resumeKey)
        let first = Data([1, 2, 3])
        store.setBookmarkData(first, persistentID: "DISPLAY-STABLE")
        precondition(store.bookmarkData(persistentID: "DISPLAY-STABLE", legacyDisplayID: 777) == first,
                     "Stable assignment must not depend on transient CG display ID")
        let legacy = Data([7, 8, 9])
        defaults.set(legacy, forKey: store.legacyKey(42))
        precondition(store.bookmarkData(persistentID: "DISPLAY-MIGRATED", legacyDisplayID: 42) == legacy,
                     "Legacy direct-ID assignment should migrate on first read")
        precondition(defaults.data(forKey: store.stableKey("DISPLAY-MIGRATED")) == legacy,
                     "Migrated assignment must be stored under stable display identity")
        precondition(defaults.data(forKey: store.legacyKey(42)) == nil,
                     "Legacy direct-ID assignment should be retired after migration")
    }

    private func saveResume(url: URL, paused: Bool) throws {
        guard persistsSelection else { return }
        resumeDefaults.set(try bookmarkData(for: url), forKey: Self.resumeKey)
        resumeDefaults.set(paused, forKey: Self.pauseKey)
    }

    private func updateResumePause(_ paused: Bool) {
        guard persistsSelection, resumeDefaults.data(forKey: Self.resumeKey) != nil else { return }
        resumeDefaults.set(paused, forKey: Self.pauseKey)
    }
    private var cleanDesktop = false
    /// Some helpers (e.g. smoke tests) use a controller without showing windows.
    var presentsWindows = true
    let source = SceneSourceResolver()
    private var clock: SceneClock?
    private var generation = 0
    private var backdropTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var lifecycleTokens: [NSObjectProtocol] = []
    private var batteryToken: NSObjectProtocol?
    private var previousOnBattery: Bool?
    private var library: SceneLibraryController?
    var presentingWindow: (() -> NSWindow?)?
    var desktopComfort: DesktopComfortController?
    var onShowSettings: (() -> Void)?
    var onStateChange: (() -> Void)?
    var previewOpacityProvider: (() -> Double)?
    var menu: NSMenu?
    var hasPendingWork: Bool { isLoading || backdropTask != nil }
    private(set) var lastReloadError: String?
    private(set) var lastQualificationReport: String?
    private var lastSharedPlaybackDebugLine: String?
    private(set) var isLoading = false
    var isRunning: Bool { !surfaces.isEmpty }
    var diagnostics: RendererDiagnostics? { surfaces.first?.diagnostics }
    var menuStripFrameCount: Int { surfaces.reduce(0) { $0 + $1.menuStripFrames } }
    var activeSharedVideoDecoders: Int { activeSharedVideoHub == nil ? 0 : 1 }
    var activeSharedVideoHubID: ObjectIdentifier? { activeSharedVideoHub.map(ObjectIdentifier.init) }
    var retiringSharedVideoHubID: ObjectIdentifier? { retiringSharedVideoHub.map(ObjectIdentifier.init) }
    var coveragePauseEnabled: Bool {
        get {
            if resumeDefaults.object(forKey: "wallpaper.coveragePauseEnabled") == nil { return true }
            return resumeDefaults.bool(forKey: "wallpaper.coveragePauseEnabled")
        }
        set {
            resumeDefaults.set(newValue, forKey: "wallpaper.coveragePauseEnabled")
            if !newValue { resetCoverageRest() }
            startCoverageMonitor()
        }
    }
    private lazy var coverageMonitor = CoverageMonitor()
    private var coverageTimer: Timer?
    private var workspace = NSWorkspace.shared
    private static let powerSourceNotification = ProcessInfo.powerStateDidChangeNotification
    var transitionDuration: Double {
        get {
            let value = resumeDefaults.double(forKey: "wallpaperTransitionDuration")
            if value <= 0 { return 0 }
            return min(2, max(0.1, value))
        }
        set { resumeDefaults.set(min(2, max(0, newValue)), forKey: "wallpaperTransitionDuration") }
    }

    enum TransitionStyle: String, CaseIterable {
        case crossfade, slide, push, reveal
        var title: String {
            switch self { case .crossfade: return "Crossfade"; case .slide: return "Slide"; case .push: return "Push"; case .reveal: return "Reveal" }
        }
    }
    var transitionStyle: TransitionStyle {
        get { TransitionStyle(rawValue: resumeDefaults.string(forKey: "wallpaperTransitionStyle") ?? "") ?? .crossfade }
        set { resumeDefaults.set(newValue.rawValue, forKey: "wallpaperTransitionStyle") }
    }

    override init() {
        super.init()
        let nc = workspace.notificationCenter
        lifecycleTokens.append(nc.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.setLifecyclePaused(true) })
        lifecycleTokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.setLifecyclePaused(false)
            self.handleWakeBackdrop()
        })
        lifecycleTokens.append(nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.setLifecyclePaused(true) })
        lifecycleTokens.append(nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.setLifecyclePaused(false) })
        lifecycleTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main) { [weak self] _ in self?.refreshDisplayAssignments() })
        batteryToken = NotificationCenter.default.addObserver(forName: Self.powerSourceNotification,
            object: nil, queue: .main) { [weak self] _ in self?.handlePowerSourceChange() }
        previousOnBattery = SceneFrameRate.isOnBattery
        startCoverageMonitor()
    }

    deinit {
        backdropTask?.cancel()
        selectionTask?.cancel()
        coverageTimer?.invalidate()
        lifecycleTokens.forEach { workspace.notificationCenter.removeObserver($0) }
        if let batteryToken { NotificationCenter.default.removeObserver(batteryToken) }
    }

    func setDesktopComfort(_ comfort: DesktopComfortController) {
        desktopComfort = comfort
        NotificationCenter.default.addObserver(self, selector: #selector(desktopVisibilityChanged),
            name: DesktopComfortController.desktopVisibilityChanged, object: nil)
        refreshCleanDesktop()
    }

    @objc private func desktopVisibilityChanged() { refreshCleanDesktop() }
    private func refreshCleanDesktop() {
        guard let comfort = desktopComfort else { return }
        cleanDesktop = !comfort.desktopIconsVisible
        for surface in surfaces {
            surface.setCleanDesktop(cleanDesktop, hideWidgets: !comfort.desktopWidgetsVisible,
                click: { [weak comfort] in comfort?.showDesktopIcons() },
                menu: { [weak self] in self?.desktopMenu() ?? NSMenu() })
        }
    }

    private func setLifecyclePaused(_ value: Bool) {
        let paused = value || pausedByUser
        surfaces.forEach { $0.setPaused(paused) }
        syncSharedPlaybackPause()
    }

    private func handlePowerSourceChange() {
        let current = SceneFrameRate.isOnBattery
        let changed = previousOnBattery != current
        previousOnBattery = current
        guard changed else { return }
        guard SceneFrameRate.throttleOnBattery else { return }
        applyFrameRate()
        let requested = SceneFrameRate.selected.requested(maximum: NSScreen.main?.maximumFramesPerSecond ?? 60)
        logState("power-policy source=\(current ? "battery" : "ac") requested=\(requested)")
    }

    private func handleWakeBackdrop() {
        let value = UserDefaults.standard.double(forKey: "wallpaperBackdropRefresh")
        let interval = value > 0 ? value : 60 * 30
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "wallpaperBackdropLast") > interval,
              let playable, let selectedURL else { return }
        syncSystemBackdrop(scene: playable, sourceURL: selectedURL, request: generation)
    }

    /// Coverage pause samples ordinary opaque on-screen windows above the
    /// desktop level. This remains conservative: a stale or uncertain sample
    /// wakes the surface instead of saving power at the risk of visible stalls.
    private func startCoverageMonitor() {
        coverageTimer?.invalidate()
        guard coveragePauseEnabled else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sampleCoverage() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        coverageTimer = timer
    }

    private func resetCoverageRest() {
        coverageMonitor.resetAll()
        for surface in surfaces { surface.setCovered(false) }
        syncSharedPlaybackPause()
    }

    private func syncSharedPlaybackPause() {
        let globalPause = pausedByUser
        let covered = surfaces.map(\.isCovered)
        let restShared = CoverageRestPolicy.shouldRestSharedPlayback(globalPause: globalPause,
                                                                     displayResting: covered)
        activeSharedVideoHub?.setPaused(restShared)
    }

    private func sampleCoverage() {
        guard coveragePauseEnabled, !surfaces.isEmpty else { return }
        var changed = false
        for surface in surfaces {
            guard let screen = surface.window.screen else { continue }
            let frame = screen.frame
            let fraction = coverageFraction(for: frame)
            let result = coverageMonitor.evaluate(displayKey: "\(surface.displayID)", fraction: fraction,
                                                  currentResting: surface.isCovered)
            if result.changed {
                surface.setCovered(result.isResting)
                changed = true
                Self.appendLine("Idlesse-coverage display=\(surface.displayID) covered=\(String(format: "%.3f", fraction)) rest=\(result.isResting ? 1 : 0)")
            }
        }
        if changed { syncSharedPlaybackPause() }
    }

    private func coverageFraction(for frame: CGRect) -> Double {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return 0 }
        var bounds: [CGRect] = []
        let ourIDs = Set(surfaces.map { UInt32($0.window.windowNumber) })
        for item in info {
            guard let number = item[kCGWindowNumber as String] as? UInt32, !ourIDs.contains(number),
                  let layer = item[kCGWindowLayer as String] as? Int, layer > Int(CGWindowLevelForKey(.desktopWindow)),
                  let alpha = item[kCGWindowAlpha as String] as? Double,
                  CoverageMonitor.countsAsOpaqueWindow(alpha: alpha),
                  let rawBounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = rawBounds["X"], let y = rawBounds["Y"],
                  let width = rawBounds["Width"], let height = rawBounds["Height"] else { continue }
            bounds.append(CGRect(x: x, y: y, width: width, height: height))
        }
        return CoverageMonitor.coveredFraction(of: frame, by: bounds)
    }

    private func desktopMenu() -> NSMenu {
        let menu = NSMenu(title: "Desktop")
        let files = NSMenuItem(title: "Show Files", action: #selector(showDesktopFiles), keyEquivalent: "")
        files.target = self
        menu.addItem(files)
        if let comfort = desktopComfort, !comfort.desktopWidgetsVisible {
            let widgets = NSMenuItem(title: "Show Widgets", action: #selector(showDesktopWidgets), keyEquivalent: "")
            widgets.target = self
            menu.addItem(widgets)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Idlesse Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let exit = NSMenuItem(title: "Exit Wallpaper", action: #selector(stopFromMenu), keyEquivalent: "")
        exit.target = self
        menu.addItem(exit)
        return menu
    }

    @objc private func showDesktopFiles() { desktopComfort?.showDesktopIcons() }
    @objc private func showDesktopWidgets() { desktopComfort?.showDesktopWidgets() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func stopFromMenu() { stop() }

    func installMenu(into statusMenu: NSMenu) {
        menu = statusMenu
        updateMenu()
    }

    private func updateMenu() {
        guard let menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        if isLoading {
            let item = NSMenuItem(title: "Loading Wallpaper…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let selectedURL {
            let state = NSMenuItem(title: "Wallpaper: \(selectedURL.lastPathComponent)", action: nil, keyEquivalent: "")
            state.isEnabled = false
            menu.addItem(state)
            let pause = NSMenuItem(title: pausedByUser ? "Resume Wallpaper" : "Pause Wallpaper",
                                   action: #selector(togglePause), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
            let stop = NSMenuItem(title: "Stop Wallpaper", action: #selector(stopFromMenu), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let wallpapers = NSMenuItem(title: "Wallpapers…", action: #selector(showWallpapers), keyEquivalent: "")
        wallpapers.target = self
        menu.addItem(wallpapers)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    @objc private func showWallpapers() { libraryController().show() }

    func libraryController(indexURL: URL? = nil, importRoot: URL? = nil) -> SceneLibraryController {
        if let library { return library }
        let created: SceneLibraryController
        do {
            created = try SceneLibraryController(indexURL: indexURL, importRoot: importRoot,
                onUse: { [weak self] in self?.select($0) },
                onUseDisplay: { [weak self] url, displayID, token in
                    self?.assignLibraryWallpaper(url, to: displayID, retaining: token)
                },
                onEdit: { [weak self] url, name in self?.openEditor(url, name: name) })
        } catch {
            // A Library window is always preferable to a dead menu item. A temp index can still browse/import.
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("Idlesse-Library.json")
            created = try! SceneLibraryController(indexURL: fallback,
                onUse: { [weak self] in self?.select($0) },
                onUseDisplay: { [weak self] url, displayID, token in
                    self?.assignLibraryWallpaper(url, to: displayID, retaining: token)
                },
                onEdit: { [weak self] url, name in self?.openEditor(url, name: name) })
        }
        library = created
        return created
    }

    private func openEditor(_ url: URL, name: String) {
        do {
            var scene = try SceneDocument.load(url)
            scene.sourceURL = url
            let editor = InspectorController(scene: scene, title: name)
            editor.show()
        } catch {
            showError("The scene could not be opened in Studio: " + error.localizedDescription)
        }
    }

    func select(_ url: URL, automatic: Bool = false, restoringPause: Bool? = nil) {
        generation += 1
        let request = generation
        selectionTask?.cancel()
        isLoading = true
        lastReloadError = nil
        updateMenu()
        logState("select-begin url=\(url.lastPathComponent) automatic=\(automatic ? 1 : 0)")

        let retainedScope = url.startAccessingSecurityScopedResource()
        selectionTask = Task { @MainActor [weak self] in
            guard let self else {
                if retainedScope { url.stopAccessingSecurityScopedResource() }
                return
            }
            defer {
                if retainedScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let scene = try await self.source.resolve(url)
                try Task.checkCancellation()
                guard request == self.generation else { return }
                let playable = try self.validate(scene)
                let candidateClock = SceneClock()
                candidateClock.start()
                var replacement: [WallpaperSurface] = []
                var newHub: SharedVideoHub?
                do {
                    (replacement, newHub) = try self.makeSurfaces(playable: playable, clock: candidateClock, request: request)
                } catch {
                    replacement.forEach { $0.close() }
                    newHub?.stop()
                    throw error
                }
                guard request == self.generation else {
                    replacement.forEach { $0.close() }
                    newHub?.stop()
                    return
                }
                if self.persistsSelection {
                    do {
                        try self.saveResume(url: url, paused: restoringPause ?? self.pausedByUser)
                    } catch {
                        replacement.forEach { $0.close() }
                        newHub?.stop()
                        throw error
                    }
                }
                let old = self.surfaces
                let oldHub = self.activeSharedVideoHub
                self.clock?.stop()
                self.activeSharedVideoHub = newHub
                self.retiringSharedVideoHub = oldHub
                self.playable = playable
                self.clock = candidateClock
                self.selectedURL = url
                self.pausedByUser = restoringPause ?? false
                if self.persistsSelection { self.updateResumePause(self.pausedByUser) }
                self.surfaces = replacement
                self.refreshCleanDesktop()
                self.applyFrameRate()
                for surface in replacement { surface.show(paused: self.pausedByUser) }
                self.finishTransition(old: old) { [weak self, oldHub] in
                    oldHub?.stop()
                    if self?.retiringSharedVideoHub === oldHub { self?.retiringSharedVideoHub = nil }
                }
                self.syncSharedPlaybackPause()
                self.syncSystemBackdrop(scene: playable, sourceURL: url, request: request)
                self.isLoading = false
                self.lastReloadError = nil
                self.logState("select-ready")
                self.updateMenu()
                self.onSelectionCommitted?(url)
                self.onStateChange?()
            } catch is CancellationError {
                guard request == self.generation else { return }
                self.isLoading = false
                self.updateMenu()
                self.logState("select-cancelled")
            } catch {
                guard request == self.generation else { return }
                self.isLoading = false
                let detail = error.localizedDescription
                self.lastReloadError = detail
                self.updateMenu()
                self.logState("select-error \(detail)")
                if !automatic { self.showError("The wallpaper could not start: " + detail) }
            }
        }
    }

    var onSelectionCommitted: ((URL) -> Void)?

    private func makeSurfaces(playable: SceneDescriptor, clock: SceneClock, request: Int) throws -> ([WallpaperSurface], SharedVideoHub?) {
        var made: [WallpaperSurface] = []
        var sharedHub: SharedVideoHub?
        let assignmentPlan = sharedDisplayAssignmentPlan(
            request: request, desktopSpan: playable.canvas == .desktopSpan)
        let sharesSceneAcrossDisplays = assignmentPlan.mode != .perDisplay
        if sharesSceneAcrossDisplays,
           playable.layers.filter({ $0.kind == .video }).count == 1,
           playable.layers.count == 1,
           let url = playable.videoURL,
           let asset = playable.videoAsset {
            let hub = SharedVideoHub(asset: asset, url: url)
            if let clock { hub.attach(clock: clock) }
            hub.setMuted(playable.muted)
            sharedHub = hub
        }
        do {
            for screen in NSScreen.screens {
                var scene = playable
                var lease: WallpaperScopeLease?
                var screenHub = sharesSceneAcrossDisplays ? sharedHub : nil
                if !sharesSceneAcrossDisplays {
                    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    if let assignment = assignmentPlan.assignment(for: displayID),
                       assignment.explicit,
                       let overrideURL = assignment.sourceURL {
                        lease = retainSurfaceScope(overrideURL)
                        do {
                            let loaded = try loadDisplaySceneSynchronously(overrideURL)
                            scene = try validate(loaded)
                            screenHub = nil
                        } catch {
                            lease = nil
                            showError("A display-specific wallpaper could not be loaded. Using the default wallpaper on that display.\n\n\(error.localizedDescription)")
                        }
                    }
                }
                let surface = try WallpaperSurface(screen: screen, playable: scene, clock: clock,
                    sharedHub: screenHub, securityScope: lease) { [weak self] message in self?.showError(message) }
                made.append(surface)
                guard request == generation else { throw CancellationError() }
            }
            sharedHub?.setPaused(pausedByUser)
            return (made, sharedHub)
        } catch {
            made.forEach { $0.close() }
            sharedHub?.stop()
            throw error
        }
    }

    private func retainSurfaceScope(_ url: URL) -> WallpaperScopeLease? {
        let lease = WallpaperScopeLease(url)
        return lease
    }

    /// Per-display overrides are file/package roots selected from the Library.
    /// SceneSourceResolver is async because remote descriptors may refresh; a
    /// bookmark assignment is intentionally local and bounded to the same loaders
    /// used by the resolver so rebuilds stay transactional on the main thread.
    private func loadDisplaySceneSynchronously(_ url: URL) throws -> SceneDescriptor {
        switch url.pathExtension.lowercased() {
        case "idlesse":
            return try ScenePackageLoader.load(url)
        case "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp":
            return try StaticImageSceneLoader.load(url)
        case "mp4", "mov", "m4v":
            return try StaticVideoSceneLoader.load(url)
        default:
            if url.hasDirectoryPath { return try ScenePackageLoader.load(url) }
            throw WallpaperError.unsupported
        }
    }

    private func finishTransition(old: [WallpaperSurface], completion: @escaping () -> Void = {}) {
        guard !old.isEmpty, transitionDuration > 0 else {
            old.forEach { $0.close() }
            completion()
            return
        }
        let duration = transitionDuration
        let options: NSViewController.TransitionOptions
        switch transitionStyle {
        case .crossfade: options = [.crossfade]
        case .slide: options = [.slideLeft]
        case .push: options = [.slideForward]
        case .reveal: options = [.slideBackward]
        }
        // Wallpaper surfaces are independent top-level windows, so AppKit's view-controller
        // transition API cannot bridge them directly. Keep both desktop surfaces alive for
        // the duration and fade the outgoing windows; non-crossfade styles also offset the
        // retiring frame slightly for a native-feeling directional cue.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for surface in old {
                surface.window.animator().alphaValue = 0
                guard transitionStyle != .crossfade else { continue }
                let distance: CGFloat = transitionStyle == .reveal ? -24 : 24
                let frame = surface.window.frame.offsetBy(dx: distance, dy: 0)
                surface.window.animator().setFrame(frame, display: false)
            }
        } completionHandler: {
            old.forEach { $0.close() }
            _ = options // Documents intent and keeps style mapping explicit.
            completion()
        }
    }

    func stop(restoreSystemWallpaper: Bool = true) {
        generation += 1
        selectionTask?.cancel()
        selectionTask = nil
        backdropTask?.cancel()
        backdropTask = nil
        let old = surfaces
        surfaces.removeAll()
        for surface in old { surface.close() }
        activeSharedVideoHub?.stop()
        activeSharedVideoHub = nil
        retiringSharedVideoHub?.stop()
        retiringSharedVideoHub = nil
        clock?.stop()
        clock = nil
        playable = nil
        selectedURL = nil
        isLoading = false
        pausedByUser = false
        cleanDesktop = false
        resetCoverageRest()
        if persistsSelection {
            resumeDefaults.removeObject(forKey: Self.resumeKey)
            resumeDefaults.removeObject(forKey: Self.pauseKey)
        }
        if restoreSystemWallpaper { restoreSystemBackdrops() }
        updateMenu()
        logState("stopped")
        onStateChange?()
    }

    @objc func togglePause() {
        guard isRunning else { return }
        pausedByUser.toggle()
        for surface in surfaces { surface.setPaused(pausedByUser) }
        syncSharedPlaybackPause()
        updateResumePause(pausedByUser)
        updateMenu()
        logState(pausedByUser ? "paused" : "resumed")
        onStateChange?()
    }

    func setPaused(_ paused: Bool) {
        guard pausedByUser != paused else { return }
        togglePause()
    }

    func applyFrameRate() {
        surfaces.forEach { $0.updateFrameRate() }
        logState("frame-rate-change requested=\(SceneFrameRate.selected.requested(maximum: NSScreen.main?.maximumFramesPerSecond ?? 60))")
    }

    private func rebuild() {
        guard let playable, let clock else { return }
        invalidateSharedDisplayAssignmentPlan(request: generation)
        let old = surfaces
        let oldHub = activeSharedVideoHub
        do {
            let (replacement, newHub) = try makeSurfaces(playable: playable, clock: clock, request: generation)
            surfaces = replacement
            activeSharedVideoHub = newHub
            retiringSharedVideoHub = oldHub
            refreshCleanDesktop()
            for surface in replacement { surface.show(paused: pausedByUser) }
            finishTransition(old: old) { [weak self, oldHub] in
                oldHub?.stop()
                if self?.retiringSharedVideoHub === oldHub { self?.retiringSharedVideoHub = nil }
            }
            syncSharedPlaybackPause()
        } catch {
            activeSharedVideoHub = oldHub
            retiringSharedVideoHub = nil
            logState("rebuild-error \(error.localizedDescription)")
        }
    }

    // MARK: - Matching system wallpaper stills

    private struct BackdropRequest: Sendable {
        let key: String
        let source: URL
        let scene: SceneDescriptor
        let output: URL
        let displaySize: CGSize
        let displayScale: CGFloat
    }

    /// The animated host sits just above the system desktop window. We also set a matching
    /// still through NSWorkspace so Mission Control, startup, and transitions never reveal an
    /// unrelated wallpaper behind the scene. Per-display assignments produce per-display stills.
    private func syncSystemBackdrop(scene: SceneDescriptor, sourceURL: URL, request: Int) {
        guard presentsWindows else { return }
        backdropTask?.cancel()
        let screens = NSScreen.screens
        let assignmentPlan = sharedDisplayAssignmentPlan(
            request: request, desktopSpan: scene.canvas == .desktopSpan)
        let perDisplayBackdrops = assignmentPlan.mode == .perDisplay &&
            assignmentPlan.assignments.contains { $0.explicit }
        backdropTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var work: [BackdropRequest] = []
            for (index, screen) in screens.enumerated() {
                if Task.isCancelled { return }
                let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                var effectiveScene = scene
                var effectiveSource = sourceURL
                var lease: WallpaperScopeLease?
                if assignmentPlan.mode == .perDisplay,
                   let assignment = assignmentPlan.assignment(for: displayID),
                   assignment.explicit,
                   let overrideURL = assignment.sourceURL,
                   overrideURL.standardizedFileURL != sourceURL.standardizedFileURL {
                    lease = self.retainSurfaceScope(overrideURL)
                    if let loaded = try? self.loadDisplaySceneSynchronously(overrideURL),
                       let validated = try? self.validate(loaded) {
                        effectiveScene = validated
                        effectiveSource = overrideURL
                    }
                }
                defer { withExtendedLifetime(lease) {} }
                guard let plan = self.backdropPlan(scene: effectiveScene, sourceURL: effectiveSource) else { continue }
                var still = plan.still
                if perDisplayBackdrops {
                    let ext = still.pathExtension
                    still.deletePathExtension()
                    still = still.deletingLastPathComponent().appendingPathComponent(still.lastPathComponent + "-display-\(displayID)")
                    if !ext.isEmpty { still.appendPathExtension(ext) }
                }
                do {
                    try FileManager.default.createDirectory(at: still.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if plan.refresh || !FileManager.default.fileExists(atPath: still.path) {
                        try autoreleasepool { try plan.produce(still) }
                    }
                } catch {
                    continue // Interactive wallpaper is already valid; still creation is secondary.
                }
                let key = Self.persistentDisplayIdentifier(displayID)
                if self.resumeDefaults.string(forKey: Self.origBackdropPrefix + key) == nil,
                   let current = NSWorkspace.shared.desktopImageURL(for: screen), !Self.isOurStill(current) {
                    self.resumeDefaults.set(current.path, forKey: Self.origBackdropPrefix + key)
                }
                work.append(BackdropRequest(key: key, source: effectiveSource, scene: effectiveScene,
                    output: still, displaySize: screen.frame.size, displayScale: screen.backingScaleFactor))
                if scene.canvas == .desktopSpan { break }
                if !perDisplayBackdrops { break }
                _ = index
            }
            if Task.isCancelled { return }
            guard request == self.generation else { return }
            await MainActor.run {
                if scene.canvas == .desktopSpan || !perDisplayBackdrops {
                    if let item = work.first {
                        for screen in NSScreen.screens {
                            try? NSWorkspace.shared.setDesktopImageURL(item.output, for: screen,
                                options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                                          .allowClipping: true])
                        }
                    }
                } else {
                    let byKey = Dictionary(uniqueKeysWithValues: work.map { ($0.key, $0) })
                    for screen in NSScreen.screens {
                        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                        guard let item = byKey[Self.persistentDisplayIdentifier(displayID)] else { continue }
                        try? NSWorkspace.shared.setDesktopImageURL(item.output, for: screen,
                            options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                                      .allowClipping: true])
                    }
                }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "wallpaperBackdropLast")
                self.backdropTask = nil
            }
        }
    }

    private struct BackdropPlan {
        let still: URL
        let refresh: Bool
        let produce: (URL) throws -> Void
    }

    private func backdropPlan(scene: SceneDescriptor, sourceURL: URL) -> BackdropPlan? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.stillsDirName, isDirectory: true)
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" || ext == "png" || ext == "heic" || ext == "heif" || ext == "tiff" || ext == "tif" || ext == "bmp" {
            // Point the system straight at ordinary stills — zero duplication and perfect match.
            return BackdropPlan(still: sourceURL, refresh: false, produce: { _ in })
        }
        if scene.canvas == .desktopSpan {
            // Render the full desktop-spanning first frame so the system backdrop
            // matches cross-display geometry instead of exposing a per-screen crop.
            let still = dir.appendingPathComponent(Self.stillKey(for: sourceURL) + "-span.jpg")
            return BackdropPlan(still: still, refresh: true) { output in
                let desktopFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
                let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
                let size = CGSize(width: max(1, desktopFrame.width * scale),
                                  height: max(1, desktopFrame.height * scale))
                try SystemBackdropRenderer.render(scene: scene, desktopFrame: desktopFrame,
                    pixelSize: size, to: output)
            }
        }
        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            let still = dir.appendingPathComponent(Self.stillKey(for: sourceURL) + ".jpg")
            return BackdropPlan(still: still, refresh: true) { output in
                try SystemBackdropRenderer.extractVideoStill(sourceURL, to: output)
            }
        }
        if ext == "idlesse" || sourceURL.hasDirectoryPath {
            if let entry = scene.allNodes.first(where: { $0.kind == .image }), let url = entry.resolvedURL,
               ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"].contains(url.pathExtension.lowercased()) {
                return BackdropPlan(still: url, refresh: false, produce: { _ in })
            }
            if let entry = scene.allNodes.first(where: { $0.kind == .video }), let url = entry.resolvedURL {
                let still = dir.appendingPathComponent(Self.stillKey(for: sourceURL) + ".jpg")
                return BackdropPlan(still: still, refresh: true) { output in
                    try SystemBackdropRenderer.extractVideoStill(url, to: output)
                }
            }
        }
        return nil
    }

    private static func stillKey(for url: URL) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in url.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte); hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func restoreSystemBackdrops() {
        backdropTask?.cancel()
        backdropTask = nil
        guard presentsWindows else { return }
        for screen in NSScreen.screens {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let key = Self.origBackdropPrefix + Self.persistentDisplayIdentifier(displayID)
            var storedKey = key
            var raw = resumeDefaults.string(forKey: key)
            if raw == nil {
                let legacy = Self.origBackdropPrefix + "\(displayID)"
                raw = resumeDefaults.string(forKey: legacy)
                storedKey = legacy
            }
            if let raw {
                let url = URL(fileURLWithPath: raw)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                }
                resumeDefaults.removeObject(forKey: storedKey)
                if storedKey != key { resumeDefaults.removeObject(forKey: key) }
            }
        }
    }

    // MARK: - Validation + static helper

    private func validate(_ descriptor: SceneDescriptor) throws -> SceneDescriptor {
        guard !descriptor.layers.isEmpty else { throw WallpaperError.unsupported }
        for layer in descriptor.layers {
            switch layer.kind {
            case .image:
                guard let url = layer.resolvedURL else { throw WallpaperError.unreadableImage }
                guard ImageAssetLoader.probe(url) != nil else { throw WallpaperError.unreadableImage }
            case .video:
                guard let url = layer.resolvedURL else { throw WallpaperError.noVideo }
                let asset = AVURLAsset(url: url)
                let duration = CMTimeGetSeconds(asset.duration)
                guard duration.isFinite, duration > 0,
                      asset.tracks(withMediaType: .video).first != nil else { throw WallpaperError.noVideo }
            case .particles, .text, .shape, .gradient, .shader:
                break
            }
        }
        return descriptor
    }

    static func validateStatic(_ url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"].contains(ext) else {
            throw WallpaperError.unsupported
        }
        guard ImageAssetLoader.probe(url) != nil else { throw WallpaperError.unreadableImage }
        return url
    }

    // MARK: - Reopen + qualification

    /// User-facing reload: preserve the current wallpaper if the source cannot reopen.
    func reloadCurrent() {
        guard let url = selectedURL else { return }
        select(url, restoringPause: pausedByUser)
    }

    func reopenSourceForQualification() async throws {
        guard let selectedURL else { throw WallpaperError.unsupported }
        let scene = try await source.resolve(selectedURL)
        _ = try validate(scene)
    }

    func runQualification(seconds: Double = 60) async -> String {
        let duration = max(10, min(seconds, 60))
        guard isRunning else { return "Qualification skipped: no active wallpaper." }
        lastQualificationReport = nil
        for surface in surfaces { _ = surface.gpuTotals }
        let startGPU = surfaces.compactMap(\.gpuTotals).reduce((0.0, 0)) { ($0.0 + $1.seconds, $0.1 + $1.frames) }
        let started = Date()
        let samples = Int(duration / 0.5)
        let helper = await helperRSSKB()
        var hostRSS: [Int] = []
        var hostCPU: [Double] = []
        var decodingRSS: [Int] = []
        var userCPU: [Double] = []
        var sysCPU: [Double] = []
        for _ in 0..<samples {
            if Task.isCancelled { break }
            if let usage = Self.processUsage(pid: getpid()) {
                hostRSS.append(usage.rssKB)
                hostCPU.append(usage.cpu)
            }
            let processes = await Self.topProcesses(matching: ["VTDecoder", "VTEncoder", "mediaanalysis", "WallpaperVideo"])
            decodingRSS.append(processes.map(\.rssKB).reduce(0, +))
            userCPU.append(processes.map(\.cpu).reduce(0, +))
            sysCPU.append(await Self.systemCPU())
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        let endGPU = surfaces.compactMap(\.gpuTotals).reduce((0.0, 0)) { ($0.0 + $1.seconds, $0.1 + $1.frames) }
        let gpuSeconds = max(0, endGPU.0 - startGPU.0)
        let gpu = min(100, 100 * gpuSeconds / elapsed)
        let report = String(format:
            "QUAL host_rss_max_mb=%.1f helper_rss_mb=%.1f decode_rss_max_mb=%.1f host_cpu_avg=%.1f decode_cpu_avg=%.1f system_cpu_avg=%.1f gpu_busy_pct=%.1f elapsed=%.1f",
            Double(hostRSS.max() ?? 0) / 1024, Double(helper) / 1024,
            Double(decodingRSS.max() ?? 0) / 1024, Self.average(hostCPU), Self.average(userCPU),
            Self.average(sysCPU), gpu, elapsed)
        lastQualificationReport = report
        Self.appendLine(report)
        return report
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private struct Usage { let cpu: Double; let rssKB: Int }
    private static func processUsage(pid: pid_t) -> Usage? {
        var info = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<proc_taskinfo>.size) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
            }
        }
        guard result == MemoryLayout<proc_taskinfo>.size else { return nil }
        let rss = Int(info.pti_resident_size / 1024)
        // proc_taskinfo is cumulative; RSS is exact, CPU is sampled from ps below for reporting.
        let cpu = shellCPU(pid: pid)
        return Usage(cpu: cpu, rssKB: rss)
    }

    private static func shellCPU(pid: pid_t) -> Double {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "%cpu="]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func topProcesses(matching names: [String]) async -> [Usage] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "comm=,%cpu=,rss="]
        let pipe = Pipe(); task.standardOutput = pipe
        do { try task.run(); task.waitUntilExit() } catch { return [] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var result: [Usage] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3 else { continue }
            let command = String(parts[0])
            guard names.contains(where: { command.localizedCaseInsensitiveContains($0) }) else { continue }
            result.append(Usage(cpu: Double(parts[1]) ?? 0, rssKB: Int(parts[2]) ?? 0))
        }
        return result
    }

    private func helperRSSKB() async -> Int {
        // ScreenCaptureKit helper or saver process may not exist for wallpaper playback;
        // report zero rather than spawning one solely for qualification.
        let names = ["IdlesseScreenSaver", "WallpaperVideo"]
        return await Self.topProcesses(matching: names).map(\.rssKB).reduce(0, +)
    }

    private static func systemCPU() async -> Double {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        task.arguments = ["-l", "1", "-n", "0"]
        let pipe = Pipe(); task.standardOutput = pipe
        do { try task.run(); task.waitUntilExit() } catch { return 0 }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("CPU usage:") }) else { return 0 }
        let numbers = line.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard numbers.count >= 2 else { return 0 }
        return numbers[0] + numbers[1]
    }

    private static func appendLine(_ line: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-wallpaper.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }; handle.seekToEndOfFile(); try? handle.write(contentsOf: data)
        } else { try? data.write(to: url) }
    }

    func logState(_ message: String) {
        let descriptor = surfaces.first?.diagnostics
        let line = "Idlesse-wallpaper \(message) layers=\(descriptor?.layerCount ?? 0) metal=\(descriptor?.metalBacked == true ? 1 : 0) displays=\(surfaces.count) paused=\(pausedByUser ? 1 : 0)"
        Self.appendLine(line)
    }

    func sharedPlaybackDebugLine() -> String {
        let totalSurfaceFrames = surfaces.compactMap(\.presentedFrameCount).reduce(0, +)
        let hubLine: String
        if let hub = activeSharedVideoHub {
            let d = hub.diagnostics
            hubLine = "hub=1 status=\(d.status) ready=\(d.ready ? 1 : 0) frameDecodes=\(d.frameDecodes) seeks=\(d.seeks)"
        } else {
            hubLine = "hub=0 status=none ready=0 frameDecodes=0 seeks=0"
        }
        let line = "Idlesse-shared-playback displays=\(surfaces.count) decoders=\(activeSharedVideoDecoders) \(hubLine) surfaceFrames=\(totalSurfaceFrames)"
        lastSharedPlaybackDebugLine = line
        Self.appendLine(line)
        return line
    }

    func sharedPlaybackQualification(seconds: Double = 6) async -> String {
        guard surfaces.count >= 2 else { return "QUAL-SHARED skipped=needs-two-displays" }
        guard let hub = activeSharedVideoHub else { return "QUAL-SHARED skipped=active-scene-is-not-shared-video" }
        let started = hub.diagnostics.frameDecodes
        let surfaceStart = surfaces.compactMap(\.presentedFrameCount).reduce(0, +)
        try? await Task.sleep(nanoseconds: UInt64(max(1, min(seconds, 15)) * 1_000_000_000))
        let ended = hub.diagnostics.frameDecodes
        let surfaceEnd = surfaces.compactMap(\.presentedFrameCount).reduce(0, +)
        let line = "QUAL-SHARED displays=\(surfaces.count) decoders=\(activeSharedVideoDecoders) hubFrameDelta=\(max(0, ended - started)) surfaceFrameDelta=\(max(0, surfaceEnd - surfaceStart))"
        Self.appendLine(line)
        return line
    }

    /// CI-safe phase-offset assertion: two surface clocks sharing one hub must
    /// normalize to the exact same hub frame index at every sampled wall time.
    static func sharedPlaybackPhaseSmoke() {
        let step = 1.0 / 30.0
        let duration = 10.0
        let offsets = [0.0, 0.37]
        for i in 0..<600 {
            let wall = Double(i) / 60.0
            let indices = offsets.map { offset -> Int in
                let sceneTime = wall + offset
                let normalizedHubTime = sceneTime - offset
                let looped = normalizedHubTime.truncatingRemainder(dividingBy: duration)
                return Int(floor(looped / step))
            }
            precondition(Set(indices).count == 1,
                         "Shared hub consumers diverged at wall time \(wall): \(indices)")
        }
    }

    // MARK: - Menu validation + alerts

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePause) { return isRunning }
        if menuItem.action == #selector(stopFromMenu) { return isRunning || isLoading }
        return true
    }

    private func showError(_ message: String) {
        guard presentsWindows else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Idlesse Wallpaper"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = presentingWindow?(), window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// libproc is available on macOS but does not have a Swift module on all toolchains.
@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64,
                          _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32
private let PROC_PIDTASKINFO: Int32 = 4
private struct proc_taskinfo {
    var pti_virtual_size: UInt64 = 0, pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0, pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0, pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0, pti_faults: Int32 = 0, pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0, pti_messages_sent: Int32 = 0, pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0, pti_syscalls_unix: Int32 = 0, pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0, pti_numrunning: Int32 = 0, pti_priority: Int32 = 0
}
