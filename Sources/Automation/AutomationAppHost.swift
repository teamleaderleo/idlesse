#if os(macOS)
import AppKit
import Foundation

private enum AutomationHostError: LocalizedError {
    case sceneNotFound(String)
    case collectionNotFound(String)
    case emptyCollection(String)
    case ambientSetNotFound(String)
    case noWallpaper
    case variantNotFound(String)
    case variantCouldNotApply

    var errorDescription: String? {
        switch self {
        case .sceneNotFound(let id): return "Library scene not found: \(id)"
        case .collectionNotFound(let id): return "Library collection not found: \(id)"
        case .emptyCollection(let id): return "Library collection has no available scenes: \(id)"
        case .ambientSetNotFound(let id): return "Ambient Set not found: \(id)"
        case .noWallpaper: return "Choose a wallpaper before selecting a variant."
        case .variantNotFound(let id): return "Named variant not found: \(id)"
        case .variantCouldNotApply: return "The selected variant could not be applied to the current renderer."
        }
    }
}

@MainActor
final class AutomationAppHost {
    static var current: AutomationAppHost?

    private struct ResolvedScene {
        var id: String
        var title: String
        var url: URL
        var access: SceneLibraryStore.Access?
    }

    lazy var executor: AutomationCommandExecutor = AutomationCommandExecutor(dependencies: .init(
        applyScene: { [weak self] id in guard let self else { return }; try self.applyScene(id, recordManualHold: true) },
        applyCollection: { [weak self] id in guard let self else { return }; try self.applyCollection(id, recordManualHold: true) },
        applyAmbientSet: { [weak self] id in guard let self else { return }; try self.applyAmbientSet(id) },
        setVariant: { [weak self] variant, scene in guard let self else { return }; try await self.setVariant(variant, sceneID: scene) },
        step: { [weak self] delta in guard let self else { return }; try self.step(delta) },
        setPaused: { [weak self] paused in self?.setPaused(paused) },
        togglePause: { [weak self] in self?.togglePause() },
        pauseFor: { [weak self] seconds in self?.pause(for: seconds) },
        cleanDesktop: { [weak self] in self?.cleanDesktop() },
        currentState: { [weak self] in self?.state() ?? AutomationState(appRunning: true) },
        setLoginItem: { enabled in try LoginItemService.setEnabled(enabled) },
        screenShareState: { await ScreenShareProbe.probe() }
    ))
    private let wallpaper: WallpaperController
    private let comfort: DesktopComfortController
    private let externalStep: (Int) throws -> Void
    private let libraryStore: SceneLibraryStore
    private let ambientStore: AmbientSetStore
    private var retainedAccess: SceneLibraryStore.Access?
    private var currentSceneID: String?
    private var currentSceneURL: URL?
    private var currentCollectionID: String?
    private var collectionSceneIDs: [String] = []
    private var collectionIndex = 0
    private var currentVariantID: String?
    private var currentVariantName: String?
    private var currentAmbientSetID: String?
    private var currentAmbientSetName: String?
    private var pauseTimer: Timer?
    private var pauseUntil: Date?

    init(wallpaper: WallpaperController,
         comfort: DesktopComfortController,
         step: @escaping (Int) throws -> Void) throws {
        self.wallpaper = wallpaper
        self.comfort = comfort
        self.externalStep = step
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        self.libraryStore = try SceneLibraryStore(file: support.appendingPathComponent("Idlesse/Library/index.json"))
        self.ambientStore = try AmbientSetStore(fileURL: support.appendingPathComponent("Idlesse/Ambient Sets/catalog.json"))

        restoreTimedPause()
    }

    func install() {
        Self.current = self
        AutomationRuntimeRegistry.shared.install(executor)
        AutomationMailbox.writeState(state())
    }

    func handleAutomationURL(_ url: URL) {
        Task { @MainActor in
            do {
                let command = try AutomationURLParser.parse(url)
                _ = await AutomationRuntimeRegistry.shared.execute(command)
            } catch {
                NSLog("Idlesse automation URL rejected: %@", error.localizedDescription)
            }
        }
    }

