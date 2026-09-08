import AppKit
import ScreenSaver

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var saverView: IdlesseView!

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

        window.makeKeyAndOrderFront(nil)
        saverView.startAnimation()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        saverView?.stopAnimation()
    }

    @objc private func showOptions() {
        guard let sheet = saverView?.configureSheet, sheet.sheetParent == nil else { return }
        window.beginSheet(sheet)
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
let delegate = PreviewAppDelegate()
app.delegate = delegate
app.run()
