import AppKit

final class AppSettingsController: NSWindowController, NSWindowDelegate {
    private let comfort: DesktopComfortController
    private let wallpaper: WallpaperController
    private let showSaver: () -> Void
    private let tabs = NSTabView()
    private let status = NSTextField(labelWithString: "")
    private let pause = NSButton(title: "Pause", target: nil, action: nil)
    private var navigation: [NSButton] = []
    var onLibraryVisible: (() -> Void)?
    var onClose: (() -> Void)?
    func installLibrary(_ view: NSView) {
        guard tabs.numberOfTabViewItems == 3 else { return }
        let item = NSTabViewItem(identifier: "Library"); item.view = view
        tabs.addTabViewItem(item)
    }
    func updateStatus() {
        status.stringValue = "Wallpaper: " + wallpaper.statusDescription
        pause.title = wallpaper.pausedByUser ? "Resume" : "Pause"
        pause.isEnabled = wallpaper.isRunning
    }
    @objc private func togglePlayback() { wallpaper.togglePause(); updateStatus() }
    @objc private func navigate(_ sender: NSButton) { selectPage(sender.tag) }
    private func selectPage(_ index: Int) {
        guard index < tabs.numberOfTabViewItems else { return }
        tabs.selectTabViewItem(at: index)
        for button in navigation { button.state = button.tag == index ? .on : .off }
        if index == 3 { onLibraryVisible?() }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }

    private let icons = NSButton(checkboxWithTitle: "Show desktop icons", target: nil, action: nil)
    private let rate = NSPopUpButton()
    private let transition = NSPopUpButton()
    private let schedule = NSButton(checkboxWithTitle: "Schedule dimming", target: nil, action: nil)
    private let amount = NSSlider(value: 90, minValue: 20, maxValue: 98, target: nil, action: nil)
    private let percent = NSTextField(labelWithString: "90%")
    private let from = NSDatePicker()
    private let until = NSDatePicker()
    private let dim = NSButton(title: "Dim Now", target: nil, action: nil)

