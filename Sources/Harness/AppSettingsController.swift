import AppKit

/// Session frame restore that refuses garbage: a saved frame from a different
/// screen layout (or a runaway resize) that dwarfs the default size is
/// discarded in favor of a centered default. Self-heals poisoned defaults.
///
/// Deliberately manual (no setFrameAutosaveName): AppKit's lazy autosave
/// restore races validation and re-applies rejected frames after showing.
extension NSWindow {
    private static func managedFrameKey(_ name: String) -> String { "NSWindow Frame \(name)" }
    func restoreManagedFrame(name: String, defaultSize: NSSize) {
        var applied = false
        if let saved = NSWindow.managedFrame(name: name),
           saved.width <= defaultSize.width + 320, saved.height <= defaultSize.height + 230,
           saved.width >= 400, saved.height >= 300 {
            setFrame(saved, display: false)
            applied = true
        }
        if !applied {
            setContentSize(defaultSize)
            center()
            saveManagedFrame(name: name)
        }
        NSAccessibility.post(element: self, notification: .windowMoved)
        NSAccessibility.post(element: self, notification: .windowResized)
    }
    private static func managedFrame(name: String) -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: managedFrameKey(name)) else { return nil }
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 4 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
    func saveManagedFrame(name: String) {
        let f = frame
        guard f.width <= 1500, f.height <= 950, f.width >= 400, f.height >= 300 else { return }
        UserDefaults.standard.set(
            "\(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height)) 0 0 0 0",
            forKey: Self.managedFrameKey(name))
    }
}

/// Conventional preferences window. Home owns Library, Displays, Ambient Sets,
/// desktop state and automation; Settings keeps playback and screen-saver prefs.
final class AppSettingsController: NSWindowController, NSWindowDelegate {
    private let comfort: DesktopComfortController
    private let wallpaper: WallpaperController
    private let showSaver: () -> Void
    private let tabs = NSTabView()
    private var navigation: [NSButton] = []
    private var home: HomeWindowController?
    private var displaysDestination: DisplayAssignmentViewController?
    private weak var libraryWindow: NSWindow?

    /// Runtime dependency injected by the app delegate before Home is installed.
    /// It is deliberately absent from visible Settings UI.
    var modes: AmbientModesController?
    var onLibraryVisible: (() -> Void)?
    var onClose: (() -> Void)?

    private let liveMenu = NSButton(checkboxWithTitle: "Animate menu bar", target: nil, action: nil)
    private let batteryThrottle = NSButton(checkboxWithTitle: "Cap to 30 fps on battery", target: nil, action: nil)
    private let coveragePause = NSButton(checkboxWithTitle: "Rest fully covered displays", target: nil, action: nil)
    private let rate = NSPopUpButton()
    private let transition = NSPopUpButton()
    private let transitionStyle = NSPopUpButton()

