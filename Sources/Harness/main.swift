import AppKit
import ScreenSaver

final class IdlesseAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var saverView: IdlesseView!
    private var settingsButton: NSButton!
    private var pauseButton: NSButton!
    private let wallpaper = WallpaperController()
    private var pendingSceneURL: URL?
    private lazy var scenePreview = ScenePreviewController { [weak self] url in self?.wallpaper.select(url) }
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
        let sceneButton = NSButton(title: "Scene Preview…", target: self, action: #selector(showScenePreview))
        sceneButton.bezelStyle = .rounded
        let controls = NSStackView(views: [pauseButton, nextButton, revealButton, settingsButton, wallpaperButton, sceneButton])
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePause) || menuItem.action == #selector(nextImage) {
            return window.isKeyWindow && !window.isMiniaturized
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
        appMenu.addItem(NSMenuItem(title: "Quit Idlesse Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        for (title, selector, key) in [
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }

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
        let scenePreviewItem = NSMenuItem(title: "Scene Preview…", action: #selector(showScenePreview), keyEquivalent: "o")
        scenePreviewItem.target = self
        wallpaperMenu.addItem(scenePreviewItem)
        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared

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
