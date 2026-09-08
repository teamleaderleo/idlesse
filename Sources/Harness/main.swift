import AppKit
import ScreenSaver

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var saverView: IdlesseView!
    private var optionsButton: NSButton!

    private lazy var optionsController = ConfigureSheetController(preferences: IdlessePreferences.shared) { [weak self] in
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
        window.title = "Idlesse Preview"
        window.center()

        guard let contentView = window.contentView else { return }
        saverView = IdlesseView(frame: contentView.bounds, isPreview: false)
        saverView.autoresizingMask = [.width, .height]
        contentView.addSubview(saverView)

        optionsButton = NSButton(title: "Options…", target: self, action: #selector(showOptions))
        optionsButton.bezelStyle = .rounded
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(optionsButton)

        NSLayoutConstraint.activate([
            optionsButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            optionsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])

        window.makeKeyAndOrderFront(nil)
        saverView.startAnimation()
        NSApp.activate(ignoringOtherApps: true)

        // On first launch, skip the menu entirely and put configuration in front of the user.
        if IdlessePreferences.shared.folderDisplayPath == nil {
            DispatchQueue.main.async { [weak self] in
                self?.showOptions()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saverView?.stopAnimation()
    }

    @objc private func showOptions() {
        optionsController.reload()
        let optionsWindow = optionsController.window

        optionsWindow.center()
        optionsWindow.makeKeyAndOrderFront(nil)
        optionsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let options = NSMenuItem(title: "Options…", action: #selector(showOptions), keyEquivalent: ",")
        options.target = self
        appMenu.addItem(options)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Idlesse Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared

if CommandLine.arguments.contains("--smoke-options") {
    // Instantiate and lay out the options UI without entering the app event loop.
    // This catches Auto Layout exceptions that compilation alone cannot detect.
    let controller = ConfigureSheetController(preferences: IdlessePreferences.shared) {}
    controller.window.contentView?.layoutSubtreeIfNeeded()
    print("Idlesse options UI smoke test passed")
    exit(EXIT_SUCCESS)
}

let delegate = PreviewAppDelegate()
app.delegate = delegate
app.run()