    init(comfort: DesktopComfortController, wallpaper: WallpaperController, showSaver: @escaping () -> Void) {
        self.comfort = comfort
        self.wallpaper = wallpaper
        self.showSaver = showSaver
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Idlesse Settings"
        window.minSize = NSSize(width: 660, height: 450)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.restoreManagedFrame(name: "IdlessePreferences", defaultSize: NSSize(width: 720, height: 500))
        installContent(in: window)
        retargetSettingsCommand()
        wallpaper.onShowSettings = { [weak self] in self?.present(tab: 0) }
        wallpaper.onStateChange = { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Install Home around the Library's existing window. This is a one-time app
    /// bootstrap seam; Settings never owns or reparents Home content.
    func installLibrary(_ view: NSView) {
        guard home == nil,
              let modes,
              let library = view.window?.windowController as? SceneLibraryController else { return }
        libraryWindow = library.window
        library.hostWindow = library.window
        let displays = DisplayAssignmentViewController(wallpaper: wallpaper)
        displays.onArrangementChange = { [weak modes] in modes?.adoptManualDisplayArrangement() }
        displaysDestination = displays
        home = HomeWindowController(
            library: library,
            wallpaper: wallpaper,
            comfort: comfort,
            modes: modes,
            displaysDestinationController: displays,
            activateDisplaysDestination: { [weak displays] in displays?.activate() })
    }

    /// Historical callers use 3 for Library, 1 for the removed Automation pane,
    /// and 2 for Screen Saver. Preserve those routes while changing destinations.
    func present(tab: Int? = nil) {
        let requested = tab ?? 0
        if requested == 3 {
            onLibraryVisible?()
            if let home { home.presentLibrary() }
            else {
                libraryWindow?.deminiaturize(nil)
                libraryWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        if requested == 1, let home {
            home.presentAmbientSets()
            return
        }
        reload()
        selectPage(requested == 2 ? 1 : 0)
        window?.level = comfort.isDimmed ? .mainMenu : .normal
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.restoreManagedFrame(name: "IdlessePreferences", defaultSize: NSSize(width: 720, height: 500))
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentDisplays() { home?.presentDisplays() }
    func presentAmbientSets() { home?.presentAmbientSets() }

    @objc private func openSettingsFromMenu(_ sender: Any?) { present(tab: 0) }

    private func retargetSettingsCommand() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let item = appMenu.items.first(where: { $0.title == "Settings…" }) else { return }
        item.target = self
        item.action = #selector(openSettingsFromMenu(_:))
    }

    private func installContent(in window: NSWindow) {
        guard let root = window.contentView else { return }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let destinations: [(String, String)] = [
            ("Playback", "play.circle"),
            ("Screen Saver", "sparkles.tv"),
        ]
        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navStack)
        for (index, entry) in destinations.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: #selector(navigate(_:)))
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.0)
            button.imagePosition = .imageLeading
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.widthAnchor.constraint(equalToConstant: 156).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            navStack.addArrangedSubview(button)
            navigation.append(button)
        }

        tabs.tabViewType = .noTabsNoBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 180),
            navStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            navStack.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),
            navStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22),
            tabs.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        rate.addItems(withTitles: SceneFrameRate.allCases.map { $0 == .automatic ? "Auto" : $0.title })
        rate.target = self
        rate.action = #selector(changePlayback)
        rate.setAccessibilityLabel("Frame rate")
        transition.addItems(withTitles: ["None", "0.5 seconds", "1 second", "2 seconds"])
        transition.target = self
        transition.action = #selector(changePlayback)
        transition.setAccessibilityLabel("Transition duration")
        transitionStyle.addItems(withTitles: WallpaperController.TransitionStyle.allCases.map(\.title))
        transitionStyle.target = self
        transitionStyle.action = #selector(changePlayback)
        transitionStyle.setAccessibilityLabel("Transition style")
        let transitionRow = NSStackView(views: [transition, transitionStyle])
        transitionRow.spacing = 8
        liveMenu.target = self
        liveMenu.action = #selector(changeMenuAnimation)
        batteryThrottle.target = self
        batteryThrottle.action = #selector(changeBatteryThrottle)
        batteryThrottle.toolTip = "Automatically cap frame rate to 30 fps on battery."
        coveragePause.target = self
        coveragePause.action = #selector(changeCoveragePause)
        coveragePause.toolTip = "Pause a renderer after its display stays fully covered."
        addTab("Playback", rows: [
            [label("Frame rate"), rate],
            [label("Transition"), transitionRow],
            [NSView(), liveMenu],
            [NSView(), batteryThrottle],
            [NSView(), coveragePause],
        ])

        let saver = NSButton(title: "Screen Saver Options…", target: self, action: #selector(openSaver))
        saver.bezelStyle = .rounded
        let mirror = NSButton(title: "Mirror Active Wallpaper to Screen Saver", target: self,
                              action: #selector(mirrorWallpaperToSaver))
        mirror.bezelStyle = .rounded
        addTab("Screen Saver", rows: [[NSView(), saver], [NSView(), mirror]])
        selectPage(0)
    }

    @objc private func navigate(_ sender: NSButton) { selectPage(sender.tag) }

    private func selectPage(_ index: Int) {
        guard (0..<tabs.numberOfTabViewItems).contains(index) else { return }
        tabs.selectTabViewItem(at: index)
        for button in navigation {
            let selected = button.tag == index
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .clear).cgColor
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
    }

    private func addTab(_ title: String, rows: [[NSView]]) {
        let page = NSView()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(heading)
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 16
        grid.columnSpacing = 16
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).width = 110
            grid.column(at: 0).xPlacement = .trailing
        }
        if grid.numberOfColumns > 1 { grid.column(at: 1).xPlacement = .leading }
        grid.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(grid)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: page.topAnchor, constant: 28),
            heading.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 30),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 26),
            grid.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 26),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -26),
        ])
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = page
        tabs.addTabViewItem(item)
    }

    func updateStatus() {
        liveMenu.state = UserDefaults.standard.bool(forKey: "comfort.liveMenuStrip") ? .on : .off
    }

    private func reload() {
        updateStatus()
        rate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        transition.selectItem(at: [0.0, 0.5, 1, 2].firstIndex(of: wallpaper.transitionDuration) ?? 0)
        transitionStyle.selectItem(at: WallpaperController.TransitionStyle.allCases.firstIndex(of: wallpaper.transitionStyle) ?? 0)
        batteryThrottle.state = SceneFrameRate.throttleOnBattery ? .on : .off
        coveragePause.state = wallpaper.coveragePauseEnabled ? .on : .off
    }

    func windowDidBecomeKey(_ notification: Notification) { reload() }
    func windowDidMove(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlessePreferences")
    }
    func windowDidResize(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlessePreferences")
    }

    @objc private func changeMenuAnimation() {
        UserDefaults.standard.set(liveMenu.state == .on, forKey: "comfort.liveMenuStrip")
        if let url = wallpaper.selectedURL {
            wallpaper.select(url, automatic: true, restoringPause: wallpaper.pausedByUser)
        }
    }

    @objc private func changePlayback() {
        guard SceneFrameRate.allCases.indices.contains(rate.indexOfSelectedItem),
              WallpaperController.TransitionStyle.allCases.indices.contains(transitionStyle.indexOfSelectedItem) else { return }
        SceneFrameRate.selected = SceneFrameRate.allCases[rate.indexOfSelectedItem]
        let durations = [0.0, 0.5, 1.0, 2.0]
        if durations.indices.contains(transition.indexOfSelectedItem) {
            wallpaper.transitionDuration = durations[transition.indexOfSelectedItem]
        }
        wallpaper.transitionStyle = WallpaperController.TransitionStyle.allCases[transitionStyle.indexOfSelectedItem]
    }

    @objc private func changeBatteryThrottle() {
        SceneFrameRate.throttleOnBattery = batteryThrottle.state == .on
    }

    @objc private func changeCoveragePause() {
        wallpaper.coveragePauseEnabled = coveragePause.state == .on
    }

    /// Dimming belongs to Home/Ambient, but callers use this to keep Settings at
    /// an appropriate window level while the desktop is dimmed.
    func updateDimming() {
        window?.level = comfort.isDimmed ? .mainMenu : .normal
    }

    @objc private func mirrorWallpaperToSaver() {
        guard let url = wallpaper.selectedURL else {
            let alert = NSAlert()
            alert.messageText = "No Active Wallpaper"
            alert.informativeText = "Choose or play a wallpaper first before mirroring to the Screen Saver."
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
            return
        }
        do {
            let targetURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            try IdlessePreferences.shared.saveFolder(targetURL)
            NotificationCenter.default.post(name: IdlessePreferences.settingsChangedNotification, object: nil)
            let alert = NSAlert()
            alert.messageText = "Screen Saver Synchronized"
            alert.informativeText = "The Idlesse screen saver now mirrors “\(url.lastPathComponent)”."
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Update Screen Saver"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    @objc private func openSaver() { showSaver() }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }
}
