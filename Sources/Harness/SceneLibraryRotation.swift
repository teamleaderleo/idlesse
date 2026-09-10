import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func refreshEmbedded() {
        if selected != nil { preview() }
        collectionView.collectionViewLayout?.invalidateLayout()
        DispatchQueue.main.async { [weak self] in self?.updateThumbnailDemand() }
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if selected != nil { preview() }
    }

    func startSchedules() {
        guard scheduleTimer == nil else { return }
        checkSchedule()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkSchedule() }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    func checkSchedule(now: Date = Date()) {
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

    func beginRotation(_ collection: SceneLibraryStore.Collection, shuffle: Bool) {
        rotationCollectionID = collection.id
        rotationShuffle = shuffle
        rotationMinutes = collection.playback?.minutes ?? 30
        rotationQueue = SceneRotationQueue()
        advanceRotation()
        if rotationCollectionID != nil { armRotationTimer() }
    }

    func stopRotation(manual: Bool = true) {
        if manual, scheduleTimer != nil { checkSchedule() }
        rotationTimer?.invalidate()
        rotationTimer = nil
        rotationCollectionID = nil
        collectionActions.item(at: 0)?.title = "Collections…"
    }

    func releaseActiveUseAccess() { activeUseAccess.removeAll() }
    func releaseActiveEditAccess() { activeEditAccess.removeAll() }
    func retainUseAccess(_ access: SceneLibraryStore.Access?) {
        guard let access, let sourceID = access.sourceID else { return }
        activeUseAccess[sourceID] = access
    }
    func retainEditAccess(_ access: SceneLibraryStore.Access?) {
        guard let access, let sourceID = access.sourceID else { return }
        activeEditAccess[sourceID] = access
    }

    func advanceRotation() {
        guard let id = rotationCollectionID,
              let collection = store.catalog.collections.first(where: { $0.id == id }) else {
            stopRotation(manual: false); return
        }
        let available = allItems()
        let availableByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        let ids = collection.sceneIDs.filter { availableByID[$0] != nil }
        guard let next = rotationQueue.next(ids, shuffle: rotationShuffle),
              let item = availableByID[next] else { stopRotation(manual: false); return }
        do {
            let opened = try open(item)
            try store.used(item.id)
            retainUseAccess(opened.access)
            onUse(opened.url)
        } catch { detail.stringValue = "Rotation: " + error.localizedDescription }
    }

    /// Presentation only: preserve catalog titles and filenames for round trips.
    static func displayTitle(_ title: String) -> String {
        let suffixes = ["-Restored-4K60", "-Restored-4K-HEVC", "-4K-HEVC", "-4K60"]
        guard let suffix = suffixes.first(where: { title.hasSuffix($0) }) else { return title }
        let name = String(title.dropLast(suffix.count))
        let variants = ["Kayoko-Dress": "Kayoko (Dress)", "Hina-Dress": "Hina (Dress)",
            "Hare-Camping": "Hare (Camping)", "Shiroko-Terror": "Shiroko (Terror)",
            "Vivian-Trust": "Vivian (Trust)"]
        return variants[name] ?? name.replacingOccurrences(of: "-", with: " ")
    }

    func allItems() -> [Item] {
        let names = [("DeskClock", "Desk Clock"), ("AfterHours", "After Hours"), ("Undertow", "Undertow"),
                     ("Fireflies", "Fireflies"), ("Ripple", "Ripple"), ("AudioAurora", "Audio Aurora"),
                     ("Gradient", "Aurora"), ("BreathingAurora", "Breathing Aurora")]
        let builtins = names.compactMap { name, title -> Item? in
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Scenes/\(name).idlesse"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Item(id: "builtin.\(name)", title: title, builtin: url, entry: nil)
        }
        return builtins + store.catalog.entries.map {
            Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0)
        }
    }

}