    private func resolveScene(_ token: String) throws -> ResolvedScene {
        if token.hasPrefix("file://"), let url = URL(string: token), FileManager.default.fileExists(atPath: url.path) {
            return ResolvedScene(id: token, title: url.deletingPathExtension().lastPathComponent, url: url, access: nil)
        }
        if FileManager.default.fileExists(atPath: token) {
            let url = URL(fileURLWithPath: token)
            return ResolvedScene(id: token, title: url.deletingPathExtension().lastPathComponent, url: url, access: nil)
        }
        for builtin in SceneLibraryController.builtinScenes() where "builtin.\(builtin.name)" == token || builtin.title.caseInsensitiveCompare(token) == .orderedSame {
            return ResolvedScene(id: "builtin.\(builtin.name)", title: builtin.title, url: builtin.url, access: nil)
        }
        if let entry = libraryStore.catalog.entries.first(where: {
            $0.id == token || $0.catalogID == token || $0.title.caseInsensitiveCompare(token) == .orderedSame
        }) {
            let access = try libraryStore.access(entry)
            return ResolvedScene(id: entry.id, title: entry.title, url: access.url, access: access)
        }
        throw AutomationHostError.sceneNotFound(token)
    }

    private func applyScene(_ token: String, recordManualHold: Bool) throws {
        let scene = try resolveScene(token)
        retainedAccess = scene.access
        currentSceneID = scene.id
        currentSceneURL = scene.url
        currentCollectionID = nil
        collectionSceneIDs = []
        currentVariantID = nil
        currentVariantName = nil
        if recordManualHold {
            try setManualWallpaperHold(.scene(scene.id), label: scene.title)
            currentAmbientSetID = nil
            currentAmbientSetName = nil
        }
        wallpaper.select(scene.url)
    }

    private func applyCollection(_ token: String, recordManualHold: Bool) throws {
        guard let collection = libraryStore.catalog.collections.first(where: {
            $0.id == token || $0.name.caseInsensitiveCompare(token) == .orderedSame
        }) else { throw AutomationHostError.collectionNotFound(token) }
        let available = collection.sceneIDs.filter { id in (try? resolveScene(id)) != nil }
        guard let first = available.first else { throw AutomationHostError.emptyCollection(collection.id) }
        try applyScene(first, recordManualHold: false)
        currentCollectionID = collection.id
        collectionSceneIDs = available
        collectionIndex = 0
        currentAmbientSetID = nil
        currentAmbientSetName = nil
        if recordManualHold { try setManualWallpaperHold(.collection(collection.id), label: collection.name) }
    }

    private func setManualWallpaperHold(_ target: AmbientWallpaperTarget, label: String) throws {
        let resolver = AmbientSetResolver()
        let hold = resolver.makeManualHold(intent: .overrides(.init(wallpaper: target), label: label),
                                           policy: .untilNextAutomaticChange,
                                           sets: ambientStore.catalog.sets)
        try ambientStore.setManualHold(hold)
    }

    private func applyAmbientSet(_ token: String) throws {
        guard let set = ambientStore.catalog.sets.first(where: {
            $0.id == token || $0.name.caseInsensitiveCompare(token) == .orderedSame
        }) else { throw AutomationHostError.ambientSetNotFound(token) }
        let resolver = AmbientSetResolver()
        let hold = resolver.makeManualHold(intent: .set(id: set.id), policy: .untilNextAutomaticChange,
                                           sets: ambientStore.catalog.sets)
        try ambientStore.setManualHold(hold)
        let base = ResolvedDesktopState(
            wallpaper: currentSceneID.map(AmbientWallpaperTarget.scene),
            filesVisible: comfort.desktopIconsVisible,
            widgetsVisible: comfort.desktopWidgetsVisible,
            dimming: .init(enabled: comfort.isDimmed, level: comfort.bedtimeSettings.amount))
        let resolution = resolver.resolve(sets: ambientStore.catalog.sets,
                                          arrangementDefault: base,
                                          manualHold: hold)
        try applyResolvedDesktopState(resolution.state)
        currentAmbientSetID = set.id
        currentAmbientSetName = set.name
    }

    private func applyResolvedDesktopState(_ state: ResolvedDesktopState) throws {
        if let target = state.wallpaper {
            switch target.kind {
            case .scene: try applyScene(target.id, recordManualHold: false)
            case .collection: try applyCollection(target.id, recordManualHold: false)
            }
        }
        if comfort.desktopIconsVisible != state.filesVisible { comfort.toggleDesktopIcons() }
        if comfort.desktopWidgetsVisible != state.widgetsVisible { comfort.toggleDesktopWidgets() }
        let settings = comfort.bedtimeSettings
        comfort.applyBedtime(amount: state.dimming.level, enabled: settings.enabled, start: settings.start, end: settings.end)
        if comfort.isDimmed != state.dimming.enabled { comfort.toggle() }
    }

    private func step(_ delta: Int) throws {
        guard !collectionSceneIDs.isEmpty else { try externalStep(delta); return }
        let id = currentCollectionID
        let ids = collectionSceneIDs
        var index = (collectionIndex + delta) % ids.count
        if index < 0 { index += ids.count }
        try applyScene(ids[index], recordManualHold: false)
        currentCollectionID = id
        collectionSceneIDs = ids
        collectionIndex = index
    }

