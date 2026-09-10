import AppKit

/// Local wall-clock schedule. Equal endpoints disable the interval rather than dimming all day.
struct DimSchedule {
    var start: Int
    var end: Int
    func contains(minute: Int) -> Bool {
        guard (0..<1440).contains(start), (0..<1440).contains(end), (0..<1440).contains(minute), start != end else { return false }
        return start < end ? minute >= start && minute < end : minute >= start || minute < end
    }

    static func pickerDate(minute: Int, on date: Date, calendar: Calendar = .current) -> Date {
        let bounded = min(1439, max(0, minute))
        return calendar.date(bySettingHour: bounded / 60, minute: bounded % 60, second: 0, of: date) ?? date
    }
}

private final class DimWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An opt-in visual shade, not a hardware brightness or display-sleep controller.
final class DesktopComfortController: NSObject, NSMenuItemValidation {
    private let iconItems = NSHashTable<NSMenuItem>.weakObjects()
    private let widgetItems = NSHashTable<NSMenuItem>.weakObjects()
    private(set) var changingDesktopWidgets = false
    private(set) var changingDesktopIcons = false
    var onDesktopIconsChanged: (() -> Void)?
    var onShowSettings: (() -> Void)?

    var desktopIconsVisible: Bool {
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        return !((CFPreferencesCopyAppValue("StandardHideDesktopIcons" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false)
    }

    var desktopWidgetsVisible: Bool {
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        return !((CFPreferencesCopyAppValue("StandardHideWidgets" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false)
    }

    @objc func toggleDesktopWidgets() {
        guard !changingDesktopWidgets else { return }
        let visible = !desktopWidgetsVisible
        changingDesktopWidgets = true
        updateDesktopIconsItems()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                let write = Process()
                write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
                write.arguments = ["write", "com.apple.WindowManager", "StandardHideWidgets", "-bool", visible ? "false" : "true"]
                try write.run(); write.waitUntilExit()
                if write.terminationStatus != 0 { failure = "Could not change desktop widget visibility." }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changingDesktopWidgets = false
                self.updateDesktopIconsItems()
                if let failure {
                    let alert = NSAlert(); alert.messageText = "Desktop Widgets"
                    alert.informativeText = failure; alert.runModal()
                }
            }
        }
    }

    func addDesktopIconsItem(to menu: NSMenu) {
        let item = menu.addItem(withTitle: "Show Desktop Files", action: #selector(toggleDesktopIcons), keyEquivalent: "")
        item.target = self
        item.toolTip = "Hide icons without moving files. Restarts Finder."
        iconItems.add(item)
        let widgets = menu.addItem(withTitle: "Show Desktop Widgets", action: #selector(toggleDesktopWidgets), keyEquivalent: "")
        widgets.target = self
        widgets.toolTip = "Show widgets on the desktop. Stage Manager has a separate macOS setting."
        widgetItems.add(widgets)
        updateDesktopIconsItems()
    }

    private func updateDesktopIconsItems() {
        let visible = desktopIconsVisible
        for item in iconItems.allObjects {
            item.state = visible ? .on : .off
            item.isEnabled = !changingDesktopIcons
        }
        for item in widgetItems.allObjects {
            item.state = desktopWidgetsVisible ? .on : .off
            item.isEnabled = !changingDesktopWidgets
        }
        onDesktopIconsChanged?()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleDesktopWidgets) {
            updateDesktopIconsItems()
            return !changingDesktopWidgets
        }
        if item.action == #selector(toggleDesktopIcons) {
            updateDesktopIconsItems()
            return !changingDesktopIcons
        }
        return true
    }

    @objc func toggleDesktopIcons() {
        guard !changingDesktopIcons else { return }
        let visible = !desktopIconsVisible
        changingDesktopIcons = true
        updateDesktopIconsItems()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                // Match Desktop & Dock > Show items > On Desktop. CreateDesktop=false
                // removes Finder's desktop surface and breaks click-to-reveal.
                for arguments in [
                    ["write", "com.apple.finder", "CreateDesktop", "-bool", "true"],
                    ["write", "com.apple.WindowManager", "StandardHideDesktopIcons", "-bool", visible ? "false" : "true"]
                ] {
                    let write = Process()
                    write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
                    write.arguments = arguments
                    try write.run(); write.waitUntilExit()
                    guard write.terminationStatus == 0 else { throw NSError(domain: "Idlesse.Desktop", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not change the desktop icon setting."]) }
                }
                if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty {
                    let restart = Process()
                    restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                    restart.arguments = ["Finder"]
                    try restart.run(); restart.waitUntilExit()
                    guard restart.terminationStatus == 0 else { throw NSError(domain: "Idlesse.Desktop", code: 2, userInfo: [NSLocalizedDescriptionKey: "The setting was saved, but Finder could not restart. Relaunch Finder to apply it."]) }
                }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changingDesktopIcons = false
                self.updateDesktopIconsItems()
                if let failure {
                    let alert = NSAlert()
                    alert.messageText = "Desktop Icons"
                    alert.informativeText = failure
                    alert.runModal()
                }
            }
        }
    }
    var onDimmingChanged: ((Bool) -> Void)?
    private let defaults = UserDefaults.standard
    private var windows: [NSWindow] = []
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var manual: Bool?
    private var previousScheduled = false
    private var inactive = false
    private(set) var isDimmed = false
    private var schedule: DimSchedule {
        DimSchedule(start: defaults.object(forKey: "comfort.start") as? Int ?? 1320,
                    end: defaults.object(forKey: "comfort.end") as? Int ?? 420)
    }
    private var amount: Double {
        let value = defaults.object(forKey: "comfort.amount") as? Double ?? 0.9
        return value.isFinite ? min(0.98, max(0.2, value)) : 0.9
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 5
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.rebuild() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.inactive = true; $0.refresh() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.inactive = false; $0.refresh() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.refresh() }
        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping (DesktopComfortController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { action(self) }
        }
        observers.append((center, token))
    }

    private func refresh() {
        updateDesktopIconsItems()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let scheduled = defaults.bool(forKey: "comfort.schedule") &&
            schedule.contains(minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        // A manual restore lasts until the next schedule boundary, not just the next timer tick.
        if scheduled != previousScheduled { manual = nil }
        previousScheduled = scheduled
        let next = !inactive && (manual ?? scheduled)
        guard next != isDimmed else { return }
        isDimmed = next
        rebuild()
        onDimmingChanged?(next)
    }

    @objc func toggle() {
        refresh()
        manual = !isDimmed
        refresh()
    }

    @objc private func setLevel(_ sender: NSMenuItem) {
        defaults.set(Double(sender.tag) / 100, forKey: "comfort.amount")
        windows.forEach { $0.alphaValue = amount }
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        guard isDimmed else { return }
        statusItem?.button?.title = " Dimmed"
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.toolTip = "Idlesse — Click to restore or adjust display dimming"
        let menu = NSMenu()
        addDesktopIconsItem(to: menu)
        menu.addItem(.separator())
        let restore = menu.addItem(withTitle: "Restore Display", action: #selector(toggle), keyEquivalent: "d")
        restore.keyEquivalentModifierMask = [.command, .option]
        restore.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "\(Int((amount * 100).rounded()))% dimming · \(windows.count) displays", action: nil, keyEquivalent: "")
        for (title, level) in [("Evening — 70%", 70), ("Dark — 90%", 90), ("Bedtime — 98%", 98)] {
            let item = menu.addItem(withTitle: title, action: #selector(setLevel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level
            item.state = abs(amount * 100 - Double(level)) < 0.5 ? .on : .off
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Bedtime Display…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        statusItem?.menu = menu
    }

    private func rebuild() {
        windows.forEach { $0.close() }
        windows.removeAll()
        if isDimmed {
            for screen in NSScreen.screens {
                let window = DimWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.backgroundColor = .black
                window.isOpaque = true
                window.alphaValue = amount
                window.hasShadow = false
                window.ignoresMouseEvents = true
                // Keep the system menu bar and its Restore action above the shade.
                window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                window.isExcludedFromWindowsMenu = true
                window.orderFrontRegardless()
                windows.append(window)
            }
            if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
            statusItem?.button?.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Restore Display")
            updateStatusMenu()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc func showSettings() { onShowSettings?() }

    var bedtimeSettings: (amount: Double, enabled: Bool, start: Int, end: Int) {
        (amount, defaults.bool(forKey: "comfort.schedule"), schedule.start, schedule.end)
    }

    func applyBedtime(amount: Double, enabled: Bool, start: Int, end: Int) {
        let changed = defaults.bool(forKey: "comfort.schedule") != enabled ||
            schedule.start != start || schedule.end != end
        defaults.set(min(0.98, max(0.2, amount)), forKey: "comfort.amount")
        defaults.set(enabled, forKey: "comfort.schedule")
        defaults.set(start, forKey: "comfort.start")
        defaults.set(end, forKey: "comfort.end")
        if changed { manual = nil }
        refresh()
        windows.forEach { $0.alphaValue = self.amount }
        updateStatusMenu()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
        windows.forEach { $0.close() }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
