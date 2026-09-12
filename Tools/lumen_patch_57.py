from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    file.write_text(text.replace(old, new, 1))


# Library: active desktop state + inline daily controls and scene parameters.
replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''    private let poster = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Choose a wallpaper")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let favorite = NSButton(title: "Favorite", target: nil, action: nil)
    private let apply = NSButton(title: "Set Wallpaper", target: nil, action: nil)
    private let edit = NSButton(title: "Edit in Studio", target: nil, action: nil)
    private let clearSearchButton = NSButton(title: "Clear search", target: nil, action: nil)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let remove = NSButton(title: "Remove from Library", target: nil, action: nil)
''',
    r'''    private let poster = NSImageView()
    private let sceneControlsScroll = NSScrollView()
    private let desktopActions = NSStackView()
    private let activeDesktopLabel = NSTextField(labelWithString: "● On Desktop")
    private let previousDesktop = NSButton(title: "Previous", target: nil, action: nil)
    private let pauseDesktop = NSButton(title: "Pause", target: nil, action: nil)
    private let nextDesktop = NSButton(title: "Next", target: nil, action: nil)
    private var inlineControls: SceneParameterControls?
    private var inlineParameterItemID: String?
    private let titleLabel = NSTextField(labelWithString: "Choose a wallpaper")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let favorite = NSButton(title: "Favorite", target: nil, action: nil)
    private let apply = NSButton(title: "Set Wallpaper", target: nil, action: nil)
    private let edit = NSButton(title: "Edit in Studio", target: nil, action: nil)
    private let clearSearchButton = NSButton(title: "Clear search", target: nil, action: nil)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let remove = NSButton(title: "Remove from Library", target: nil, action: nil)
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''    private var selected: Item? {
        didSet { UserDefaults.standard.set(selected?.id, forKey: "Idlesse.library.selectedID") }
    }
    /// Launch-restore for the filter popup, matched by title and consumed by
''',
    r'''    private var selected: Item? {
        didSet { UserDefaults.standard.set(selected?.id, forKey: "Idlesse.library.selectedID") }
    }
    struct DesktopState {
        let url: URL?
        let paused: Bool
        let canPause: Bool
        let scene: SceneDescriptor?
    }
    var desktopStateProvider: (() -> DesktopState)?
    var onToggleDesktopPause: (() -> Void)?
    var onCycleDesktop: ((Int) -> Void)?
    var onApplyDesktopParameters: (([String: SceneParameter]) throws -> Void)?
    private var activeURL: URL?
    private var activeID: String?
    private var desktopPaused = false
    private var desktopCanPause = false
    private var desktopScene: SceneDescriptor?
    /// Launch-restore for the filter popup, matched by title and consumed by
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''        favorite.isBordered = false; favorite.setAccessibilityLabel("Favorite wallpaper")
        let heading = NSStackView(views: [titleLabel, NSView(), favorite])
        heading.orientation = .horizontal
        let primary = NSStackView(views: [apply, edit, more, clearSearchButton])
        primary.spacing = 10
        for button in [add, apply, edit] { button.bezelStyle = .rounded }
        apply.bezelColor = .controlAccentColor
        apply.contentTintColor = .white
        detail.font = .systemFont(ofSize: 12)
        right.setViews([poster, heading, detail, primary], in: .leading)
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
''',
    r'''        favorite.isBordered = false; favorite.setAccessibilityLabel("Favorite wallpaper")
        let heading = NSStackView(views: [titleLabel, NSView(), favorite])
        heading.orientation = .horizontal
        let primary = NSStackView(views: [apply, edit, more, clearSearchButton])
        primary.spacing = 10
        activeDesktopLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        activeDesktopLabel.textColor = .controlAccentColor
        previousDesktop.target = self; previousDesktop.action = #selector(previousDesktopAction)
        pauseDesktop.target = self; pauseDesktop.action = #selector(toggleDesktopPauseAction)
        nextDesktop.target = self; nextDesktop.action = #selector(nextDesktopAction)
        desktopActions.setViews([activeDesktopLabel, previousDesktop, pauseDesktop, nextDesktop], in: .leading)
        desktopActions.orientation = .horizontal
        desktopActions.spacing = 8
        desktopActions.isHidden = true
        sceneControlsScroll.hasVerticalScroller = true
        sceneControlsScroll.autohidesScrollers = true
        sceneControlsScroll.drawsBackground = false
        sceneControlsScroll.isHidden = true
        let previewRow = NSStackView(views: [poster, sceneControlsScroll])
        previewRow.orientation = .horizontal
        previewRow.alignment = .top
        previewRow.spacing = 14
        previewRow.distribution = .fill
        for button in [add, apply, edit, previousDesktop, pauseDesktop, nextDesktop] { button.bezelStyle = .rounded }
        apply.bezelColor = .controlAccentColor
        apply.contentTintColor = .white
        detail.font = .systemFont(ofSize: 12)
        right.setViews([previewRow, heading, detail, desktopActions, primary], in: .leading)
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            right.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            poster.widthAnchor.constraint(equalTo: right.widthAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 9.0 / 16.0),
            heading.widthAnchor.constraint(equalTo: right.widthAnchor),
