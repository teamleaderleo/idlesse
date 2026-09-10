import AppKit
import FinderSync
import Darwin

/// Adds Idlesse actions only to the Desktop folder's contextual menus.
final class FinderSync: FIFinderSync {
    private let desktop = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir)).appendingPathComponent("Desktop")

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [desktop]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems,
              let target = FIFinderSyncController.default().targetedURL(),
              target.resolvingSymlinksInPath().standardizedFileURL == desktop.resolvingSymlinksInPath().standardizedFileURL else { return nil }
        let menu = NSMenu()
        for (title, action) in [("Customize Idlesse Wallpaper…", #selector(customize)),
                                ("Show / Hide Desktop Icons", #selector(toggleIcons))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    @objc private func customize() { open("wallpapers") }
    @objc private func toggleIcons() { open("desktop-icons") }
    private func open(_ action: String) {
        guard let url = URL(string: "idlesse://\(action)") else { return }
        NSWorkspace.shared.open(url)
    }
}
