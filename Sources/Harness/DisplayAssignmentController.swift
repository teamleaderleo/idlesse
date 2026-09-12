import AppKit

extension Notification.Name {
    static let idlesseDisplayAssignmentsChanged = Notification.Name("IdlesseDisplayAssignmentsChanged")
    static let idlesseDisplayLibraryRequested = Notification.Name("IdlesseDisplayLibraryRequested")
}

private final class DisplayMapView: NSView {
    var topology = DisplayTopology(displays: []) { didSet { needsDisplay = true } }
    var plan: ResolvedWallpaperAssignmentPlan? { didSet { needsDisplay = true } }
    var selectedID: UInt32? { didSet { needsDisplay = true; onSelection?(selectedID) } }
    var onSelection: ((UInt32?) -> Void)?
    var onDrop: ((UInt32, URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let frames = topology.normalizedFrames(in: bounds.size, padding: 22)
        for display in topology.displays {
            guard let frame = frames[display.liveID] else { continue }
            let selected = selectedID == display.liveID
            let master = topology.master(for: display)
            let mirrored = display.mirrorMasterID != nil
            let path = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = selected ? 3 : 1.5
            path.stroke()

            if mirrored {
                let inset = frame.insetBy(dx: 7, dy: 7)
                let mirrorPath = NSBezierPath(roundedRect: inset, xRadius: 7, yRadius: 7)
                NSColor.secondaryLabelColor.setStroke()
                mirrorPath.lineWidth = 1
                mirrorPath.stroke()
            }

            let assignment = plan?.assignment(for: display.liveID)
            let sourceTitle = assignment?.sourceURL.map(displayName) ?? "No Wallpaper"
            var title = display.identity.name
            if display.isMain { title += " · Main" }
            if mirrored { title += " · Mirrored" }
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (title as NSString).draw(in: CGRect(x: frame.minX + 10, y: frame.minY + 9,
                                                width: max(10, frame.width - 20), height: 17),
                                     withAttributes: titleAttrs)
            (sourceTitle as NSString).draw(in: CGRect(x: frame.minX + 10, y: frame.maxY - 26,
                                                      width: max(10, frame.width - 20), height: 15),
                                           withAttributes: detailAttrs)
            if mirrored, master.liveID != display.liveID {
                let mirrorText = "Follows \(master.identity.name)"
                (mirrorText as NSString).draw(in: CGRect(x: frame.minX + 10, y: frame.minY + 27,
                                                         width: max(10, frame.width - 20), height: 15),
                                              withAttributes: detailAttrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frames = topology.normalizedFrames(in: bounds.size, padding: 22)
        // Reverse order lets a mirrored child on the same frame remain selectable.
        selectedID = topology.displays.reversed().first(where: { frames[$0.liveID]?.contains(point) == true })?.liveID
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        destination(for: sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        destination(for: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (displayID, url) = destination(for: sender) else { return false }
        selectedID = displayID
        onDrop?(displayID, url)
        return true
    }

    private func destination(for sender: NSDraggingInfo) -> (UInt32, URL)? {
        let point = convert(sender.draggingLocation, from: nil)
        let frames = topology.normalizedFrames(in: bounds.size, padding: 22)
        guard let display = topology.displays.reversed().first(where: { frames[$0.liveID]?.contains(point) == true }),
              let item = sender.draggingPasteboard.pasteboardItems?.first,
              let value = item.string(forType: .fileURL),
              let url = URL(string: value) else { return nil }
        return (display.liveID, url)
    }

    private func displayName(_ url: URL) -> String {
        SceneLibraryController.displayTitle(url.deletingPathExtension().lastPathComponent)
    }
}

/// Visual Displays destination. It keeps #52's runtime assignment semantics and
/// replaces the duplicate Library picker with topology selection + Library/file
/// drag/drop. The view is deliberately reusable so Home (#30) can host the same
/// destination instead of maintaining a second display UI.
final class DisplayAssignmentController: NSWindowController {
    private weak var wallpaper: WallpaperController?
    private let mode = NSSegmentedControl(labels: ["Same on All", "Per Display", "Desktop Span"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let arrangement = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mapView = DisplayMapView(frame: .zero)
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let useDefault = NSButton(title: "Use Default", target: nil, action: nil)
    private let openLibrary = NSButton(title: "Open Library", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var topology = DisplayTopology(displays: [])
    private var plan: ResolvedWallpaperAssignmentPlan?
    private var selectedID: UInt32?
    private var observers: [NSObjectProtocol] = []
    private let arrangements = KnownDisplayArrangementsStore(defaults: .standard)

    init(wallpaper: WallpaperController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        self.wallpaper = wallpaper
        window.title = "Displays"
        window.minSize = NSSize(width: 700, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        installContent(in: window)
        observers.append(NotificationCenter.default.addObserver(
            forName: .idlesseDisplayAssignmentsChanged, object: wallpaper, queue: .main) { [weak self] _ in self?.rebuild() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
    }

    required init?(coder: NSCoder) { nil }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var destinationView: NSView? { window?.contentView }

    func present() {
        rebuild()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installContent(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Displays")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Arrange wallpapers on the displays macOS reports. Rectangles preserve the real relative desktop positions and proportions.")
        subtitle.textColor = .secondaryLabelColor

        mode.target = self
        mode.action = #selector(changeMode(_:))
        mode.setContentHuggingPriority(.required, for: .horizontal)
        arrangement.setAccessibilityLabel("Known display arrangement")

        let controls = NSStackView(views: [mode, NSView(frame: .zero), arrangement])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        arrangement.setContentHuggingPriority(.required, for: .horizontal)

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.heightAnchor.constraint(greaterThanOrEqualToConstant: 285).isActive = true
        mapView.onSelection = { [weak self] id in self?.select(id) }
        mapView.onDrop = { [weak self] id, url in self?.assign(url, to: id) }

        detailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        detailText.textColor = .secondaryLabelColor
        detailText.maximumNumberOfLines = 3
        useDefault.target = self
        useDefault.action = #selector(clearSelected)
        openLibrary.target = self
        openLibrary.action = #selector(showLibrary)
        let buttons = NSStackView(views: [useDefault, openLibrary])
        buttons.spacing = 8
        hint.textColor = .secondaryLabelColor
        hint.stringValue = "Drag a wallpaper from Library or Finder onto a display. Open Library browses the existing catalog; Displays never builds a second wallpaper picker."

        let detailBox = NSBox()
        detailBox.boxType = .custom
        detailBox.borderType = .lineBorder
        detailBox.cornerRadius = 10
        detailBox.contentViewMargins = NSSize(width: 14, height: 12)
        if let boxContent = detailBox.contentView {
            let detailStack = NSStackView(views: [detailTitle, detailText, buttons, hint])
            detailStack.orientation = .vertical
            detailStack.alignment = .leading
            detailStack.spacing = 8
            detailStack.translatesAutoresizingMaskIntoConstraints = false
            boxContent.addSubview(detailStack)
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 650).isActive = true
            NSLayoutConstraint.activate([
                detailStack.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor),
                detailStack.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor),
                detailStack.topAnchor.constraint(equalTo: boxContent.topAnchor),
                detailStack.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor),
            ])
        }

        let stack = NSStackView(views: [title, subtitle, controls, mapView, detailBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 720).isActive = true
        controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        mapView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detailBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
    }

    private func rebuild() {
        guard let wallpaper else { return }
        topology = .current()
        wallpaper.reconcileDurableDisplayAssignments(topology: topology)
        plan = wallpaper.resolvedDisplayAssignmentPlan(topology: topology)
        let current = arrangements.record(topology)
        reloadArrangements(current: current)
        mapView.topology = topology
        mapView.plan = plan

        switch plan?.mode {
        case .sameOnAll: mode.selectedSegment = 0
        case .perDisplay: mode.selectedSegment = 1
        case .desktopSpan: mode.selectedSegment = 2
        case nil: mode.selectedSegment = 0
        }
        let span = plan?.mode == .desktopSpan
        mode.setEnabled(!span, forSegment: 0)
        mode.setEnabled(!span, forSegment: 1)
        mode.setEnabled(span, forSegment: 2)
        if selectedID == nil || !topology.displays.contains(where: { $0.liveID == selectedID }) {
            selectedID = topology.displays.first(where: \ .isMain)?.liveID ?? topology.displays.first?.liveID
        }
        mapView.selectedID = selectedID
        refreshDetail()
    }

    private func reloadArrangements(current: DisplayArrangementProfile) {
        arrangement.removeAllItems()
        let profiles = arrangements.profiles().sorted { $0.lastSeen > $1.lastSeen }
        for profile in profiles {
            arrangement.addItem(withTitle: profile.name + (profile.id == current.id ? " · Current" : ""))
        }
        arrangement.selectItem(at: max(0, profiles.firstIndex(where: { $0.id == current.id }) ?? 0))
        arrangement.isEnabled = false
        arrangement.toolTip = "Known docked and undocked arrangements are remembered automatically."
    }

    private func select(_ id: UInt32?) {
        selectedID = id
        refreshDetail()
    }

    private func refreshDetail() {
        guard let selectedID,
              let display = topology.displays.first(where: { $0.liveID == selectedID }) else {
            detailTitle.stringValue = "No display selected"
            detailText.stringValue = ""
            useDefault.isEnabled = false
            return
        }
        let master = topology.master(for: display)
        let assignment = plan?.assignment(for: display.liveID)
        detailTitle.stringValue = display.identity.name + (display.isMain ? " · Main Display" : "")
        var details = [display.resolutionDescription, "\(Int(display.frame.width)) × \(Int(display.frame.height)) desktop points"]
        if let mirrorID = display.mirrorMasterID,
           let mirrored = topology.displays.first(where: { $0.liveID == mirrorID }) {
            details.append("Mirrors \(mirrored.identity.name)")
        }
        if let url = assignment?.sourceURL {
            let title = SceneLibraryController.displayTitle(url.deletingPathExtension().lastPathComponent)
            details.append((assignment?.explicit == true ? "Assigned: " : "Using: ") + title)
        } else {
            details.append("No wallpaper selected")
        }
        details.append("Identity: \(topology.persistentKey(for: master))")
        detailText.stringValue = details.joined(separator: " · ")
        useDefault.isEnabled = plan?.mode == .perDisplay && assignment?.explicit == true && display.mirrorMasterID == nil
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        guard let wallpaper, !wallpaper.desktopSpanActive else { rebuild(); return }
        switch sender.selectedSegment {
        case 0: wallpaper.sameWallpaperOnAllDisplays = true
        case 1: wallpaper.sameWallpaperOnAllDisplays = false
        default: break
        }
        rebuild()
    }

    private func assign(_ url: URL, to displayID: UInt32) {
        guard let wallpaper else { return }
        if wallpaper.desktopSpanActive || wallpaper.sameWallpaperOnAllDisplays {
            wallpaper.assignLibraryWallpaper(url, to: nil)
        } else {
            let display = topology.displays.first(where: { $0.liveID == displayID })
            let target = display.map { topology.master(for: $0).liveID } ?? displayID
            wallpaper.assignLibraryWallpaper(url, to: target)
        }
    }

    @objc private func clearSelected() {
        guard let wallpaper, let selectedID,
              let display = topology.displays.first(where: { $0.liveID == selectedID }) else { return }
        let master = topology.master(for: display)
        wallpaper.clearDisplayURL(for: master.liveID)
    }

    @objc private func showLibrary() {
        NotificationCenter.default.post(name: .idlesseDisplayLibraryRequested, object: self, userInfo: ["displayID": selectedID as Any])
        guard let url = URL(string: "idlesse://wallpapers") else { return }
        NSWorkspace.shared.open(url)
    }
}
