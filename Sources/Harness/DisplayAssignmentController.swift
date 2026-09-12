import AppKit

extension Notification.Name {
    static let idlesseDisplayAssignmentsChanged = Notification.Name("IdlesseDisplayAssignmentsChanged")
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
            let mirrored = display.mirrorMasterID != nil
            let master = topology.master(for: display)
            let path = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = selected ? 3 : 1.5
            path.stroke()

            if mirrored {
                let inset = NSBezierPath(roundedRect: frame.insetBy(dx: 7, dy: 7), xRadius: 7, yRadius: 7)
                NSColor.secondaryLabelColor.setStroke()
                inset.lineWidth = 1
                inset.stroke()
            }

            let assignment = plan?.assignment(for: display.liveID)
            var title = display.identity.name
            if display.isMain { title += " · Main" }
            if mirrored { title += " · Mirrored" }
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (title as NSString).draw(
                in: NSRect(x: frame.minX + 10, y: frame.minY + 9,
                           width: max(10, frame.width - 20), height: 17),
                withAttributes: titleAttributes)
            if mirrored, master.liveID != display.liveID {
                ("Follows \(master.identity.name)" as NSString).draw(
                    in: NSRect(x: frame.minX + 10, y: frame.minY + 27,
                               width: max(10, frame.width - 20), height: 15),
                    withAttributes: detailAttributes)
            }
            let source = assignment?.sourceURL.map(displayName) ?? "No Wallpaper"
            (source as NSString).draw(
                in: NSRect(x: frame.minX + 10, y: frame.maxY - 26,
                           width: max(10, frame.width - 20), height: 15),
                withAttributes: detailAttributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frames = topology.normalizedFrames(in: bounds.size, padding: 22)
        selectedID = topology.displays.reversed().first {
            frames[$0.liveID]?.contains(point) == true
        }?.liveID
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
        guard let display = topology.displays.reversed().first(where: {
                  frames[$0.liveID]?.contains(point) == true
              }),
              let item = sender.draggingPasteboard.pasteboardItems?.first,
              let value = item.string(forType: .fileURL),
              let url = URL(string: value) else { return nil }
        return (display.liveID, url)
    }

    private func displayName(_ url: URL) -> String {
        SceneLibraryController.displayTitle(url.deletingPathExtension().lastPathComponent)
    }
}

/// Reusable visual Displays destination. Home embeds this exact controller; the
/// standalone wrapper below remains only for compatibility with old commands.
final class DisplayAssignmentViewController: NSViewController {
    private struct PendingLibraryTarget {
        let liveID: UInt32
        let previousDefault: URL?
        let expires: Date
    }

