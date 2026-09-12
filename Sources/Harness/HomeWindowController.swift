import AppKit
import ImageIO

/// Primary Idlesse window. Library keeps ownership of its original NSWindow;
/// Home wraps Library content inside that same window and never reparents it
/// into Settings.
final class HomeWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private enum SidebarRow: Equatable {
        case group(String)
        case library
        case displays
        case favorites
        case recent
        case collection(id: String, name: String)

        var title: String {
            switch self {
            case .group(let title): return title
            case .library: return "Library"
            case .displays: return "Displays"
            case .favorites: return "Favorites"
            case .recent: return "Recent"
            case .collection(_, let name): return name
            }
        }
        var symbol: String? {
            switch self {
            case .group: return nil
            case .library: return "photo.on.rectangle.angled"
            case .displays: return "display.2"
            case .favorites: return "star.fill"
            case .recent: return "clock"
            case .collection: return "rectangle.stack"
            }
        }
        var selectable: Bool {
            if case .group = self { return false }
            return true
        }
    }

    private let library: SceneLibraryController
    private let wallpaper: WallpaperController
    private let comfort: DesktopComfortController
    private let indexURL: URL
    private let libraryView: NSView
    private let sidebar = NSTableView()
    private let contentHost = NSView(frame: .zero)
    private let displaysView = NSView(frame: .zero)
    private let displaySummary = NSTextField(wrappingLabelWithString: "")
    private let filesButton = NSButton(checkboxWithTitle: "Files", target: nil, action: nil)
    private let widgetsButton = NSButton(checkboxWithTitle: "Widgets", target: nil, action: nil)
    private let sameDisplaysButton = NSButton(checkboxWithTitle: "Same wallpaper on all displays", target: nil, action: nil)
    private var rows: [SidebarRow] = []
    private var currentRow: SidebarRow = .library
    private var previousSortBeforeRecent: Int?
    private var refreshTimer: Timer?

    private let nowPlayingButton = NSButton(title: "No Wallpaper", target: nil, action: nil)
    private let destinationLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(frame: .zero)
    private let pauseButton = NSButton(frame: .zero)
    private let nextButton = NSButton(frame: .zero)
    private var nowPlayingPopover: NSPopover?

    var window: NSWindow { library.window! }

    init(library: SceneLibraryController, wallpaper: WallpaperController, comfort: DesktopComfortController,
         indexURL: URL? = nil) {
        self.library = library
        self.wallpaper = wallpaper
        self.comfort = comfort
        self.libraryView = library.window!.contentView!
        if let indexURL {
            self.indexURL = indexURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.indexURL = support.appendingPathComponent("Idlesse/Library/index.json")
        }
        super.init()
        installShell()
        installToolbar()
        buildDisplaysView()
        refreshSidebar()
        refreshState()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshState() }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        NotificationCenter.default.addObserver(self, selector: #selector(desktopVisibilityChanged),
            name: DesktopComfortController.desktopVisibilityChanged, object: nil)
    }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func presentLibrary() {
        refreshSidebar()
        showLibraryScope(.library)
        presentWindow()
    }

    func presentDisplays() {
        refreshSidebar()
        showDisplays()
        presentWindow()
    }

    private func presentWindow() {
        library.show()
        window.title = "Idlesse"
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Shell

    private func installShell() {
        libraryView.removeFromSuperview()

        let sidebarScroll = NSScrollView(frame: .zero)
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = sidebar
        sidebar.style = .sourceList
        sidebar.headerView = nil
        sidebar.rowHeight = 28
        sidebar.allowsEmptySelection = false
        sidebar.delegate = self
        sidebar.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HomeSource"))
        column.resizingMask = .autoresizingMask
        sidebar.addTableColumn(column)
        sidebar.setAccessibilityLabel("Idlesse destinations")

        let sidebarController = NSViewController()
        sidebarController.view = sidebarScroll
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false

        let contentController = NSViewController()
        contentController.view = contentHost
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 700

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.dividerStyle = .thin
        window.contentViewController = split
        window.minSize = NSSize(width: 960, height: 560)
        window.setContentSize(NSSize(width: 1120, height: 680))

        libraryView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(libraryView)
        NSLayoutConstraint.activate([
            libraryView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            libraryView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            libraryView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            libraryView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    private func refreshSidebar() {
        var next: [SidebarRow] = [
            .group("Idlesse"), .library, .displays,
            .group("Library"), .favorites, .recent,
        ]
        if let store = try? SceneLibraryStore(file: indexURL) {
            next.append(contentsOf: store.catalog.collections.map { .collection(id: $0.id, name: $0.name) })
        }
        rows = next
        sidebar.reloadData()
        if let index = rows.firstIndex(of: currentRow), rows[index].selectable {
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let index = rows.firstIndex(of: .library) {
            currentRow = .library
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].selectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let text = NSTextField(labelWithString: entry.title)
        text.lineBreakMode = .byTruncatingTail
        if case .group = entry {
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .secondaryLabelColor
            return text
        }
        let cell = NSTableCellView(frame: .zero)
        let image = NSImageView(frame: .zero)
        image.image = entry.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: entry.title) }
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.textField = text
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = sidebar.selectedRow
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .library, .favorites, .recent, .collection(_, _): showLibraryScope(rows[index])
        case .displays: showDisplays()
        case .group: break
        }
    }

    private func showLibraryScope(_ row: SidebarRow) {
        currentRow = row
        libraryView.isHidden = false
        displaysView.isHidden = true
        if previousSortBeforeRecent != nil, row != .recent {
            if let sort = sortPopup(), let old = previousSortBeforeRecent, sort.numberOfItems > old {
                sort.selectItem(at: old)
                sendAction(of: sort)
            }
            previousSortBeforeRecent = nil
        }
        switch row {
        case .library:
            selectFilter(title: "All Wallpapers")
        case .favorites:
            selectFilter(title: "Favorites")
        case .recent:
            selectFilter(title: "All Wallpapers")
            if let sort = sortPopup() {
                if previousSortBeforeRecent == nil { previousSortBeforeRecent = sort.indexOfSelectedItem }
                sort.selectItem(withTitle: "Recently Opened")
                sendAction(of: sort)
            }
        case .collection(let id, _):
            selectFilter(collectionID: id)
        default:
            break
        }
        library.refreshEmbedded()
    }

    private func showDisplays() {
        currentRow = .displays
        libraryView.isHidden = true
        displaysView.isHidden = false
        refreshDisplaysSummary()
    }

    /// Drive the Library's existing filter/sort controls so there is one source
    /// of truth for Sources, collections, search, selection and scheduling.
    private func selectFilter(title: String) {
        guard let popup = filterPopup(), popup.itemTitles.contains(title) else { return }
        popup.selectItem(withTitle: title)
        sendAction(of: popup)
    }

    private func selectFilter(collectionID: String) {
        guard let popup = filterPopup(),
              let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == collectionID }) else { return }
        popup.selectItem(at: index)
        sendAction(of: popup)
    }

    private func sendAction(of popup: NSPopUpButton) {
        guard let action = popup.action else { return }
        NSApp.sendAction(action, to: popup.target, from: popup)
    }

    private func filterPopup() -> NSPopUpButton? {
        popups(in: libraryView).first { $0.itemTitles.contains("All Wallpapers") && $0.itemTitles.contains("Favorites") }
    }

    private func sortPopup() -> NSPopUpButton? {
        popups(in: libraryView).first { $0.itemTitles.contains("Recently Opened") && $0.itemTitles.contains("Name") }
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        var result: [NSPopUpButton] = []
        if let popup = view as? NSPopUpButton { result.append(popup) }
        for child in view.subviews { result.append(contentsOf: popups(in: child)) }
        return result
    }

    private func rotationSummary() -> String? {
        for popup in popups(in: libraryView) {
            guard let first = popup.itemTitles.first, first.hasPrefix("Collections · Rotating") else { continue }
            return first.replacingOccurrences(of: "Collections · ", with: "")
        }
        return nil
    }

    // MARK: - Displays migration surface

    private func buildDisplaysView() {
        displaysView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(displaysView)
        NSLayoutConstraint.activate([
            displaysView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            displaysView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            displaysView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            displaysView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        displaysView.isHidden = true

        let title = NSTextField(labelWithString: "Displays")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString:
            "Choose how Idlesse treats the desktop. Display layout and per-display Library assignment live here.")
        intro.textColor = .secondaryLabelColor
        displaySummary.textColor = .secondaryLabelColor

        sameDisplaysButton.target = self
        sameDisplaysButton.action = #selector(changeSameDisplays)
        filesButton.target = self
        filesButton.action = #selector(toggleFiles)
        widgetsButton.target = self
        widgetsButton.action = #selector(toggleWidgets)

        let desktopTitle = NSTextField(labelWithString: "Desktop")
        desktopTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let desktopControls = NSStackView(views: [filesButton, widgetsButton])
        desktopControls.spacing = 18
        let stack = NSStackView(views: [title, intro, sameDisplaysButton, displaySummary, desktopTitle, desktopControls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        displaysView.addSubview(stack)
        intro.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true
        displaySummary.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: displaysView.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: displaysView.trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: displaysView.topAnchor, constant: 32),
        ])
    }

    @objc private func changeSameDisplays() {
        wallpaper.sameWallpaperOnAllDisplays = sameDisplaysButton.state == .on
        refreshState()
    }
    @objc private func toggleFiles() { comfort.toggleDesktopIcons(); refreshState() }
    @objc private func toggleWidgets() { comfort.toggleDesktopWidgets(); refreshState() }
    @objc private func desktopVisibilityChanged() { refreshState() }

    private func refreshDisplaysSummary() {
        let count = NSScreen.screens.count
        let mode = wallpaper.sameWallpaperOnAllDisplays ? "Same on All Displays" : "Per Display"
        displaySummary.stringValue = "\(count) connected display\(count == 1 ? "" : "s") · \(mode)"
        sameDisplaysButton.state = wallpaper.sameWallpaperOnAllDisplays ? .on : .off
        filesButton.state = comfort.desktopIconsVisible ? .on : .off
        widgetsButton.state = comfort.desktopWidgetsVisible ? .on : .off
        filesButton.isEnabled = !comfort.changingDesktopIcons
        widgetsButton.isEnabled = !comfort.changingDesktopWidgets
    }

    // MARK: - Now Playing

    private static let nowPlayingItem = NSToolbarItem.Identifier("Idlesse.Home.NowPlaying")

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("Idlesse.Home.Toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.nowPlayingItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.nowPlayingItem, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.nowPlayingItem else { return nil }
        configureTransport(previousButton, symbol: "backward.fill", label: "Previous wallpaper", action: #selector(previousWallpaper))
        configureTransport(pauseButton, symbol: "pause.fill", label: "Pause wallpaper", action: #selector(togglePause))
        configureTransport(nextButton, symbol: "forward.fill", label: "Next wallpaper", action: #selector(nextWallpaper))
        nowPlayingButton.isBordered = false
        nowPlayingButton.target = self
        nowPlayingButton.action = #selector(showNowPlaying)
        nowPlayingButton.imagePosition = .imageLeading
        nowPlayingButton.alignment = .left
        nowPlayingButton.toolTip = "Now Playing"
        destinationLabel.font = .systemFont(ofSize: 11)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [nowPlayingButton, destinationLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        labels.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let controls = NSStackView(views: [previousButton, pauseButton, nextButton, labels])
        controls.spacing = 7
        controls.alignment = .centerY
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = controls
        item.label = "Now Playing"
        item.paletteLabel = "Now Playing"
        return item
    }

    private func configureTransport(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
    }

    @objc private func previousWallpaper() { library.cycle(delta: -1); refreshState() }
    @objc private func nextWallpaper() { library.cycle(delta: 1); refreshState() }
    @objc private func togglePause() { wallpaper.togglePause(); refreshState() }

    @objc private func showNowPlaying() {
        let popover = NSPopover()
        let controller = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 128))
        let title = NSTextField(labelWithString: nowPlayingButton.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let destination = NSTextField(labelWithString: destinationLabel.stringValue)
        destination.textColor = .secondaryLabelColor
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopWallpaper))
        stop.bezelStyle = .rounded
        stop.isEnabled = wallpaper.selectedURL != nil
        let stack = NSStackView(views: [title, destination, stop])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        controller.view = container
        popover.contentViewController = controller
        popover.behavior = .transient
        nowPlayingPopover = popover
        popover.show(relativeTo: nowPlayingButton.bounds, of: nowPlayingButton, preferredEdge: .maxY)
    }

    @objc private func stopWallpaper() {
        wallpaper.stop()
        nowPlayingPopover?.close()
        refreshState()
    }

    private func refreshState() {
        let url = wallpaper.selectedURL
        let title = url.map { SceneLibraryController.displayTitle($0.deletingPathExtension().lastPathComponent) } ?? "No Wallpaper"
        nowPlayingButton.title = title
        nowPlayingButton.image = thumbnail(for: url) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: title)
        pauseButton.image = NSImage(systemSymbolName: wallpaper.pausedByUser ? "play.fill" : "pause.fill",
            accessibilityDescription: wallpaper.pausedByUser ? "Resume wallpaper" : "Pause wallpaper")
        pauseButton.isEnabled = url != nil
        previousButton.isEnabled = url != nil
        nextButton.isEnabled = true
        let count = NSScreen.screens.count
        var parts = [wallpaper.sameWallpaperOnAllDisplays ? "All Displays" : "\(count) display\(count == 1 ? "" : "s") · Per Display"]
        if let rotation = rotationSummary() { parts.append(rotation) }
        destinationLabel.stringValue = parts.joined(separator: " · ")
        refreshDisplaysSummary()
    }

    private func thumbnail(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let ext = url.pathExtension.lowercased()
        let candidate: URL
        if ext == "idlesse" {
            let jpg = url.appendingPathComponent("preview.jpg")
            let png = url.appendingPathComponent("preview.png")
            candidate = FileManager.default.fileExists(atPath: jpg.path) ? jpg : png
        } else if ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"].contains(ext) {
            candidate = url
        } else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(candidate as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 36,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 36, height: 24))
    }

    static func smokeTest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-home-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = folder.appendingPathComponent("index.json")
        let library = try SceneLibraryController(indexURL: index, onUse: { _ in }, onEdit: { _, _ in })
        let wallpaper = WallpaperController()
        wallpaper.presentsWindows = false
        let comfort = DesktopComfortController()
        let home = HomeWindowController(library: library, wallpaper: wallpaper, comfort: comfort, indexURL: index)
        precondition(home.window.contentViewController is NSSplitViewController)
        precondition(home.rows.contains(.library) && home.rows.contains(.displays))
        precondition(home.rows.contains(.favorites) && home.rows.contains(.recent))
        precondition(home.window.toolbar != nil)
        home.showLibraryScope(.favorites)
        precondition(home.currentRow == .favorites && !home.libraryView.isHidden)
        home.showDisplays()
        precondition(home.currentRow == .displays && !home.displaysView.isHidden && home.libraryView.isHidden)
        home.showLibraryScope(.library)
        precondition(home.currentRow == .library && !home.libraryView.isHidden)
    }
}
