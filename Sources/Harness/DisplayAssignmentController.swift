import AppKit

extension Notification.Name {
    static let idlesseDisplayAssignmentsChanged = Notification.Name("IdlesseDisplayAssignmentsChanged")
}

/// Small native editor for mapping existing Library items to connected displays.
/// It intentionally reuses SceneLibraryStore instead of growing a second import
/// path: anything shown here is already part of the user's Library.
final class DisplayAssignmentController: NSWindowController {
    private weak var wallpaper: WallpaperController?
    private let stack = NSStackView()
    private var store: SceneLibraryStore?
    private var choices: [LibraryChoice] = []
    private var observers: [NSObjectProtocol] = []

    private struct LibraryChoice {
        let title: String
        let builtinURL: URL?
        let entryID: String?
    }

    private final class AssignmentToken: NSObject {
        enum Action { case library(Int), followShared }
        let displayID: UInt32?
        let action: Action
        init(displayID: UInt32?, action: Action) {
            self.displayID = displayID
            self.action = action
        }
    }

    init(wallpaper: WallpaperController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        self.wallpaper = wallpaper
        window.title = "Display Wallpapers"
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        installContent(in: window)
        observers.append(NotificationCenter.default.addObserver(
            forName: .idlesseDisplayAssignmentsChanged, object: wallpaper, queue: .main) { [weak self] _ in
                self?.rebuild()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rebuild()
            })
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func present() {
        rebuild()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installContent(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
    }

    private func rebuild() {
        guard let wallpaper else { return }
        stack.arrangedSubviews.forEach { view in stack.removeArrangedSubview(view); view.removeFromSuperview() }
        reloadChoices()

        let title = label("Display Wallpapers", size: 21, weight: .semibold)
        stack.addArrangedSubview(title)
        let detail: String
        if wallpaper.desktopSpanActive {
            detail = "Desktop Span uses every connected display as one continuous canvas. Saved individual assignments stay preserved and return when an ordinary scene is selected."
        } else if wallpaper.sameWallpaperOnAllDisplays {
            detail = "All connected displays use one Library wallpaper. Compatible video scenes share one playback engine across displays."
        } else {
            detail = "Assign a Library wallpaper to each connected display. Saved assignments follow the physical display across disconnect and reconnect."
        }
        stack.addArrangedSubview(wrappingLabel(detail, secondary: true))

        let same = NSButton(checkboxWithTitle: "Same wallpaper on all displays", target: self,
                            action: #selector(toggleSame(_:)))
        same.state = (wallpaper.desktopSpanActive || wallpaper.sameWallpaperOnAllDisplays) ? .on : .off
        same.isEnabled = !wallpaper.desktopSpanActive
        same.toolTip = wallpaper.desktopSpanActive
            ? "Desktop Span temporarily uses all displays while preserving your individual assignments."
            : "Use one scene on every connected display. Turn this off to choose wallpapers per display."
        stack.addArrangedSubview(same)
        if !wallpaper.desktopSpanActive {
            stack.addArrangedSubview(wrappingLabel(
                wallpaper.sameWallpaperOnAllDisplays
                    ? "Turn this off to choose a different Library wallpaper for each display."
                    : "Each display can follow the default wallpaper or use its own Library wallpaper.",
                secondary: true))
        }

        let shared = row(title: wallpaper.sameWallpaperOnAllDisplays ? "Shared wallpaper" : "Default wallpaper",
                         subtitle: wallpaper.selectedURL.map(displayName) ?? "No wallpaper selected",
                         popup: makePopup(displayID: nil,
                                          current: wallpaper.selectedURL.map(displayName) ?? "Choose from Library…",
                                          includeFollowShared: false,
                                          enabled: true))
        stack.addArrangedSubview(shared)

        let showIndividualDisplays = !wallpaper.desktopSpanActive && !wallpaper.sameWallpaperOnAllDisplays
        if showIndividualDisplays {
            let heading = label("Connected Displays", size: 13, weight: .semibold)
            stack.addArrangedSubview(heading)
            for screen in NSScreen.screens {
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
                let explicit = wallpaper.explicitDisplayURL(for: displayID)
                let effective = explicit ?? wallpaper.selectedURL
                var subtitle = displayDescription(screen, displayID: displayID)
                subtitle += "\n" + (effective.map { "Using “\(displayName($0))”" } ?? "No wallpaper selected")
                let popup = makePopup(displayID: displayID,
                                      current: explicit.map(displayName) ?? "Follow default wallpaper",
                                      includeFollowShared: true,
                                      enabled: true)
                stack.addArrangedSubview(row(title: screen.localizedName, subtitle: subtitle, popup: popup))
            }
        }

        if choices.isEmpty {
            stack.addArrangedSubview(wrappingLabel(
                "The Library has no available wallpapers yet. Add one in Library, then reopen this window.", secondary: true))
        }
    }

    private func reloadChoices() {
        var result = SceneLibraryController.builtinScenes().map {
            LibraryChoice(title: $0.title, builtinURL: $0.url, entryID: nil)
        }
        store = nil
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let loaded = try SceneLibraryStore(file: support.appendingPathComponent("Idlesse/Library/index.json"))
            store = loaded
            result.append(contentsOf: loaded.catalog.entries.map {
                LibraryChoice(title: $0.title, builtinURL: nil, entryID: $0.id)
            })
        } catch {
            NSLog("Idlesse-display library catalog unavailable: %@", error.localizedDescription)
        }
        var seen = Set<String>()
        choices = result.filter { seen.insert($0.title + "|" + ($0.entryID ?? $0.builtinURL?.path ?? "")).inserted }
    }

    private func makePopup(displayID: UInt32?, current: String,
                           includeFollowShared: Bool, enabled: Bool) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.addItem(withTitle: current)
        popup.item(at: 0)?.representedObject = nil
        if includeFollowShared {
            popup.addItem(withTitle: "Follow default wallpaper")
            popup.lastItem?.representedObject = AssignmentToken(displayID: displayID, action: .followShared)
        }
        if !choices.isEmpty { popup.menu?.addItem(.separator()) }
        for (index, choice) in choices.enumerated() {
            popup.addItem(withTitle: choice.title)
            popup.lastItem?.representedObject = AssignmentToken(displayID: displayID, action: .library(index))
        }
        popup.selectItem(at: 0)
        popup.isEnabled = enabled && (includeFollowShared || !choices.isEmpty)
        popup.controlSize = .large
        popup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return popup
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let wallpaper,
              let token = sender.selectedItem?.representedObject as? AssignmentToken else {
            sender.selectItem(at: 0)
            return
        }
        switch token.action {
        case .followShared:
            if let id = token.displayID { wallpaper.clearDisplayURL(for: id) }
        case .library(let index):
            guard choices.indices.contains(index) else { return }
            let choice = choices[index]
            do {
                if let url = choice.builtinURL {
                    wallpaper.assignLibraryWallpaper(url, to: token.displayID)
                } else if let id = choice.entryID, let store,
                          let entry = store.catalog.entries.first(where: { $0.id == id }) {
                    let access = try store.access(entry)
                    wallpaper.assignLibraryWallpaper(access.url, to: token.displayID, retaining: access)
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t use that Library wallpaper"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window!)
            }
        }
        sender.selectItem(at: 0)
    }

    @objc private func toggleSame(_ sender: NSButton) {
        wallpaper?.sameWallpaperOnAllDisplays = sender.state == .on
    }

    private func row(title: String, subtitle: String, popup: NSPopUpButton) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.cornerRadius = 10
        box.borderWidth = 1
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(label(title, size: 13, weight: .semibold))
        text.addArrangedSubview(wrappingLabel(subtitle, secondary: true))

        let line = NSStackView(views: [text, popup])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 16
        line.distribution = .fill
        line.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.widthAnchor.constraint(equalToConstant: 230).isActive = true

        guard let content = box.contentView else { return box }
        content.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.topAnchor.constraint(equalTo: content.topAnchor),
            line.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return box
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func wrappingLabel(_ text: String, secondary: Bool) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        return field
    }

    private func displayName(_ url: URL) -> String {
        SceneLibraryController.displayTitle(url.deletingPathExtension().lastPathComponent)
    }

    private func displayDescription(_ screen: NSScreen, displayID: UInt32) -> String {
        let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(displayID))
        var parts: [String] = []
        if let mode { parts.append("\(mode.pixelWidth) × \(mode.pixelHeight)") }
        if CGDisplayIsMain(CGDirectDisplayID(displayID)) != 0 { parts.append("Main display") }
        return parts.joined(separator: " · ")
    }
}