    private func setVariant(_ token: String, sceneID: String?) async throws {
        if let sceneID, sceneID != currentSceneID { try applyScene(sceneID, recordManualHold: true) }
        guard let url = wallpaper.selectedURL ?? currentSceneURL else { throw AutomationHostError.noWallpaper }
        var spins = 0
        while wallpaper.isLoading && spins < 200 {
            try await Task.sleep(nanoseconds: 25_000_000)
            spins += 1
        }
        guard !wallpaper.isLoading, !wallpaper.surfaces.isEmpty else { throw AutomationHostError.variantCouldNotApply }
        let canonical = try await LocalSceneSource().resolve(url)
        let variant: SceneVariant?
        if token.caseInsensitiveCompare("default") == .orderedSame {
            variant = nil
        } else if let uuid = UUID(uuidString: token) {
            variant = canonical.variants.first(where: { $0.id == uuid })
        } else {
            variant = canonical.variants.first(where: { $0.name.caseInsensitiveCompare(token) == .orderedSame })
        }
        if variant == nil, token.caseInsensitiveCompare("default") != .orderedSame { throw AutomationHostError.variantNotFound(token) }
        let applied = canonical.applyingVariant(id: variant?.id)
        var success = false
        for surface in wallpaper.surfaces { success = surface.updateScene(applied.scene) || success }
        guard success else { throw AutomationHostError.variantCouldNotApply }
        currentVariantID = variant?.id.uuidString
        currentVariantName = variant?.name ?? "Default"
    }

    private func togglePause() {
        pauseTimer?.invalidate(); pauseTimer = nil; pauseUntil = nil
        UserDefaults.standard.removeObject(forKey: "automation.pauseUntil")
        wallpaper.togglePause()
    }

    private func setPaused(_ paused: Bool) {
        pauseTimer?.invalidate(); pauseTimer = nil; pauseUntil = nil
        UserDefaults.standard.removeObject(forKey: "automation.pauseUntil")
        if wallpaper.pausedByUser != paused { wallpaper.togglePause() }
    }

    private func pause(for seconds: Int) {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        pauseUntil = deadline
        UserDefaults.standard.set(deadline, forKey: "automation.pauseUntil")
        if !wallpaper.pausedByUser { wallpaper.togglePause() }
        armResumeTimer(deadline)
    }

    private func restoreTimedPause() {
        guard let deadline = UserDefaults.standard.object(forKey: "automation.pauseUntil") as? Date else { return }
        guard deadline > Date() else {
            UserDefaults.standard.removeObject(forKey: "automation.pauseUntil")
            return
        }
        pauseUntil = deadline
        if !wallpaper.pausedByUser { wallpaper.togglePause() }
        armResumeTimer(deadline)
    }

    private func armResumeTimer(_ deadline: Date) {
        pauseTimer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishTimedPause() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func finishTimedPause() {
        pauseTimer = nil; pauseUntil = nil
        UserDefaults.standard.removeObject(forKey: "automation.pauseUntil")
        if wallpaper.pausedByUser { wallpaper.togglePause() }
        AutomationMailbox.writeState(state())
    }

    private func cleanDesktop() {
        if comfort.desktopIconsVisible { comfort.toggleDesktopIcons() }
        if comfort.desktopWidgetsVisible { comfort.toggleDesktopWidgets() }
    }

    private func state() -> AutomationState {
        if let expected = currentSceneURL, wallpaper.selectedURL != expected {
            currentSceneID = nil
            currentSceneURL = wallpaper.selectedURL
            currentCollectionID = nil
            collectionSceneIDs = []
            currentVariantID = nil
            currentVariantName = nil
            currentAmbientSetID = nil
            currentAmbientSetName = nil
        }
        return AutomationState(
            appRunning: true,
            sceneID: currentSceneID,
            sceneTitle: wallpaper.selectedURL.map { SceneLibraryController.displayTitle($0.deletingPathExtension().lastPathComponent) },
            collectionID: currentCollectionID,
            variantID: currentVariantID,
            variantName: currentVariantName,
            ambientSetID: currentAmbientSetID,
            ambientSetName: currentAmbientSetName,
            paused: wallpaper.pausedByUser,
            pauseUntil: pauseUntil,
            desktopFilesVisible: comfort.desktopIconsVisible,
            desktopWidgetsVisible: comfort.desktopWidgetsVisible,
            loginItemEnabled: LoginItemService.enabled,
            screenShare: .unknown)
    }
}
#endif
