import AppKit
import ScreenSaver

final class IdlesseAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var saverView: IdlesseView!
    private var settingsButton: NSButton!
    private var pauseButton: NSButton!
    private let wallpaper = WallpaperController()
    private let comfort = DesktopComfortController()
    private var library: SceneLibraryController?
    private func prepareLibrary() throws {
        if library == nil {
            library = try SceneLibraryController(onUse: { [weak self] url in self?.wallpaper.select(url, automatic: true) },
                onEdit: { [weak self] url, asCopy in self?.scenePreview.openLibraryScene(url, asCopy: asCopy) })
        }
        wallpaper.onManualSelection = { [weak self] in self?.library?.stopRotation() }
        library?.startSchedules()
    }
    @objc private func showLibrary() {
        do {
            try prepareLibrary()
            saverView?.stopAnimation()
            library?.show()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open the Library"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    private var pendingSceneURL: URL?
    private lazy var scenePreview = StudioWindowController { [weak self] url in self?.wallpaper.select(url) }
    @objc private func showScenePreview() {
        saverView?.stopAnimation()
        window?.orderOut(nil)
        scenePreview.onClose = { [weak self] in self?.showPreview() }
        scenePreview.show()
    }


    private lazy var settingsController = ConfigureSheetController(preferences: IdlessePreferences.shared) { [weak self] in
        self?.saverView?.reloadFromPreferences()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        wallpaper.onStart = { [weak self] in
            self?.saverView?.stopAnimation()
            self?.window?.orderOut(nil)
        }
        wallpaper.onStop = { [weak self] in self?.showPreview() }
        wallpaper.onShowPreview = { [weak self] in self?.showPreview() }
        wallpaper.presentingWindow = { [weak self] in self?.window }
        wallpaper.comfort = comfort
        comfort.onDimmingChanged = { [weak self] value in self?.wallpaper.setDimmedForBedtime(value) }
        comfort.start()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "Idlesse Preview"
        window.center()

        guard let contentView = window.contentView else { return }
        saverView = IdlesseView(frame: contentView.bounds, isPreview: false)
        saverView.autoresizingMask = [.width, .height]
        contentView.addSubview(saverView)

        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 14
        bar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)

        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        pauseButton.toolTip = "Pause or resume (Space)"
        let nextButton = NSButton(title: "Next", target: self, action: #selector(nextImage))
        nextButton.toolTip = "Next picture (→)"
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealImage))
        settingsButton = NSButton(title: "Settings…", target: self, action: #selector(showSettings))
        let wallpaperButton = NSButton(title: "Wallpaper…", target: wallpaper, action: #selector(WallpaperController.chooseWallpaper))
        wallpaperButton.bezelStyle = .rounded
        let sceneButton = NSButton(title: "Studio…", target: self, action: #selector(showScenePreview))
        sceneButton.bezelStyle = .rounded
        let libraryButton = NSButton(title: "Library…", target: self, action: #selector(showLibrary))
        libraryButton.bezelStyle = .rounded
        let controls = NSStackView(views: [pauseButton, nextButton, revealButton, settingsButton, wallpaperButton, sceneButton, libraryButton])
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        for button in [pauseButton!, nextButton, revealButton, settingsButton!] {
            button.bezelStyle = .rounded
        }
        bar.addSubview(controls)
        NSLayoutConstraint.activate([
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            bar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            controls.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            controls.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            controls.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12),
        ])
        window.minSize = NSSize(width: 900, height: 360)

        window.makeKeyAndOrderFront(nil)
        saverView.startAnimation()
        NSApp.activate(ignoringOtherApps: true)

        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let catalog = try SceneLibraryStore(file: support.appendingPathComponent("Idlesse/Library/index.json")).catalog
            if catalog.collections.contains(where: { $0.playback?.startMinute != nil }) { try prepareLibrary() }
        } catch { NSLog("Idlesse: saved Library schedules unavailable: %@", error.localizedDescription) }

        if let pendingSceneURL {
            wallpaper.select(pendingSceneURL)
            self.pendingSceneURL = nil
        } else if IdlessePreferences.shared.folderDisplayPath == nil {
            DispatchQueue.main.async { [weak self] in
                self?.showSettings()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil { pendingSceneURL = url }
        else { wallpaper.select(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        scenePreview.mayQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaper.onStop = nil
        wallpaper.stop()
        saverView?.stopAnimation()
    }

    func windowDidMiniaturize(_ notification: Notification) { saverView?.stopAnimation() }
    func windowDidDeminiaturize(_ notification: Notification) { saverView?.startAnimation() }
    func windowWillClose(_ notification: Notification) { saverView?.stopAnimation() }
    func applicationDidHide(_ notification: Notification) { saverView?.stopAnimation(); scenePreview.applicationVisibilityChanged() }
    func applicationDidUnhide(_ notification: Notification) {
        scenePreview.applicationVisibilityChanged()
        if window.isVisible && !window.isMiniaturized { saverView?.startAnimation() }
    }

    @objc private func showPreview() {
        window.makeKeyAndOrderFront(nil)
        saverView.startAnimation()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePause() {
        saverView.togglePlaybackPause()
        pauseButton.title = saverView.isPlaybackPaused ? "Resume" : "Pause"
    }

    @objc private func nextImage() { saverView.showNextImage() }

    @objc private func revealImage() {
        if let url = saverView.displayedFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func showSettings() {
        settingsController.reload()
        let settingsWindow = settingsController.window

        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveStudio() { scenePreview.saveDocument() }
    @objc private func saveStudioAs() { scenePreview.saveAsDocument() }
    @objc private func duplicateStudioLayer() { scenePreview.duplicateLayer() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePause) || menuItem.action == #selector(nextImage) {
            return window.isKeyWindow && !window.isMiniaturized
        }
        if [#selector(saveStudio), #selector(saveStudioAs), #selector(duplicateStudioLayer)].contains(menuItem.action) {
            return scenePreview.acceptsDocumentCommands
        }
        return true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Idlesse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        for (title, action, key) in [("Save", #selector(saveStudio), "s"), ("Save As…", #selector(saveStudioAs), "S")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == key.uppercased() ? [.command, .shift] : [.command]
            item.target = self
            fileMenu.addItem(item)
        }
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == key.uppercased() ? [.command, .shift] : [.command]
            edit.addItem(item)
        }

        let duplicate = NSMenuItem(title: "Duplicate Layer", action: #selector(duplicateStudioLayer), keyEquivalent: "d")
        duplicate.target = self
        edit.addItem(duplicate)
        let playbackItem = NSMenuItem()
        let playback = NSMenu(title: "Playback")
        playbackItem.submenu = playback
        mainMenu.addItem(playbackItem)
        for (title, action, key) in [
            ("Pause / Resume", #selector(togglePause), " "),
            ("Next Picture", #selector(nextImage), String(UnicodeScalar(NSRightArrowFunctionKey)!))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            item.target = self
            playback.addItem(item)
        }
        let wallpaperItem = NSMenuItem()
        let wallpaperMenu = NSMenu(title: "Wallpaper")
        wallpaperItem.submenu = wallpaperMenu
        mainMenu.addItem(wallpaperItem)
        for (title, action) in [
            ("Choose Wallpaper…", #selector(WallpaperController.chooseWallpaper)),
            ("Pause / Resume Video", #selector(WallpaperController.togglePause)),
            ("Stop Wallpaper", #selector(WallpaperController.stop))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = wallpaper
            wallpaperMenu.addItem(item)
        }
        let show = NSMenuItem(title: "Show Preview", action: #selector(showPreview), keyEquivalent: "")
        show.target = self
        wallpaperMenu.addItem(show)
        let scenePreviewItem = NSMenuItem(title: "Studio…", action: #selector(showScenePreview), keyEquivalent: "o")
        scenePreviewItem.target = self
        wallpaperMenu.addItem(scenePreviewItem)
        let libraryItem = wallpaperMenu.addItem(withTitle: "Library…", action: #selector(showLibrary), keyEquivalent: "l")
        libraryItem.target = self
        wallpaperMenu.addItem(.separator())
        let bedtime = wallpaperMenu.addItem(withTitle: "Bedtime Display…", action: #selector(DesktopComfortController.showSettings), keyEquivalent: "")
        bedtime.target = comfort
        let dim = wallpaperMenu.addItem(withTitle: "Dim / Restore Display", action: #selector(DesktopComfortController.toggle), keyEquivalent: "d")
        dim.keyEquivalentModifierMask = [.command, .option]
        dim.target = comfort
        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared

if let index = CommandLine.arguments.firstIndex(of: "--smoke-library"), CommandLine.arguments.count > index + 1 {
    do {
        let video = CommandLine.arguments.count > index + 2 ? URL(fileURLWithPath: CommandLine.arguments[index + 2]) : nil
        try SceneLibraryController.smokeTest(outputURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]), videoURL: video)
        exit(0)
    }
    catch { fputs("Library check failed: \(error.localizedDescription)\n", stderr); exit(1) }
}

// Deterministic, offscreen preview: no desktop windows, input grants, or UI activation.
if let index = CommandLine.arguments.firstIndex(of: "--smoke-export"), CommandLine.arguments.count > index + 1 {
    let video = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task { @MainActor in
        do { try await SceneVideoExporter.smokeTest(videoURL: video); exit(0) }
        catch { fputs("Export checks failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--export-video") {
    guard CommandLine.arguments.count > index + 5,
          let seconds = Double(CommandLine.arguments[index + 3]),
          let fps = Int(CommandLine.arguments[index + 4]),
          let width = Int(CommandLine.arguments[index + 5]), [1920, 3840].contains(width) else {
        fputs("Usage: --export-video input.idlesse output.mp4 seconds fps width(1920|3840)\n", stderr); exit(1)
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task { @MainActor in
        do {
            let scene = try await LocalSceneSource().resolve(input)
            try await SceneVideoExporter.export(scene, to: output, width: width, height: width * 9 / 16,
                                                fps: fps, duration: seconds, progress: { _ in })
            print("Exported " + output.path); exit(0)
        } catch { fputs("Export failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-scene") {
    guard CommandLine.arguments.count > index + 3,
          let seconds = Double(CommandLine.arguments[index + 3]), seconds.isFinite, (0...86400).contains(seconds) else {
        fputs("Usage: --render-scene input.idlesse output.png seconds\n", stderr); exit(1)
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task { @MainActor in
        do {
            let scene = try await LocalSceneSource().resolve(input)
            guard !scene.allNodes.contains(where: { $0.kind == .video }) else {
                throw SceneError.invalid("Offscreen export supports images and procedural scenes. Use Studio for video previews.")
            }
            let clock = SceneClock(now: { 0 })
            try clock.configure(timeline: scene.timeline)
            try clock.seek(to: seconds)
            let renderer = try MetalSceneRenderer(playable: scene, bounds: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                scale: 1, clock: clock) { fputs(($0 + "\n"), stderr) }
            defer { renderer.releaseResources() }
            let pixels = try renderer.renderProbe(signals: .init(time: clock.time), dimension: 1024)
            let data = Data(pixels)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw SceneError.invalid("Could not encode scene preview.")
            }
            try png.write(to: output, options: .withoutOverwriting)
            print("Rendered 1024×1024 preview at \(seconds)s; input permissions remain disabled.")
            exit(0)
        } catch { fputs((error.localizedDescription + "\n"), stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--benchmark"),
   CommandLine.arguments.count > index + 2 {
    do {
        try PlaybackBenchmark.run(mode: CommandLine.arguments[index + 1],
            folder: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Benchmark failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--smoke-audio"), CommandLine.arguments.count > index + 1 {
    do {
        try AudioSmoke.run(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Audio checks failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--smoke-wallpaper"),
   CommandLine.arguments.count > index + 1 {
    do {
        try WallpaperSmoke.run(videoURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Wallpaper checks failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--smoke-options") {
    let controller = ConfigureSheetController(preferences: IdlessePreferences.shared) {}
    controller.window.contentView?.layoutSubtreeIfNeeded()
    precondition(controller.window.canBecomeKey)
    precondition(ConfigureSheetController.timingNumber("2oops") == nil)
    precondition(ConfigureSheetController.timingNumber("") == nil)
    precondition(ConfigureSheetController.timingNumber("2") == 2)
    let content = controller.window.contentView!
    func checkButtons(_ view: NSView) {
        if let button = view as? NSButton, ["Choose…", "Save", "Cancel"].contains(button.title) {
            let frame = button.convert(button.bounds, to: content)
            precondition(frame.minX >= 16 && frame.maxX <= content.bounds.width - 16,
                         "Settings button escapes content margins: \(button.title)")
        }
        view.subviews.forEach(checkButtons)
    }
    checkButtons(content)
    print("Idlesse settings UI smoke test passed")
    exit(EXIT_SUCCESS)
}

let delegate = IdlesseAppDelegate()
app.delegate = delegate
app.run()
