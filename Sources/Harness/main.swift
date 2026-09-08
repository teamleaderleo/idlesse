import AppKit
import ScreenSaver

final class IdlesseAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var saverView: IdlesseView!
    private var settingsButton: NSButton!

    private lazy var settingsController = ConfigureSheetController(preferences: IdlessePreferences.shared) { [weak self] in
        self?.saverView?.reloadFromPreferences()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Idlesse Development Preview"
        window.center()

        guard let contentView = window.contentView else { return }
        saverView = IdlesseView(frame: contentView.bounds, isPreview: false)
        saverView.autoresizingMask = [.width, .height]
        contentView.addSubview(saverView)

        settingsButton = NSButton(title: "Preview Settings…", target: self, action: #selector(showSettings))
        settingsButton.bezelStyle = .rounded
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            settingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])

        window.makeKeyAndOrderFront(nil)
        saverView.startAnimation()
        NSApp.activate(ignoringOtherApps: true)

        if IdlessePreferences.shared.folderDisplayPath == nil {
            DispatchQueue.main.async { [weak self] in
                self?.showSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saverView?.stopAnimation()
    }

    @objc private func showSettings() {
        settingsController.reload()
        let settingsWindow = settingsController.window

        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let settings = NSMenuItem(title: "Preview Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Idlesse Development Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared

if CommandLine.arguments.contains("--smoke-options") {
    let controller = ConfigureSheetController(preferences: IdlessePreferences.shared) {}
    controller.window.contentView?.layoutSubtreeIfNeeded()
    print("Idlesse settings UI smoke test passed")
    exit(EXIT_SUCCESS)
}

let delegate = IdlesseAppDelegate()
app.delegate = delegate
app.run()