''',
    r'''            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            right.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            previewRow.widthAnchor.constraint(equalTo: right.widthAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 9.0 / 16.0),
            sceneControlsScroll.widthAnchor.constraint(equalToConstant: 340),
            sceneControlsScroll.heightAnchor.constraint(equalToConstant: 220),
            heading.widthAnchor.constraint(equalTo: right.widthAnchor),
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''        if isGrid {
            gridView.update(items: items, selectedID: selected?.id)
        }
''',
    r'''        if isGrid {
            gridView.update(items: items, selectedID: selected?.id, activeID: activeID)
        }
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''    func refreshEmbedded() {
        if selected != nil { preview() }
    }
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.restoreManagedFrame(name: "IdlesseLibrary", defaultSize: NSSize(width: 1040, height: 640))
        NSApp.activate(ignoringOtherApps: true)
        startHoverMonitor()
        if selected != nil { preview() }
    }
    private func startHoverMonitor() {
''',
    r'''    func refreshEmbedded() {
        refreshDesktopState()
        if selected != nil { preview() }
    }
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.restoreManagedFrame(name: "IdlesseLibrary", defaultSize: NSSize(width: 1040, height: 640))
        NSApp.activate(ignoringOtherApps: true)
        startHoverMonitor()
        refreshDesktopState()
        if selected != nil { preview() }
    }

    func refreshDesktopState() {
        let previousID = activeID
        let previousParameters = desktopScene?.parameters
        pullDesktopState()
        gridView.setActive(id: activeID)
        var changed = IndexSet()
        for (index, item) in items.enumerated() where item.id == previousID || item.id == activeID {
            changed.insert(index)
        }
        if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }
        updateDesktopControls(force: previousID != activeID || previousParameters != desktopScene?.parameters)
    }

    private func pullDesktopState() {
        guard let state = desktopStateProvider?() else { return }
        activeURL = state.url
        desktopPaused = state.paused
        desktopCanPause = state.canPause
        desktopScene = state.scene
        activeID = state.url.flatMap { itemID(for: $0) }
    }

    private func itemID(for url: URL) -> String? {
        let target = url.standardizedFileURL
        for item in items {
            if let builtin = item.builtin, builtin.standardizedFileURL == target { return item.id }
            if let entry = item.entry, let access = try? store.access(entry),
               access.url.standardizedFileURL == target { return item.id }
        }
        return nil
    }

    private func updateDesktopControls(force: Bool = false) {
        let activeSelected = activeURL != nil && selected?.id == activeID
        desktopActions.isHidden = !activeSelected
        pauseDesktop.title = desktopPaused ? "Resume" : "Pause"
        pauseDesktop.isEnabled = activeSelected && desktopCanPause
        previousDesktop.isEnabled = activeSelected && items.count > 1
        nextDesktop.isEnabled = activeSelected && items.count > 1

        guard activeSelected, let scene = desktopScene, !scene.parameters.isEmpty else {
            sceneControlsScroll.isHidden = true
            sceneControlsScroll.documentView = nil
            inlineControls = nil
            inlineParameterItemID = nil
            return
        }
        if !force, inlineParameterItemID == selected?.id,
           inlineControls?.currentValues() == scene.parameters {
            sceneControlsScroll.isHidden = false
            return
        }
        let controls = SceneParameterControls(parameters: scene.parameters)
        controls.onChange = { [weak self] values in
            guard let self, self.selected?.id == self.activeID else { return }
            do {
                try self.onApplyDesktopParameters?(values)
                if var current = self.desktopScene {
                    current.parameters = values
                    self.desktopScene = current
                }
            } catch {
                self.detail.stringValue = "Scene controls: " + error.localizedDescription
            }
        }
        inlineControls = controls
        inlineParameterItemID = selected?.id
        sceneControlsScroll.documentView = controls
        sceneControlsScroll.isHidden = false
    }

    @objc private func toggleDesktopPauseAction() {
        onToggleDesktopPause?()
        refreshDesktopState()
    }
    @objc private func previousDesktopAction() { onCycleDesktop?(-1) }
    @objc private func nextDesktopAction() { onCycleDesktop?(1) }

    private func startHoverMonitor() {
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''        table.reloadData()
        gridView.update(items: items, selectedID: selected?.id)
        updateEmptyState(activeCollection: activeCollection)
''',
    r'''        pullDesktopState()
        table.reloadData()
        gridView.update(items: items, selectedID: selected?.id, activeID: activeID)
        updateEmptyState(activeCollection: activeCollection)
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''        let item = items[row]
        let text = NSTextField(labelWithString: (store.catalog.favorites.contains(item.id) ? "★  " : "") + item.title)
''',
    r'''        let item = items[row]
        let activeMark = item.id == activeID ? "◉  " : ""
        let text = NSTextField(labelWithString: activeMark + (store.catalog.favorites.contains(item.id) ? "★  " : "") + item.title)
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''        more.isEnabled = selected != nil
        more.item(at: 3)?.isEnabled = selected?.entry != nil
        collectionActions.removeAllItems()
''',
    r'''        more.isEnabled = selected != nil
        more.item(at: 3)?.isEnabled = selected?.entry != nil
        updateDesktopControls()
        collectionActions.removeAllItems()
''')

# Wallpaper host: expose the current runtime descriptor and one transactional
# parameter application path so Library and the existing modal share semantics.
replace_once(
    "Sources/Wallpaper/WallpaperController.swift",
    r'''    var isRunning: Bool { selectedURL != nil }
    private var suspended: Bool { asleep || systemAsleep || sessionInactive }
''',
    r'''    var isRunning: Bool { selectedURL != nil }
    var activeScene: SceneDescriptor? { playable }
    var canPauseActiveScene: Bool { isRunning && selectedIsAnimated }
    private var suspended: Bool { asleep || systemAsleep || sessionInactive }
''')

replace_once(
    "Sources/Wallpaper/WallpaperController.swift",
    r'''    @objc private func editControls() {
        guard let original = playable, !isLoading else { return }
        SceneParameterControls.present(scene: original, window: nil) { [weak self] parameters in
            guard let self, self.playable?.parameters == original.parameters, !self.isLoading,
                  self.playable?.allNodes.map(\.id) == original.allNodes.map(\.id) else { return }
            var next = original
            next.parameters = parameters
            do { _ = try next.evaluated() } catch { self.showError(error.localizedDescription); return }
            for surface in self.surfaces {
                guard surface.updateScene(next) else {
                    self.surfaces.forEach { _ = $0.updateScene(original) }
                    self.showError("The scene controls could not be applied. The previous values were restored.")
                    return
                }
            }
            self.playable = next
            self.updateMenu()
        }
    }
''',
    r'''    func applySceneParameters(_ parameters: [String: SceneParameter]) throws {
        guard let original = playable, !isLoading,
              Set(parameters.keys) == Set(original.parameters.keys),
              parameters.values.allSatisfy(\.isValid) else {
            throw SceneError.invalid("The active scene controls changed. Select the wallpaper again and retry.")
        }
        var next = original
        next.parameters = parameters
        _ = try next.evaluated()
        for surface in surfaces {
            guard surface.updateScene(next) else {
                surfaces.forEach { _ = $0.updateScene(original) }
                throw SceneError.invalid("The scene controls could not be applied. The previous values were restored.")
            }
        }
        playable = next
        updateMenu()
    }

    @objc private func editControls() {
        guard let original = playable, !isLoading else { return }
        SceneParameterControls.present(scene: original, window: nil) { [weak self] parameters in
            guard let self, self.playable?.parameters == original.parameters, !self.isLoading,
                  self.playable?.allNodes.map(\.id) == original.allNodes.map(\.id) else { return }
            do { try self.applySceneParameters(parameters) }
            catch { self.showError(error.localizedDescription) }
        }
    }
''')

# Host wiring: Library reads state from WallpaperController, then invokes the
# same daily actions and runtime parameter application used elsewhere.
replace_once(
    "Sources/Harness/main.swift",
    r'''        library?.onPeek = { [weak self] url in self?.wallpaper.peek(url) }
        library?.onEndPeek = { [weak self] reverting in
            self?.wallpaper.endPeek(reverting: reverting)
            self?.modes.refresh()
        }
        }