    private weak var wallpaper: WallpaperController?
    var onArrangementChange: (() -> Void)?
    private let mode = NSSegmentedControl(
        labels: ["Same on All", "Per Display", "Desktop Span"],
        trackingMode: .selectOne, target: nil, action: nil)
    private let arrangement = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rememberArrangement = NSButton(title: "Remember Setup", target: nil, action: nil)
    private let mapView = DisplayMapView(frame: .zero)
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let useDefault = NSButton(title: "Use Default", target: nil, action: nil)
    private let openLibrary = NSButton(title: "Choose in Library…", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var topology = DisplayTopology(displays: [])
    private var plan: ResolvedWallpaperAssignmentPlan?
    private var selectedID: UInt32?
    private var pendingLibraryTarget: PendingLibraryTarget?
    private var reconcilingLibraryTarget = false
    private var topologyRefreshWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private let arrangements = KnownDisplayArrangementsStore(defaults: .standard)

    init(wallpaper: WallpaperController) {
        self.wallpaper = wallpaper
        super.init(nibName: nil, bundle: nil)
        observers.append(NotificationCenter.default.addObserver(
            forName: .idlesseDisplayAssignmentsChanged, object: wallpaper, queue: .main) { [weak self] _ in
                self?.assignmentDidChange()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.pendingLibraryTarget = nil
                self?.scheduleTopologyRefresh()
            })
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        topologyRefreshWorkItem?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 650))
        view = root
        installContent(in: root)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
    }

    func activate() {
        pendingLibraryTarget = nil
        _ = view
        rebuild()
    }

    private func installContent(in content: NSView) {
        let title = NSTextField(labelWithString: "Displays")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Rectangles follow the real desktop positions and proportions reported by macOS, including offsets, gaps, mixed resolutions and mirroring.")
        subtitle.textColor = .secondaryLabelColor

        mode.target = self
        mode.action = #selector(changeMode(_:))
        mode.setContentHuggingPriority(.required, for: .horizontal)
        arrangement.setAccessibilityLabel("Known display arrangement")
        arrangement.setContentHuggingPriority(.required, for: .horizontal)
        arrangement.isEnabled = false
        rememberArrangement.target = self
        rememberArrangement.action = #selector(rememberCurrentArrangement)
        rememberArrangement.bezelStyle = .rounded
        rememberArrangement.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView(frame: .zero)
        let controls = NSStackView(views: [mode, spacer, arrangement, rememberArrangement])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        hint.stringValue = "Drop a wallpaper file onto a display, or choose a target and use Choose in Library. The existing Library remains the only catalog picker."

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

    private func scheduleTopologyRefresh() {
        topologyRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.topologyRefreshWorkItem = nil
            guard self?.isViewLoaded == true else { return }
            self?.rebuild()
        }
        topologyRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rebuild() {
        guard isViewLoaded, let wallpaper else { return }
        topology = .current()
        wallpaper.reconcileDurableDisplayAssignments(topology: topology)
        plan = wallpaper.resolvedDisplayAssignmentPlan(topology: topology)
        let current = arrangements.touchKnown(topology)
        reloadArrangements(current: current)
        mapView.topology = topology
        mapView.plan = plan

        switch plan?.mode {
        case .sameOnAll: mode.selectedSegment = 0
        case .perDisplay: mode.selectedSegment = 1
        case .desktopSpan: mode.selectedSegment = 2
        case nil: mode.selectedSegment = 0
        }
        mode.isEnabled = plan?.mode != .desktopSpan
        if selectedID == nil || !topology.displays.contains(where: { $0.liveID == selectedID }) {
            selectedID = topology.displays.first(where: { $0.isMain })?.liveID
                ?? topology.displays.first?.liveID
        }
        mapView.selectedID = selectedID
        refreshDetail()
    }

    private func reloadArrangements(current: DisplayArrangementProfile?) {
        arrangement.removeAllItems()
        let profiles = arrangements.profiles().sorted { $0.lastSeen > $1.lastSeen }
        guard let current else {
            arrangement.addItem(withTitle: "Unremembered Setup")
            arrangement.selectItem(at: 0)
            arrangement.toolTip = arrangements.bestMatch(for: topology).map {
                "Closest remembered setup: \($0.name). Save only after this dock/display arrangement has settled."
            } ?? "This settled display arrangement has not been saved."
            rememberArrangement.isEnabled = !topology.displays.isEmpty
            return
        }
        for profile in profiles {
            arrangement.addItem(withTitle: profile.name + (profile.id == current.id ? " · Current" : ""))
        }
        arrangement.selectItem(at: max(0, profiles.firstIndex(where: { $0.id == current.id }) ?? 0))
        arrangement.toolTip = "Known docked and undocked arrangements are retained with bounded LRU history."
        rememberArrangement.isEnabled = false
    }

    @objc private func rememberCurrentArrangement() {
        guard !topology.displays.isEmpty else { return }
        let profile = arrangements.saveCurrent(topology)
        reloadArrangements(current: profile)
    }

    private func select(_ id: UInt32?) {
        selectedID = id
        pendingLibraryTarget = nil
        refreshDetail()
    }

    private func refreshDetail() {
        guard let selectedID,
              let display = topology.displays.first(where: { $0.liveID == selectedID }) else {
            detailTitle.stringValue = "No display selected"
            detailText.stringValue = ""
            useDefault.isEnabled = false
            openLibrary.isEnabled = false
            return
        }
        let master = topology.master(for: display)
        let assignment = plan?.assignment(for: display.liveID)
        detailTitle.stringValue = display.identity.name + (display.isMain ? " · Main Display" : "")
        var details = [
            display.resolutionDescription,
            "\(Int(display.frame.width)) × \(Int(display.frame.height)) desktop points",
        ]
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
        useDefault.isEnabled = plan?.mode == .perDisplay
            && assignment?.explicit == true
            && display.mirrorMasterID == nil
        openLibrary.isEnabled = true
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        guard let wallpaper, !wallpaper.desktopSpanActive else { rebuild(); return }
        pendingLibraryTarget = nil
        switch sender.selectedSegment {
        case 0: wallpaper.sameWallpaperOnAllDisplays = true
        case 1: wallpaper.sameWallpaperOnAllDisplays = false
        default: break
        }
        rebuild()
        onArrangementChange?()
    }

    private func assign(_ url: URL, to displayID: UInt32) {
        guard let wallpaper else { return }
        pendingLibraryTarget = nil
        if wallpaper.desktopSpanActive || wallpaper.sameWallpaperOnAllDisplays {
            wallpaper.assignLibraryWallpaper(url, to: nil)
            onArrangementChange?()
            return
        }
        let display = topology.displays.first(where: { $0.liveID == displayID })
        let target = display.map { topology.master(for: $0).liveID } ?? displayID
        wallpaper.assignLibraryWallpaper(url, to: target)
        onArrangementChange?()
    }

    @objc private func clearSelected() {
        guard let wallpaper, let selectedID,
              let display = topology.displays.first(where: { $0.liveID == selectedID }) else { return }
        pendingLibraryTarget = nil
        wallpaper.clearDisplayURL(for: topology.master(for: display).liveID)
        onArrangementChange?()
    }

    @objc private func showLibrary() {
        guard let wallpaper, let selectedID,
              let display = topology.displays.first(where: { $0.liveID == selectedID }) else { return }
        let master = topology.master(for: display)
        if plan?.mode == .perDisplay {
            pendingLibraryTarget = PendingLibraryTarget(
                liveID: master.liveID,
                previousDefault: wallpaper.selectedURL,
                expires: Date().addingTimeInterval(120))
            hint.stringValue = "Choose a wallpaper in Library within two minutes. Set Wallpaper assigns it to \(master.identity.name) and preserves the current default on the other displays."
        } else {
            pendingLibraryTarget = nil
        }
        if let url = URL(string: "idlesse://wallpapers") { NSWorkspace.shared.open(url) }
    }

    private func assignmentDidChange() {
        guard isViewLoaded, !reconcilingLibraryTarget else { return }
        guard let pending = pendingLibraryTarget else { rebuild(); return }
        guard pending.expires > Date() else {
            pendingLibraryTarget = nil
            rebuild()
            return
        }
        guard let wallpaper, let chosen = wallpaper.selectedURL else { rebuild(); return }
        if wallpaper.desktopSpanActive {
            pendingLibraryTarget = nil
            rebuild()
            return
        }

        pendingLibraryTarget = nil
        reconcilingLibraryTarget = true
        wallpaper.setDisplayURL(chosen, for: pending.liveID)
        if let previous = pending.previousDefault,
           previous.standardizedFileURL != chosen.standardizedFileURL {
            wallpaper.select(previous, automatic: true)
        }
        reconcilingLibraryTarget = false
        rebuild()
        onArrangementChange?()
    }
}

/// Standalone compatibility shell used by the existing #52 menu/command path.
/// After Home bootstrap its old command forwards to Home's single Displays
/// destination; the window remains only as a pre-bootstrap fallback.
final class DisplayAssignmentController: NSWindowController {
    static var homePresenter: (() -> Void)?
    let destinationController: DisplayAssignmentViewController

    init(wallpaper: WallpaperController) {
        destinationController = DisplayAssignmentViewController(wallpaper: wallpaper)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Displays"
        window.minSize = NSSize(width: 700, height: 560)
        window.isReleasedWhenClosed = false
        window.contentViewController = destinationController
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if let homePresenter = Self.homePresenter {
            homePresenter()
            return
        }
        destinationController.activate()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
