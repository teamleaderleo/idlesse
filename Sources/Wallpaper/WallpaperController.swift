import AppKit
import AVFoundation
import UniformTypeIdentifiers

private final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperSurface {
    let window: NSWindow
    private let renderer: SceneRenderer
    var diagnostics: RendererDiagnostics { renderer.diagnostics }
    func updateScene(_ scene: SceneDescriptor) -> Bool { renderer.updateScene(scene) }

    init(screen: NSScreen, playable: SceneDescriptor, clock: SceneClock, onError: @escaping (String) -> Void) throws {
        window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
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
        if playable.requiresMetal || ProcessInfo.processInfo.environment["IDLESSE_METAL_COMPOSITOR"] == "1" {
            renderer = try MetalSceneRenderer(playable: playable, bounds: bounds,
                scale: screen.backingScaleFactor, clock: clock, onError: onError)
        } else {
            renderer = try LayeredSceneRenderer(playable: playable, bounds: bounds,
                scale: screen.backingScaleFactor, clock: clock, onError: onError)
        }
        if let metal = renderer as? MetalSceneRenderer, playable.canvas == .desktopSpan {
            metal.desktopFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            metal.displayFrame = screen.frame
        }
        window.contentView = renderer.view
        updateFrameRate()
    }

    func updateFrameRate() {
        renderer.setPreferredFrameRate(SceneFrameRate.selected.requested(maximum: window.screen?.maximumFramesPerSecond ?? 60))
    }

    func show(paused: Bool) {
        window.orderBack(nil)
        setPaused(paused)
    }

    func setPaused(_ paused: Bool) { renderer.setPaused(paused) }

    func close() {
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

/// A sibling to the saver. Does not mutate macOS's wallpaper or ScreenSaverDefaults.
final class WallpaperController: NSObject, NSMenuItemValidation {
    private(set) var surfaces: [WallpaperSurface] = []
    private(set) var selectedURL: URL?
    private(set) var pausedByUser = false
    private var playable: SceneDescriptor?
    private var selectedIsAnimated: Bool { playable?.animated ?? false }
    private var clock = SceneClock()
    private var audioSession: SceneAudioSession?
    private var watcher: SceneWatcher?
    private(set) var lastReloadError: String?
    private(set) var revision = 0
    var sceneTime: TimeInterval { clock.time }
    private let source: SceneSource = LocalSceneSource()
    private var scopeStarted = false
    private var retiring: [WallpaperSurface] = []
    private var retiringURL: URL?
    private var transitionTimer: Timer?
    var transitionDuration: Double {
        get { let value = UserDefaults.standard.double(forKey: "wallpaperTransitionSeconds"); return [0, 0.5, 1, 2].contains(value) ? value : 0 }
        set { UserDefaults.standard.set([0, 0.5, 1, 2].contains(newValue) ? newValue : 0, forKey: "wallpaperTransitionSeconds") }
    }
    private var asleep = false
    private var systemAsleep = false
    var presentsWindows = true
    var onError: ((String) -> Void)?
    private var sessionInactive = false
    private var generation = 0
    private var surfaceGeneration = 0
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var screenRefresh: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var statusItem: NSStatusItem?
    private var chooser: NSOpenPanel?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onShowPreview: (() -> Void)?
    var presentingWindow: (() -> NSWindow?)?
    var onStateChange: (() -> Void)?
    weak var comfort: DesktopComfortController?
    private var dimmedForBedtime = false

    var isRunning: Bool { selectedURL != nil }
    private var suspended: Bool { asleep || systemAsleep || sessionInactive }
    private var shouldPause: Bool { pausedByUser || dimmedForBedtime || ProcessInfo.processInfo.isLowPowerModeEnabled }

    override init() {
        super.init()
        observe(.default, SceneFrameRate.changed) { controller in
            controller.surfaces.forEach { $0.updateFrameRate() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setAsleep(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setAsleep(false) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSystemAsleep(true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSystemAsleep(false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSessionInactive(true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSessionInactive(false) }
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange) { controller in
            controller.clock.setPaused(controller.suspended || controller.shouldPause)
            controller.surfaces.forEach { $0.setPaused(controller.shouldPause) }
            controller.updateMenu()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.screenRefresh?.cancel()
            let work = DispatchWorkItem { [weak controller] in controller?.rebuild() }
            controller.screenRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (WallpaperController) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { action(self) }
        }
        observers.append((center, observer))
    }

    @objc func chooseWallpaper() {
        if let chooser { chooser.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Choose your wallpaper"
        panel.message = "One image or muted looping video, on every display. Stop any time from the Idlesse menu."
        panel.prompt = "Use Wallpaper"
        panel.allowedContentTypes = [.directory, .jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie, UTType(exportedAs: "com.teamleaderleo.idlesse.scene", conformingTo: .package)]
        panel.treatsFilePackagesAsDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedURL?.deletingLastPathComponent()
        chooser = panel
        NSApp.activate(ignoringOtherApps: true)
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.chooser = nil
            guard response == .OK, let url = panel.url else {
                if self?.isRunning == true { self?.onStart?() }
                return
            }
            self?.select(url)
        }
        onShowPreview?()
        if let owner = presentingWindow?() {
            panel.beginSheetModal(for: owner, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    static func isVideo(_ url: URL) throws -> Bool {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic": return false
        case "mp4", "mov": return true
        default: throw WallpaperError.unsupported
        }
    }

    var onManualSelection: (() -> Void)?
    func select(_ url: URL, reloading: Bool = false, automatic: Bool = false) {
        if !reloading && !automatic { onManualSelection?() }
        if !reloading { watcher = nil }
        generation += 1
        let request = generation
        loadTask?.cancel()
        finishTransition()
        isLoading = true
        ensureStatusItem()
        updateMenu()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let access = url.startAccessingSecurityScopedResource()
            var adopted = false
            defer {
                if access && !adopted { url.stopAccessingSecurityScopedResource() }
                if request == self.generation {
                    self.isLoading = false
                    self.updateMenu()
                }
            }
            do {
                let playable = try await self.source.resolve(url)
                for node in playable.allNodes where node.kind == .video {
                    guard let assetURL = node.assetURL else { continue }
                    let asset = AVURLAsset(url: assetURL)
                    let playable = try await asset.load(.isPlayable)
                    let duration = try await asset.load(.duration)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard playable, duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else {
                        throw WallpaperError.noVideo
                    }
                }
                guard !Task.isCancelled, request == self.generation else { return }
                // Build before replacing the old wallpaper, so a bad file leaves it intact.
                let reuseClock = reloading && self.playable?.timeline == playable.timeline
                let candidateClock = reuseClock ? self.clock : SceneClock()
                if !reuseClock {
                    try candidateClock.configure(timeline: playable.timeline)
                    candidateClock.pointerEnabled = reloading && self.clock.pointerEnabled
                    candidateClock.audioEnabled = reloading && self.clock.audioEnabled && playable.usesAudio
                }
                let replacement = self.suspended ? [] :
                    try self.makeSurfaces(playable: playable, clock: candidateClock, request: request)
                let fade = !reloading && self.presentsWindows && !self.suspended && !self.shouldPause &&
                    !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && self.transitionDuration > 0 && !self.surfaces.isEmpty
                if fade {
                    self.retiring = self.surfaces
                    self.retiring.forEach { $0.setPaused(true) }
                    self.retiringURL = self.scopeStarted ? self.selectedURL : nil
                    self.surfaces = []
                } else {
                    self.releaseSurfaces()
                    if self.scopeStarted { self.selectedURL?.stopAccessingSecurityScopedResource() }
                }
                self.selectedURL = url
                self.scopeStarted = access
                self.playable = playable
                adopted = true
                if !reloading { self.pausedByUser = false }
                if !reuseClock {
                    self.audioSession = nil
                    self.audioSession = SceneAudioSession(clock: candidateClock) { [weak self] message in
                        self?.onError?(message)
                        self?.lastReloadError = message
                        self?.updateMenu()
                    }
                }
                if !playable.usesAudio { candidateClock.audioEnabled = false }
                self.clock = candidateClock
                self.clock.setPaused(self.suspended || self.shouldPause)
                self.lastReloadError = nil
                self.revision += 1
                self.watch(url: url, scene: playable)
                self.surfaces = replacement
                replacement.forEach { $0.setPaused(self.shouldPause) }
                if self.suspended { self.releaseSurfaces() }
                else if self.presentsWindows {
                    replacement.forEach { $0.window.alphaValue = fade ? 0 : 1; $0.show(paused: self.shouldPause) }
                    if fade { self.beginTransition() }
                }
                self.ensureStatusItem()
                self.updateMenu()
                self.onStart?()
            } catch {
                guard !Task.isCancelled, request == self.generation else { return }
                if reloading {
                    self.lastReloadError = error.localizedDescription
                    self.updateMenu()
                } else {
                    if let previousURL = self.selectedURL, let previousScene = self.playable {
                        self.watch(url: previousURL, scene: previousScene)
                    }
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func watch(url: URL, scene: SceneDescriptor) {
        watcher = nil
        guard url.pathExtension.lowercased() == "idlesse" else { return }
        watcher = SceneWatcher(package: url, assets: scene.allNodes.compactMap { $0.assetURL }) { [weak self] in
            guard let self, self.selectedURL == url else { return }
            self.select(url, reloading: true)
        }
    }

    private func makeSurfaces(playable: SceneDescriptor, clock: SceneClock, request: Int) throws -> [WallpaperSurface] {
        surfaceGeneration += 1
        let surfaceRequest = surfaceGeneration
        var result: [WallpaperSurface] = []
        do {
            for screen in NSScreen.screens {
                let surface = try autoreleasepool {
                    try WallpaperSurface(screen: screen, playable: playable, clock: clock) { [weak self] message in
                        guard let self, self.generation == request,
                              self.surfaceGeneration == surfaceRequest else { return }
                        self.stop()
                        self.showError(message)
                    }
                }
                result.append(surface)
            }
            return result
        } catch {
            result.forEach { $0.close() }
            throw error
        }
    }

    private func rebuild() {
        guard let playable, !suspended else { return }
        // Release first on display changes to avoid temporarily doubling players.
        releaseSurfaces()
        do {
            surfaces = try makeSurfaces(playable: playable, clock: clock, request: generation)
            surfaces.forEach { $0.setPaused(shouldPause) }
            if presentsWindows { surfaces.forEach { $0.show(paused: shouldPause) } }
        } catch {
            stop()
            showError(error.localizedDescription)
        }
        updateMenu()
    }

    func setSystemAsleep(_ value: Bool) {
        guard systemAsleep != value else { return }
        systemAsleep = value
        clock.setPaused(suspended || shouldPause)
        if suspended { releaseSurfaces() } else { rebuild() }
        updateMenu()
    }

    func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value
        clock.setPaused(suspended || shouldPause)
        if suspended { releaseSurfaces() } else { rebuild() }
        updateMenu()
    }

    func setSessionInactive(_ value: Bool) {
        guard sessionInactive != value else { return }
        sessionInactive = value
        clock.setPaused(suspended || shouldPause)
        if suspended { releaseSurfaces() } else { rebuild() }
        updateMenu()
    }

    func setDimmedForBedtime(_ value: Bool) {
        finishTransition()
        dimmedForBedtime = value
        clock.setPaused(suspended || shouldPause)
        surfaces.forEach { $0.setPaused(shouldPause) }
        updateMenu()
    }

    @objc func togglePause() {
        finishTransition()
        pausedByUser.toggle()
        clock.setPaused(suspended || shouldPause)
        surfaces.forEach { $0.setPaused(shouldPause) }
        updateMenu()
    }

    @objc func stop() {
        onManualSelection?()
        let wasActive = isRunning || isLoading
        watcher = nil
        lastReloadError = nil
        clock.setPaused(true)
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        screenRefresh?.cancel()
        screenRefresh = nil
        releaseSurfaces()
        if scopeStarted { selectedURL?.stopAccessingSecurityScopedResource() }
        scopeStarted = false
        selectedURL = nil
        playable = nil
        isLoading = false
        pausedByUser = false
        updateMenu()
        if wasActive { onStop?() }
    }

    private func releaseSurfaces() {
        finishTransition()
        surfaces.forEach { $0.close() }
        surfaces.removeAll()
    }

    private func beginTransition() {
        for (next, old) in zip(surfaces, retiring) {
            next.window.order(.above, relativeTo: old.window.windowNumber)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let duration = transitionDuration
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / max(0.01, duration))
            self.surfaces.forEach { $0.window.alphaValue = progress * progress * (3 - 2 * progress) }
            if progress >= 1 { self.finishTransition() }
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishTransition() {
        transitionTimer?.invalidate(); transitionTimer = nil
        surfaces.forEach { $0.window.alphaValue = 1 }
        retiring.forEach { $0.close() }; retiring.removeAll()
        retiringURL?.stopAccessingSecurityScopedResource(); retiringURL = nil
    }

    @objc private func changeTransition(_ sender: NSMenuItem) {
        transitionDuration = sender.representedObject as? Double ?? 0
        updateMenu()
    }

    private func ensureStatusItem() {
        guard presentsWindows, statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Idlesse Wallpaper")
        item.button?.toolTip = "Idlesse Wallpaper"
        statusItem = item
    }

    private func updateMenu() {
        let menu = NSMenu()
        let state = isLoading ? "Opening wallpaper…" : selectedURL == nil ? "Wallpaper stopped" :
            (suspended ? "Waiting for your display" : (shouldPause && selectedIsAnimated ? "Scene paused" : "Wallpaper running"))
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        if let lastReloadError { menu.addItem(withTitle: "Edit not applied: " + lastReloadError, action: nil, keyEquivalent: "") }
        if let selectedURL { menu.addItem(withTitle: selectedURL.lastPathComponent, action: nil, keyEquivalent: "") }
        if let playable, !playable.parameters.isEmpty {
            let controls = addItem(menu, "Scene Controls…", #selector(editControls))
            controls.isEnabled = !isLoading
        }
        if playable?.usesPointer == true {
            let pointer = addItem(menu, "Enable Pointer Response", #selector(togglePointer))
            pointer.state = clock.pointerEnabled ? .on : .off
            pointer.isEnabled = !isLoading
        }
        if playable?.usesAudio == true {
            let audio = addItem(menu, "Enable Audio Response", #selector(toggleAudio))
            audio.state = clock.audioEnabled ? .on : .off
            audio.isEnabled = !isLoading
        }
        menu.addItem(.separator())
        addItem(menu, "Choose Wallpaper…", #selector(chooseWallpaper))
        let transition = NSMenuItem(title: "Scene Transition", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for seconds in [0.0, 0.5, 1.0, 2.0] {
            let item = addItem(choices, seconds == 0 ? "Instant" : "Crossfade · \(seconds) seconds", #selector(changeTransition(_:)))
            item.representedObject = seconds
            item.state = transitionDuration == seconds ? .on : .off
        }
        transition.submenu = choices; menu.addItem(transition)
        let pause = addItem(menu, pausedByUser ? "Resume Scene" : "Pause Scene", #selector(togglePause))
        pause.isEnabled = isRunning && selectedIsAnimated
        let stop = addItem(menu, "Stop Wallpaper", #selector(self.stop))
        stop.isEnabled = isRunning || isLoading
        menu.addItem(.separator())
        addItem(menu, "Show Preview", #selector(showPreview))
        if let comfort {
            let item = menu.addItem(withTitle: "Bedtime Display…", action: #selector(DesktopComfortController.showSettings), keyEquivalent: "")
            item.target = comfort
        }
        addItem(menu, "Quit Idlesse", #selector(quit))
        menu.autoenablesItems = false
        statusItem?.menu = menu
        onStateChange?()
    }

    @discardableResult private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(togglePause) {
            item.title = pausedByUser ? "Resume Scene" : "Pause Scene"
            return isRunning && selectedIsAnimated
        }
        if item.action == #selector(stop) { return isRunning || isLoading }
        return true
    }

    @objc private func showPreview() { onShowPreview?() }
    @objc private func toggleAudio() {
        guard let playable, playable.usesAudio, !isLoading else { return }
        clock.audioEnabled.toggle()
        surfaces.forEach { _ = $0.updateScene(playable) }
        updateMenu()
    }
    @objc private func togglePointer() {
        guard let playable, !isLoading else { return }
        clock.pointerEnabled.toggle()
        surfaces.forEach { _ = $0.updateScene(playable) }
        updateMenu()
    }
    @objc private func editControls() {
        guard let original = playable, !isLoading else { return }
        SceneParameterControls.present(scene: original, window: nil) { [weak self] parameters in
            guard let self, self.playable?.parameters == original.parameters, !self.isLoading,
                  self.playable?.allNodes.map(\.id) == original.allNodes.map(\.id) else { return }
            var next = original
            next.parameters = parameters
            do { _ = try next.evaluated() } catch { self.showError(error.localizedDescription); return }
            for surface in self.surfaces {
                guard surface.updateScene(next) else {
                    self.surfaces.forEach { _ = $0.updateScene(original) }
                    self.showError("The scene controls could not be applied. The previous values were restored.")
                    return
                }
            }
            self.playable = next
            self.updateMenu()
        }
    }
    @objc private func quit() { onStop = nil; stop(); NSApp.terminate(nil) }

    private func showError(_ message: String) {
        if let onError { onError(message); return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t start that wallpaper"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    deinit {
        loadTask?.cancel()
        screenRefresh?.cancel()
        observers.forEach { $0.0.removeObserver($0.1) }
        releaseSurfaces()
        if scopeStarted { selectedURL?.stopAccessingSecurityScopedResource() }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