''',
    r'''        library?.onPeek = { [weak self] url in self?.wallpaper.peek(url) }
        library?.onEndPeek = { [weak self] reverting in
            self?.wallpaper.endPeek(reverting: reverting)
            self?.modes.refresh()
        }
        library?.desktopStateProvider = { [weak self] in
            guard let self else { return .init(url: nil, paused: false, canPause: false, scene: nil) }
            return .init(url: self.wallpaper.selectedURL,
                         paused: self.wallpaper.pausedByUser,
                         canPause: self.wallpaper.canPauseActiveScene,
                         scene: self.wallpaper.activeScene)
        }
        library?.onToggleDesktopPause = { [weak self] in self?.wallpaper.togglePause() }
        library?.onCycleDesktop = { [weak self] delta in self?.stepWallpaper(delta: delta) }
        library?.onApplyDesktopParameters = { [weak self] parameters in
            guard let self else { return }
            try self.wallpaper.applySceneParameters(parameters)
        }
        library?.refreshDesktopState()
        }
''')

replace_once(
    "Sources/Harness/main.swift",
    r'''        wallpaper.onStop = { [weak self] in
            self?.library?.releaseActiveUseAccess()
            self?.showLibrary()
        }
''',
    r'''        wallpaper.onStop = { [weak self] in
            self?.library?.releaseActiveUseAccess()
            self?.library?.refreshDesktopState()
            self?.showLibrary()
        }
