import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Native reference library with one on-demand poster, never a grid of live renderers.
final class SceneLibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
    }
    private let store: SceneLibraryStore
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSPopUpButton()
    private let sort = NSPopUpButton()
    private let collectionActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let poster = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Choose a scene")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let favorite = NSButton(title: "Favorite", target: nil, action: nil)
    private let apply = NSButton(title: "Use on Desktop", target: nil, action: nil)
    private let edit = NSButton(title: "Open in Studio", target: nil, action: nil)
    private let remove = NSButton(title: "Remove from Library", target: nil, action: nil)
    private enum PosterRevision: Equatable, Sendable {
        case package(ScenePackageWriter.Revision)
        case file(Date?, Int?)
        static func read(_ source: URL) throws -> PosterRevision {
            var url = source
            url.removeAllCachedResourceValues()
            if url.pathExtension.lowercased() == "idlesse" { return .package(try ScenePackageWriter.revision(of: url)) }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return .file(values.contentModificationDate, values.fileSize)
        }
    }
    private var cache: [String: (image: NSImage, note: String, revision: PosterRevision)] = [:]
    private var cacheOrder: [String] = []
    private var items: [Item] = []
    private var selected: Item?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var rotationTimer: Timer?
    private var rotationCollectionID: String?
    private var rotationQueue = SceneRotationQueue()
    private var rotationShuffle = false
    private var rotationMinutes = 30
    private var scheduleTimer: Timer?
    private var scheduleToken: String?
    func startSchedules() {
        guard scheduleTimer == nil else { return }
        checkSchedule()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkSchedule() }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }
    private func checkSchedule(now: Date = Date()) {
        let collection = store.scheduledCollection(at: now)
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: now)
        if let settings = collection?.playback, let start = settings.startMinute, let end = settings.endMinute,
           start > end, calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now) < end {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        let token = collection.map { "\($0.id):\(day.timeIntervalSince1970)" } ?? "outside"
        guard token != scheduleToken else { return }
        scheduleToken = token
        stopRotation(manual: false)
        if let collection { beginRotation(collection, shuffle: collection.playback?.shuffle ?? false) }
    }
    private func beginRotation(_ collection: SceneLibraryStore.Collection, shuffle: Bool) {
        rotationCollectionID = collection.id
        rotationShuffle = shuffle
        rotationMinutes = collection.playback?.minutes ?? 30
        rotationQueue = SceneRotationQueue()
        advanceRotation()
        if rotationCollectionID != nil { armRotationTimer() }
    }
    func stopRotation(manual: Bool = true) {
        if manual {
            // Record the current boundary before stopping, including before the first timer tick.
            if scheduleTimer != nil { checkSchedule() }
        }
        rotationTimer?.invalidate()
        rotationTimer = nil
        rotationCollectionID = nil
        collectionActions.item(at: 0)?.title = "Collections"
    }
    private func advanceRotation() {
        guard let id = rotationCollectionID,
              let collection = store.catalog.collections.first(where: { $0.id == id }) else {
            stopRotation(manual: false); return
        }
        let available = allItems()
        let ids = collection.sceneIDs.filter { id in available.contains { $0.id == id } }
        guard let next = rotationQueue.next(ids, shuffle: rotationShuffle),
              let item = available.first(where: { $0.id == next }) else { stopRotation(manual: false); return }
        do {
            let target = try url(item)
            try store.used(item.id)
            onUse(target)
        } catch { detail.stringValue = "Rotation: " + error.localizedDescription }
    }
    private var onUse: (URL) -> Void
    private var onEdit: (URL, Bool) -> Void

    init(indexURL: URL? = nil, onUse: @escaping (URL) -> Void, onEdit: @escaping (URL, Bool) -> Void) throws {
        self.onUse = onUse
        self.onEdit = onEdit
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        store = try SceneLibraryStore(file: indexURL ?? support.appendingPathComponent("Idlesse/Library/index.json"))
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false))
        window?.title = "Idlesse Library"
        window?.minSize = NSSize(width: 840, height: 520)
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        window?.center()
        setup()
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        search.placeholderString = "Search scenes"
        search.delegate = self
        filter.addItems(withTitles: ["All Scenes", "Built-in", "Imported", "Favorites"])
        filter.target = self; filter.action = #selector(filterChanged)
        sort.addItems(withTitles: ["Name", "Recently Opened"])
        sort.target = self; sort.action = #selector(filterChanged)
        let add = NSButton(title: "Add Scenes…", target: self, action: #selector(addScenes))
        collectionActions.addItem(withTitle: "Collections")
        collectionActions.target = self
        collectionActions.action = #selector(collectionAction)
        let toolbar = NSStackView(views: [search, filter, sort, add])
        toolbar.spacing = 10
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Scene"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .sourceList
        table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(doubleClickScene)
        table.setAccessibilityLabel("Scenes")
        table.registerForDraggedTypes([.fileURL])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.black.cgColor
        poster.layer?.cornerRadius = 10
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        favorite.target = self; favorite.action = #selector(toggleFavorite)
        apply.target = self; apply.action = #selector(useScene)
        edit.target = self; edit.action = #selector(editScene)
        remove.target = self; remove.action = #selector(removeScene)
        let refresh = NSButton(title: "Refresh Preview", target: self, action: #selector(refreshPreview))
        let actions = NSStackView(views: [favorite, refresh, remove])
        let duplicate = NSButton(title: "Make a Copy in Studio", target: self, action: #selector(duplicateScene))
        let primary = NSStackView(views: [edit, duplicate, apply])
        for button in [add, favorite, apply, edit, remove, refresh, duplicate] { button.bezelStyle = .rounded }
        let right = NSStackView(views: [titleLabel, collectionActions, poster, detail, actions, primary])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        for view in [toolbar, scroll, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        poster.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalToConstant: 250),
            right.topAnchor.constraint(equalTo: scroll.topAnchor),
            right.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 22),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            poster.widthAnchor.constraint(equalTo: right.widthAnchor),
            poster.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            detail.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if selected != nil { preview() }
    }
    private func allItems() -> [Item] {
        let names = [("AfterHours", "After Hours"), ("Undertow", "Undertow"), ("Fireflies", "Fireflies"), ("Ripple", "Ripple"),
                     ("AudioAurora", "Audio Aurora"), ("Gradient", "Aurora"), ("BreathingAurora", "Breathing Aurora")]
        let builtins = names.compactMap { name, title -> Item? in
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Scenes/\(name).idlesse"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Item(id: "builtin.\(name)", title: title, builtin: url, entry: nil)
        }
        return builtins + store.catalog.entries.map { Item(id: $0.id, title: $0.title, builtin: nil, entry: $0) }
    }
    @objc private func filterChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload(selecting id: String? = nil) {
        let previous = id ?? selected?.id
        let collectionID = filter.selectedItem?.representedObject as? String
        let previousFilter = min(filter.indexOfSelectedItem, 3)
        filter.removeAllItems()
        filter.addItems(withTitles: ["All Scenes", "Built-in", "Imported", "Favorites"])
        for collection in store.catalog.collections {
            filter.addItem(withTitle: "Collection: \(collection.name)")
            filter.lastItem?.representedObject = collection.id
        }
        if let collectionID, let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == collectionID }) {
            filter.selectItem(at: index)
        } else { filter.selectItem(at: max(0, previousFilter)) }
        let activeCollection = store.catalog.collections.first { $0.id == (filter.selectedItem?.representedObject as? String) }
        items = allItems().filter { item in
            let matches = search.stringValue.isEmpty || item.title.localizedCaseInsensitiveContains(search.stringValue)
            if let activeCollection { return matches && activeCollection.sceneIDs.contains(item.id) }
            switch filter.indexOfSelectedItem {
            case 1: return matches && item.builtin != nil
            case 2: return matches && item.entry != nil
            case 3: return matches && store.catalog.favorites.contains(item.id)
            default: return matches
            }
        }.sorted {
            if sort.indexOfSelectedItem == 1 {
                let a = store.catalog.recent[$0.id] ?? .distantPast, b = store.catalog.recent[$1.id] ?? .distantPast
                if a != b { return a > b }
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        table.reloadData()
        if let index = items.firstIndex(where: { $0.id == previous }) ?? (items.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            // Reloading can keep the same row number while changing its identity.
            // AppKit need not send a selection notification in that case.
            selected = items[index]
            preview()
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
            selected = nil
            preview()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let text = NSTextField(labelWithString: (store.catalog.favorites.contains(item.id) ? "★  " : "") + item.title)
        text.lineBreakMode = .byTruncatingTail
        return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        selected = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        preview()
    }
    private func url(_ item: Item) throws -> URL {
        if let builtin = item.builtin { return builtin }
        guard let entry = item.entry else { throw CocoaError(.fileNoSuchFile) }
        return try store.resolve(entry)
    }
    @objc private func refreshPreview() {
        if let selected { cache.removeValue(forKey: selected.id); cacheOrder.removeAll { $0 == selected.id } }
        preview()
    }
    private func preview() {
        task?.cancel(); task = nil; generation += 1
        let token = generation
        poster.image = nil
        favorite.isEnabled = selected != nil
        apply.isEnabled = selected != nil
        edit.isEnabled = selected != nil
        remove.isEnabled = selected?.entry != nil
        collectionActions.removeAllItems()
        collectionActions.addItems(withTitles: [rotationTimer == nil ? "Collections" : "Collections · Rotating every \(rotationMinutes)m", "New Collection…"])
        if filter.selectedItem?.representedObject is String {
            collectionActions.addItems(withTitles: ["Rename Collection…", "Delete Collection…",
                "Play Collection in Order", "Shuffle Collection", "Playback & Daily Schedule…"])
        }
        collectionActions.addItems(withTitles: ["Change Every 5 Minutes", "Change Every 15 Minutes", "Change Every 30 Minutes", "Change Every 60 Minutes"])
        if rotationTimer != nil {
            collectionActions.addItem(withTitle: "Stop Collection Rotation")
        }
        if let selected {
            for collection in store.catalog.collections {
                collectionActions.addItem(withTitle: "\(collection.sceneIDs.contains(selected.id) ? "Remove from" : "Add to") \(collection.name)")
                collectionActions.lastItem?.representedObject = collection.id
            }
        }
        guard let selected else { titleLabel.stringValue = "No scenes"; detail.stringValue = "Add a scene or change the search/filter."; return }
        titleLabel.stringValue = selected.title
        favorite.title = store.catalog.favorites.contains(selected.id) ? "★ Favorited" : "☆ Favorite"
        detail.stringValue = "Preparing still preview…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.task = nil } }
            do {
                let url = try self.url(selected)
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let revision = try await Task.detached(priority: .utility) { try PosterRevision.read(url) }.value
                try Task.checkCancellation()
                guard token == self.generation else { return }
                if let cached = self.cache[selected.id], cached.revision == revision {
                    self.poster.image = cached.image
                    self.detail.stringValue = cached.note
                    return
                }
                self.cache.removeValue(forKey: selected.id)
                let scene = try await LocalSceneSource().resolve(url)
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let image: NSImage
                let previewTime = scene.metadata?.previewTime ?? 2
                let note = "Still preview at \(String(format: "%g", previewTime))s · Open in Studio for playback · Pointer/audio access off"
                let clock = SceneClock(now: { 0 })
                try clock.configure(timeline: scene.timeline)
                try clock.seek(to: previewTime)
                let renderer = try MetalSceneRenderer(playable: scene, bounds: NSRect(x: 0, y: 0, width: 512, height: 512), scale: 1, clock: clock, onError: { _ in })
                defer { renderer.releaseResources() }
                try await renderer.prepareOfflineVideo(at: scene.timeline?.videosFollowScene == true ? clock.time : previewTime,
                                                       size: CGSize(width: 512, height: 512))
                try Task.checkCancellation()
                let bytes = try renderer.renderFrame(signals: .init(time: clock.time), width: 512, height: 512, sampleVideo: false)
                guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                      let frame = CGImage(width: 512, height: 512, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: 2048, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw SceneError.invalid("Could not prepare the Library preview.") }
                image = NSImage(cgImage: frame, size: NSSize(width: 512, height: 512))
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let after = try await Task.detached(priority: .utility) { try PosterRevision.read(url) }.value
                try Task.checkCancellation()
                guard token == self.generation else { return }
                guard after == revision else { throw SceneError.invalid("Scene changed while preparing its preview. Select it again to retry.") }
                self.cacheOrder.removeAll { $0 == selected.id }
                while self.cacheOrder.count >= 8 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
                self.cacheOrder.append(selected.id)
                self.cache[selected.id] = (image, note, revision)
                self.poster.image = image
                self.detail.stringValue = note
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.detail.stringValue = "Preview unavailable: \(error.localizedDescription). Try Open in Studio, or re-add a moved file."
            }
        }
    }

    @objc private func addScenes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, UTType(filenameExtension: "idlesse") ?? .package]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Add references to scenes or media. Originals stay in their current folder."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK else { return }
            self.importScenes(panel.urls)
        }
    }
    private static func supportedImport(_ url: URL) -> Bool {
        url.isFileURL && ["idlesse", "jpg", "jpeg", "png", "heic", "mp4", "mov"].contains(url.pathExtension.lowercased())
    }
    private func droppedURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(Self.supportedImport)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !droppedURLs(info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = droppedURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        importScenes(urls)
        return true
    }
    private func importScenes(_ urls: [URL]) {
        var firstID: String?
        var failures: [String] = []
        for url in urls {
            do {
                guard Self.supportedImport(url) else { throw SceneError.invalid("Choose an Idlesse package, JPG, PNG, HEIC, MP4, or MOV.") }
                let entry = try store.add(url)
                if firstID == nil { firstID = entry.id }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if firstID != nil {
            search.stringValue = ""
            filter.selectItem(at: 2)
        }
        reload(selecting: firstID)
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some scenes could not be added"
            alert.informativeText = failures.joined(separator: "\n")
            if let window { alert.beginSheetModal(for: window) }
        }
    }
    @objc private func toggleFavorite() {
        guard let selected else { return }
        do { try store.favorite(selected.id); reload() } catch { detail.stringValue = error.localizedDescription }
    }
    @objc private func removeScene() {
        guard let selected, selected.entry != nil else { return }
        do { try store.remove(selected.id); cache.removeValue(forKey: selected.id); cacheOrder.removeAll { $0 == selected.id }; reload() }
        catch { detail.stringValue = error.localizedDescription }
    }
    @objc private func useScene() { act(editing: false) }
    @objc private func collectionAction() {
        guard let item = collectionActions.selectedItem else { return }
        if item.title == "Playback & Daily Schedule…" { editPlayback(); return }
        if item.title == "Stop Collection Rotation" { stopRotation(); preview(); return }
        if item.title.hasPrefix("Change Every "), let minutes = Int(item.title.split(separator: " ")[2]) {
            if let id = filter.selectedItem?.representedObject as? String,
               let collection = store.catalog.collections.first(where: { $0.id == id }) {
                var settings = collection.playback ?? SceneLibraryStore.Playback()
                settings.minutes = minutes
                do { try store.setPlayback(id, settings) }
                catch { detail.stringValue = error.localizedDescription; return }
            }
            let editedID = filter.selectedItem?.representedObject as? String
            if rotationCollectionID == nil || editedID == rotationCollectionID {
                rotationMinutes = minutes
                if rotationTimer != nil { armRotationTimer(); preview() }
            }
            detail.stringValue = "Collections change every \(minutes) minutes."
            return
        }
        if item.title == "Play Collection in Order" || item.title == "Shuffle Collection" {
            guard let id = filter.selectedItem?.representedObject as? String,
                  let collection = store.catalog.collections.first(where: { $0.id == id }),
                  !collection.sceneIDs.isEmpty else { detail.stringValue = "Add scenes to this collection first."; return }
            stopRotation()
            var settings = collection.playback ?? SceneLibraryStore.Playback()
            settings.shuffle = item.title == "Shuffle Collection"
            do { try store.setPlayback(id, settings) }
            catch { detail.stringValue = error.localizedDescription; return }
            beginRotation(store.catalog.collections.first { $0.id == id }!, shuffle: settings.shuffle)
            preview()
            return
        }
        if let id = item.representedObject as? String, let selected {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
            catch { detail.stringValue = error.localizedDescription }
            return
        }
        let activeID = filter.selectedItem?.representedObject as? String
        let deleting = item.title == "Delete Collection…"
        let renaming = item.title == "Rename Collection…"
        guard item.title == "New Collection…" || deleting || renaming else { return }
        let alert = NSAlert()
        alert.messageText = deleting ? "Delete this collection?" : (renaming ? "Rename Collection" : "New Collection")
        alert.informativeText = deleting ? "Scenes and original files stay in your Library." : "Give this group of scenes a name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = renaming ? (store.catalog.collections.first { $0.id == activeID }?.name ?? "") : ""
        if !deleting { alert.accessoryView = field }
        alert.addButton(withTitle: deleting ? "Delete Collection" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            do {
                if deleting, let activeID { try self.store.removeCollection(activeID); self.filter.selectItem(at: 0) }
                else if renaming, let activeID { try self.store.renameCollection(activeID, name: field.stringValue) }
                else {
                    let collection = try self.store.createCollection(name: field.stringValue)
                    self.reload()
                    self.filter.selectItem(at: self.filter.itemArray.firstIndex { ($0.representedObject as? String) == collection.id }!)
                    self.search.stringValue = ""
                }
                self.reload()
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }
    private func editPlayback() {
        guard let id = filter.selectedItem?.representedObject as? String,
              let collection = store.catalog.collections.first(where: { $0.id == id }), let window else { return }
        let settings = collection.playback ?? SceneLibraryStore.Playback()
        let enabled = NSButton(checkboxWithTitle: "Play on a daily schedule", target: nil, action: nil)
        enabled.state = settings.startMinute == nil ? .off : .on
        let shuffle = NSButton(checkboxWithTitle: "Shuffle without repeats", target: nil, action: nil)
        shuffle.state = settings.shuffle ? .on : .off
        let interval = NSPopUpButton()
        interval.addItems(withTitles: ["5 minutes", "15 minutes", "30 minutes", "60 minutes"])
        interval.selectItem(at: [5, 15, 30, 60].firstIndex(of: settings.minutes) ?? 2)
        func picker(_ minute: Int) -> NSDatePicker {
            let view = NSDatePicker()
            view.datePickerElements = .hourMinute
            view.datePickerStyle = .textFieldAndStepper
            view.dateValue = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date())!
            return view
        }
        let start = picker(settings.startMinute ?? 420)
        let end = picker(settings.endMinute ?? 1320)
        let stack = NSStackView(views: [enabled, NSTextField(labelWithString: "From"), start,
            NSTextField(labelWithString: "Until"), end, NSTextField(labelWithString: "Change scene every"), interval, shuffle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 270)
        let alert = NSAlert()
        alert.messageText = collection.name + " Playback"
        alert.informativeText = "Daily local time, including overnight ranges. Manual wallpaper choices last until the next boundary. Bedtime dimming stays independent."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            func minute(_ picker: NSDatePicker) -> Int {
                let c = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
                return c.hour! * 60 + c.minute!
            }
            let updated = SceneLibraryStore.Playback(minutes: [5, 15, 30, 60][interval.indexOfSelectedItem],
                shuffle: shuffle.state == .on, startMinute: enabled.state == .on ? minute(start) : nil,
                endMinute: enabled.state == .on ? minute(end) : nil)
            do {
                try self.store.setPlayback(id, updated)
                self.scheduleToken = nil
                self.checkSchedule()
                self.preview()
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }
    private func armRotationTimer() {
        rotationTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(rotationMinutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            let previous = self.scheduleToken
            if self.scheduleTimer != nil { self.checkSchedule() }
            if previous == self.scheduleToken { self.advanceRotation() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }
    @objc private func doubleClickScene() {
        guard items.indices.contains(table.clickedRow) else { return }
        selected = items[table.clickedRow]
        act(editing: false)
    }
    @objc private func editScene() { act(editing: true) }
    @objc private func duplicateScene() { act(editing: true, asCopy: true) }
    private func act(editing: Bool, asCopy: Bool = false) {
        guard let selected else { return }
        do {
            let url = try url(selected)
            try store.used(selected.id)
            if editing { onEdit(url, asCopy || selected.builtin != nil) } else { stopRotation(); onUse(url); window?.orderOut(nil) }
        } catch { detail.stringValue = error.localizedDescription }
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); generation += 1
        cache.removeAll(); cacheOrder.removeAll(); poster.image = nil
    }
    deinit { task?.cancel(); rotationTimer?.invalidate(); scheduleTimer?.invalidate() }

    static func smokeTest(outputURL: URL, videoURL: URL? = nil) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("revision.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: raw)
        let oldRevision = try PosterRevision.read(raw)
        try Data([1, 2]).write(to: raw)
        let newRevision = try PosterRevision.read(raw)
        precondition(oldRevision != newRevision)
        var copied = false
        var applied = false
        let controller = try SceneLibraryController(indexURL: folder.appendingPathComponent("index.json"),
            onUse: { _ in applied = true }, onEdit: { _, asCopy in copied = asCopy })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([raw as NSURL, folder.appendingPathComponent("ignored.txt") as NSURL])
        precondition(controller.droppedURLs(pasteboard) == [raw])
        precondition(controller.items.count == 7)
        let index = controller.items.firstIndex { $0.title == "Undertow" }!
        controller.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        controller.selected = controller.items[index]
        controller.preview()
        let deadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let colors = NSBitmapImageRep(data: controller.poster.image!.tiffRepresentation!)!
        var hasWarmColor = false
        for y in stride(from: 0, to: colors.pixelsHigh, by: 32) {
            for x in stride(from: 0, to: colors.pixelsWide, by: 32) {
                if let color = colors.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent - color.blueComponent > 0.2 {
                    hasWarmColor = true
                }
            }
        }
        precondition(hasWarmColor, "Undertow's copper poster must preserve BGRA channel order")
        controller.editScene()
        precondition(copied, "Built-in edits must become drafts")
        controller.doubleClickScene()
        precondition(!applied, "An empty-space double-click must not apply the selection")
        controller.toggleFavorite()
        controller.filter.selectItem(at: 3)
        controller.reload()
        precondition(controller.items.count == 1 && controller.items[0].title == "Undertow")
        precondition(controller.selected?.id == controller.items[0].id)
        let collection = try controller.store.createCollection(name: "Psychedelic")
        try controller.store.toggleMembership(sceneID: controller.selected!.id, collectionID: collection.id)
        controller.reload()
        controller.filter.selectItem(at: controller.filter.itemArray.firstIndex { ($0.representedObject as? String) == collection.id }!)
        controller.reload()
        precondition(controller.items.count == 1 && controller.selected?.title == "Undertow")
        precondition(controller.collectionActions.itemArray.contains { $0.title == "Rename Collection…" })
        controller.collectionActions.selectItem(withTitle: "Shuffle Collection")
        controller.collectionAction()
        precondition(applied && controller.rotationTimer != nil)
        applied = false
        controller.rotationTimer?.fire()
        precondition(applied, "Rotation timer must apply the next scene")
        controller.stopRotation()
        precondition(controller.rotationTimer == nil && controller.rotationCollectionID == nil)
        try controller.store.setPlayback(collection.id, .init(startMinute: 0, endMinute: 720))
        let today = Calendar.current.startOfDay(for: Date())
        let morning = Calendar.current.date(byAdding: .hour, value: 1, to: today)!
        applied = false
        controller.checkSchedule(now: morning)
        precondition(applied && controller.rotationTimer != nil)
        controller.stopRotation()
        applied = false
        controller.checkSchedule(now: morning.addingTimeInterval(60))
        precondition(!applied && controller.rotationTimer == nil, "Manual stop must last through this schedule window")
        controller.checkSchedule(now: Calendar.current.date(byAdding: .day, value: 1, to: morning)!)
        precondition(applied && controller.rotationTimer != nil, "A new daily boundary must resume scheduling even after a missed day")
        controller.stopRotation()
        try controller.store.setPlayback(collection.id, .init())
        controller.preview()
        let posterDeadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < posterDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let root = controller.window!.contentView!
        root.layoutSubtreeIfNeeded()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL, options: .withoutOverwriting)
        controller.search.stringValue = "No matching scene"
        controller.reload()
        precondition(controller.items.isEmpty && !controller.apply.isEnabled)
        if let videoURL {
            controller.importScenes([videoURL])
            precondition(controller.search.stringValue.isEmpty && controller.filter.indexOfSelectedItem == 2)
            precondition(controller.items.count == 1 && controller.selected?.id == controller.items[0].id,
                         "Import must reveal and select its scene despite previous search/filter")
            let videoDeadline = Date().addingTimeInterval(10)
            while controller.task != nil && Date() < videoDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(controller.poster.image != nil && controller.detail.stringValue.hasPrefix("Still preview at 2s"), controller.detail.stringValue)
            // A transparent video must produce black, not a thumbnail of the raw asset.
            var video = SceneNode(content: .video(videoURL))
            video.opacity = 0
            let package = folder.appendingPathComponent("Transparent Video.idlesse")
            try ScenePackageWriter.write(SceneDescriptor(title: "Transparent Video", nodes: [video]), to: package)
            controller.importScenes([package])
            let compositionDeadline = Date().addingTimeInterval(10)
            while controller.task != nil && Date() < compositionDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(controller.poster.image != nil, controller.detail.stringValue)
            let pixels = NSBitmapImageRep(data: controller.poster.image!.tiffRepresentation!)!
            for y in stride(from: 0, to: pixels.pixelsHigh, by: 32) {
                for x in stride(from: 0, to: pixels.pixelsWide, by: 32) {
                    let color = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    precondition(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.01,
                                 "Video posters must respect scene opacity instead of exposing the raw frame")
                }
            }
        }
        controller.window?.close()
        print("Library UI checks passed: built-in poster/color, favorites, search, draft routing\(videoURL == nil ? "" : ", composed video poster"); offscreen snapshot saved")
    }
}