    init(comfort: DesktopComfortController, wallpaper: WallpaperController, showSaver: @escaping () -> Void) {
        self.comfort = comfort; self.wallpaper = wallpaper; self.showSaver = showSaver
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Idlesse"
        window.minSize = NSSize(width: 1100, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        guard let root = window.contentView else { return }
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 180, height: 720))
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)
        for (row, entry) in [(3, "Wallpapers"), (0, "Playback & Desktop"), (1, "Bedtime"), (2, "Screen Saver")].enumerated() {
            let button = NSButton(title: entry.1, target: self, action: #selector(navigate(_:)))
            button.tag = entry.0; button.setButtonType(.pushOnPushOff); button.bezelStyle = .rounded
            button.frame = NSRect(x: 12, y: 660 - row * 42, width: 156, height: 32)
            button.autoresizingMask = [.minYMargin]
            sidebar.addSubview(button); navigation.append(button)
        }
        status.frame = NSRect(x: 202, y: 670, width: 750, height: 24)
        status.autoresizingMask = [.width, .minYMargin]
        status.lineBreakMode = .byTruncatingMiddle
        root.addSubview(status)
        pause.frame = NSRect(x: 1060, y: 665, width: 96, height: 32)
        pause.autoresizingMask = [.minXMargin, .minYMargin]
        pause.bezelStyle = .rounded; pause.target = self; pause.action = #selector(togglePlayback)
        root.addSubview(pause)
        tabs.tabViewType = .noTabsNoBorder
        tabs.frame = NSRect(x: 180, y: 0, width: 1000, height: 645)
        tabs.autoresizingMask = [.width, .height]
        root.addSubview(tabs)
        wallpaper.onStateChange = { [weak self] in self?.updateStatus() }
        icons.target = self; icons.action = #selector(changeIcons)
        comfort.onDesktopIconsChanged = { [weak self] in self?.updateIcons() }
        rate.addItems(withTitles: SceneFrameRate.allCases.map { $0 == .automatic ? "Auto" : $0.title })
        rate.target = self; rate.action = #selector(changePlayback)
        rate.setAccessibilityLabel("Frame rate")
        transition.addItems(withTitles: ["None", "0.5 seconds", "1 second", "2 seconds"])
        transition.target = self; transition.action = #selector(changePlayback)
        transition.setAccessibilityLabel("Crossfade")
        addTab("Wallpaper", rows: [[label("Desktop"), icons], [label("Frame rate"), rate], [label("Crossfade"), transition]])
        schedule.target = self; schedule.action = #selector(changeBedtime)
        amount.target = self; amount.action = #selector(changeBedtime); amount.isContinuous = true
        amount.setAccessibilityLabel("Dimming")
        percent.alignment = .right
        let level = NSStackView(views: [amount, percent]); level.spacing = 8
        amount.widthAnchor.constraint(equalToConstant: 170).isActive = true
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for (picker, name) in [(from, "Dim at"), (until, "Restore at")] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.hourMinute]
            picker.target = self; picker.action = #selector(changeBedtime)
            picker.setAccessibilityLabel(name)
        }
        dim.bezelStyle = .rounded; dim.target = self; dim.action = #selector(toggleDim)
        addTab("Bedtime", rows: [[label("Dimming"), level], [NSView(), schedule],
            [label("Dim at"), from], [label("Restore at"), until], [NSView(), dim]])
        let saver = NSButton(title: "Screen Saver Options…", target: self, action: #selector(openSaver))
        saver.bezelStyle = .rounded
        addTab("Screen Saver", rows: [[NSView(), saver]])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.alignment = .right
        return field
    }
    private func addTab(_ title: String, rows: [[NSView]]) {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 230))
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 16; grid.columnSpacing = 16
        grid.column(at: 0).width = 110
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: page.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -18)])
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = page
        tabs.addTabViewItem(item)
    }
    func present(tab: Int? = nil) {
        reload()
        selectPage(tab ?? 3)
        window?.level = comfort.isDimmed ? .mainMenu : .normal
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) { reload() }
    private func updateIcons() {
        icons.state = comfort.desktopIconsVisible ? .on : .off
        icons.isEnabled = !comfort.changingDesktopIcons
    }
    private func reload() {
        updateStatus()
        updateIcons()
        rate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        transition.selectItem(at: [0.0, 0.5, 1, 2].firstIndex(of: wallpaper.transitionDuration) ?? 0)
        let values = comfort.bedtimeSettings
        schedule.state = values.enabled ? .on : .off
        amount.doubleValue = values.amount * 100
        percent.stringValue = "\(Int(amount.doubleValue.rounded()))%"
        from.dateValue = DimSchedule.pickerDate(minute: values.start, on: Date())
        until.dateValue = DimSchedule.pickerDate(minute: values.end, on: Date())
        from.isEnabled = values.enabled; until.isEnabled = values.enabled
        dim.title = comfort.isDimmed ? "Restore Display" : "Dim Now"
    }
    @objc private func changeIcons() { comfort.toggleDesktopIcons(); updateIcons() }
    @objc private func changePlayback() {
        SceneFrameRate.selected = SceneFrameRate.allCases[rate.indexOfSelectedItem]
        wallpaper.transitionDuration = [0.0, 0.5, 1, 2][transition.indexOfSelectedItem]
    }
    @objc private func changeBedtime() {
        func minute(_ picker: NSDatePicker) -> Int {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        comfort.applyBedtime(amount: amount.doubleValue / 100, enabled: schedule.state == .on,
            start: minute(from), end: minute(until))
        percent.stringValue = "\(Int(amount.doubleValue.rounded()))%"
        from.isEnabled = schedule.state == .on; until.isEnabled = schedule.state == .on
        updateDimming()
    }
    func updateDimming() {
        dim.title = comfort.isDimmed ? "Restore Display" : "Dim Now"
        window?.level = comfort.isDimmed ? .mainMenu : .normal
    }
    @objc private func toggleDim() {
        comfort.toggle(); reload()
        window?.level = comfort.isDimmed ? .mainMenu : .normal
    }
    @objc private func openSaver() { showSaver() }
}