''')

replace_once(
    "Sources/Harness/main.swift",
    r'''        wallpaper.onSelectionCommitted = { [weak self] url in
            self?.modes.adoptManualSelection(url)
            self?.noteRecentScene(url)
        }
''',
    r'''        wallpaper.onSelectionCommitted = { [weak self] url in
            self?.modes.adoptManualSelection(url)
            self?.noteRecentScene(url)
            self?.library?.refreshDesktopState()
        }
''')

replace_once(
    "Sources/Harness/main.swift",
    r'''        hotKeys.onTogglePause = { [weak self] in self?.wallpaper.togglePause() }
''',
    r'''        hotKeys.onTogglePause = { [weak self] in
            self?.wallpaper.togglePause()
            self?.library?.refreshDesktopState()
        }
''')

# UI smoke: active designation, daily Pause/Resume, and declared controls in detail.
replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''        controller.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        controller.selected = controller.items[index]
        controller.preview()
''',
    r'''        controller.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        controller.selected = controller.items[index]
        let activeURL = controller.items[index].builtin!
        var activeScene = try LocalSceneSource.read(activeURL)
        activeScene.parameters["smoke"] = SceneParameter(name: "Smoke", value: 0.5, min: 0, max: 1)
        var desktopPaused = false
        var pauseCalls = 0
        controller.desktopStateProvider = {
            .init(url: activeURL, paused: desktopPaused, canPause: true, scene: activeScene)
        }
        controller.onToggleDesktopPause = { desktopPaused.toggle(); pauseCalls += 1 }
        controller.onApplyDesktopParameters = { values in activeScene.parameters = values }
        controller.refreshDesktopState()
        precondition(controller.activeID == controller.selected?.id, "Active wallpaper must be distinct from cursor selection")
        precondition(!controller.desktopActions.isHidden && controller.pauseDesktop.title == "Pause")
        precondition(controller.sceneControlsScroll.documentView is SceneParameterControls,
                     "Active declared scene controls must appear inline")
        controller.toggleDesktopPauseAction()
        precondition(pauseCalls == 1 && controller.pauseDesktop.title == "Resume",
                     "Inline Pause/Resume must reflect desktop state")
        controller.preview()
''')

replace_once(
    "Sources/Harness/SceneLibraryController.swift",
    r'''        print("Library UI checks passed: built-in poster/color, favorites, search, source controls, draft routing\(videoURL == nil ? "" : ", composed video poster"); offscreen snapshot saved")
''',
    r'''        print("Library UI checks passed: built-in poster/color, favorites, search, source controls, active desktop controls, draft routing\(videoURL == nil ? "" : ", composed video poster"); offscreen snapshot saved")
''')

# Library documentation: daily actions stay inline; menus retain long-tail commands.
replace_once(
    "docs/library.md",
    r'''## Posters and resource bounds
''',
    r'''## Daily active-wallpaper controls

The Library distinguishes the wallpaper committed to the desktop from the current
cursor selection. List mode uses a `◉` marker and grid mode uses an **On Desktop** pill;
virtualized grid cards reapply that state whenever a card is reused after scrolling.

Select the active wallpaper to get the daily controls inline: Previous, Pause/Resume,
and Next. Pause is enabled for animated scenes. When the active `.idlesse` scene
declares scene controls, the same `SceneParameterControls` used by Studio and the
wallpaper menu appears beside the poster and applies validated values live to the
running surfaces. These desktop tweaks remain session values for the active scene;
editing package defaults still belongs in Studio. Collections, Sources, transitions,
removal, scheduling, and other long-tail commands remain in their existing menus.

## Posters and resource bounds
''')

print("#57 patch applied")
