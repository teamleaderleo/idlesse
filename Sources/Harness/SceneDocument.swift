import AppKit
import AVFoundation

/// Document state and asset access. Snapshots contain references, never decoded media.
final class SceneDocument {
    struct Snapshot {
        let scene: SceneDescriptor
        let selected: Int
        let draft: Bool
    }
    var scene = SceneDescriptor(title: "Aurora", nodes: [SceneNode(content: .gradient)])
    var sourceURL: URL?
    var revision: ScenePackageWriter.Revision?
    var scopedURL: URL?
    var workingAssets: [URL] = []
    var draft = false { didSet { scheduleRecovery() } }
    var busy = false
    var savedScene: SceneDescriptor?
    let undoManager = SceneUndoManager()
    // Mirror only the targets, so failed renderer preparation can cancel native Undo
    // before it consumes an entry. The native manager owns actions and menu names.
    var undoTargets: [Snapshot] = []
    var redoTargets: [Snapshot] = []
    var prepareRestore: ((Snapshot) -> Bool)?
    var didRestore: ((Snapshot) -> Void)?
    var currentSelection: (() -> Int)?

    private var recoveryWork: DispatchWorkItem?
    var recoveryEnabled = false
    private let recoveryDirectory: URL
    private var recoveryName = UUID().uuidString + ".json"
    private var recoveryURL: URL { recoveryDirectory.appendingPathComponent(recoveryName) }
    struct Recovery: Codable {
        let version: Int
        let edited: Date
        let scene: SceneDescriptor
    }
    var recoveryError: ((String) -> Void)?
    func scheduleRecovery() {
        guard recoveryEnabled else { return }
        recoveryWork?.cancel()
        guard draft else { clearRecovery(); return }
        let snapshot = scene
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONEncoder().encode(Recovery(version: 1, edited: Date(), scene: snapshot))
                guard data.count <= 1_048_576 else { throw SceneError.invalid("Recovery metadata exceeds 1 MiB.") }
                try FileManager.default.createDirectory(at: self.recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: self.recoveryURL, options: .atomic)
            } catch { self.recoveryError?("Could not save recovery draft: \(error.localizedDescription)") }
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func clearRecovery() {
        recoveryWork?.cancel(); recoveryWork = nil
        try? FileManager.default.removeItem(at: recoveryURL)
    }
    func flushRecovery() {
        recoveryWork?.perform()
        recoveryWork?.cancel()
        recoveryWork = nil
    }
    func readRecovery() throws -> Recovery? {
        guard FileManager.default.fileExists(atPath: recoveryDirectory.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let url = urls.first else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw SceneError.invalid("Recovery draft is too large.") }
        let stored = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: url))
        var nodes = stored.scene.nodes
        for node in stored.scene.allNodes where node.style.effects.contains(where: { $0.id == nil }) {
            _ = SceneTree.edit(node.id, in: &nodes) { siblings, index in
                for effect in siblings[index].style.effects.indices where siblings[index].style.effects[effect].id == nil {
                    siblings[index].style.effects[effect].id = UUID()
                }
            }
        }
        let recovery = Recovery(version: stored.version, edited: stored.edited,
            scene: SceneDescriptor(title: stored.scene.title, nodes: nodes, parameters: stored.scene.parameters,
                                   bindings: stored.scene.bindings, timeline: stored.scene.timeline, canvas: stored.scene.canvas, metadata: stored.scene.metadata, components: stored.scene.components))
        guard recovery.version == 1 else { throw SceneError.invalid("Unsupported recovery version.") }
        try SceneBudget.validate(recovery.scene.nodes)
        _ = try recovery.scene.evaluated()
        for node in recovery.scene.assetNodes {
            for target in ScenePropertyAddress.targets(for: node) {
                let value = try target.value(in: [node])
                guard value.isFinite, try target.range(in: [node]).contains(value) else { throw SceneError.invalid("Recovery contains an invalid layer property.") }
            }
            for url in node.assets {
                guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
                    throw SceneError.invalid("Recovery asset is unavailable: \(url.lastPathComponent). Restore its location and reopen Studio.")
                }
            }
        }
        pendingRecoveryURL = url
        return recovery
    }
    private var pendingRecoveryURL: URL?
    func adoptRecovery() {
        if let url = pendingRecoveryURL { recoveryName = url.lastPathComponent }
        pendingRecoveryURL = nil
    }
    func discardPendingRecovery() {
        if let url = pendingRecoveryURL { try? FileManager.default.removeItem(at: url) }
        pendingRecoveryURL = nil
    }

    init(recoveryDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Idlesse/Studio Recovery")) {
        self.recoveryDirectory = recoveryDirectory
        undoManager.levelsOfUndo = 32
        undoManager.groupsByEvent = false
        undoManager.prepare = { [weak self] undo in
            guard let self, !self.busy, let target = undo ? self.undoTargets.last : self.redoTargets.last else { return false }
            return self.prepareRestore?(target) ?? false
        }
    }
    struct Contents {
        let scene: SceneDescriptor
        let revision: ScenePackageWriter.Revision?
    }
    static func read(_ url: URL) async throws -> Contents {
        let before = try await Task.detached {
            url.pathExtension.lowercased() == "idlesse" ? try ScenePackageWriter.revision(of: url) : nil
        }.value
        let scene = try await LocalSceneSource().resolve(url)
        for node in scene.assetNodes {
            guard case .video(let videoURL) = node.content else { continue }
            let asset = AVURLAsset(url: videoURL)
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard playable, duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else {
                throw SceneError.invalid("That video could not be played.")
            }
        }
        let after = try await Task.detached {
            url.pathExtension.lowercased() == "idlesse" ? try ScenePackageWriter.revision(of: url) : nil
        }.value
        guard before == after else { throw SceneError.invalid("The scene changed while opening. Try again.") }
        try Task.checkCancellation()
        return Contents(scene: scene, revision: after)
    }
    func save(to url: URL, replacing revision: ScenePackageWriter.Revision?) async throws {
        let snapshot = scene
        try await Task.detached(priority: .userInitiated) {
            try ScenePackageWriter.write(snapshot, to: url, replacing: revision)
        }.value
    }
    func record(_ snapshot: Snapshot, name: String) {
        undoTargets.append(snapshot)
        if undoTargets.count > 32 { undoTargets.removeFirst() }
        redoTargets.removeAll()
        register(snapshot, name: name)
        pruneAssets()
    }
    private func register(_ target: Snapshot, name: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            let current = Snapshot(scene: document.scene, selected: document.currentSelection?() ?? 0, draft: document.draft)
            if document.undoManager.isUndoing {
                document.undoTargets.removeLast()
                document.redoTargets.append(current)
            } else {
                document.redoTargets.removeLast()
                document.undoTargets.append(current)
            }
            document.register(current, name: name)
            document.scene = target.scene
            document.draft = target.draft
            document.didRestore?(target)
            document.pruneAssets()
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }
    func clearHistory() {
        undoManager.removeAllActions()
        undoTargets.removeAll()
        redoTargets.removeAll()
    }
    func pruneAssets() {
        let scenes = [scene] + (savedScene.map { [$0] } ?? []) + (undoTargets + redoTargets).map { $0.scene }
        let needed = Set(scenes.flatMap { $0.assetNodes.flatMap { $0.assets } })
        workingAssets.removeAll { url in
            guard !needed.contains(url) else { return false }
            url.stopAccessingSecurityScopedResource()
            return true
        }
    }
    func releaseWorkingAssets() {
        workingAssets.forEach { $0.stopAccessingSecurityScopedResource() }
        workingAssets.removeAll()
    }
    deinit {
        releaseWorkingAssets()
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}

final class SceneUndoManager: UndoManager {
    var prepare: ((Bool) -> Bool)?
    override func undo() { if prepare?(true) == true { super.undo() } }
    override func redo() { if prepare?(false) == true { super.redo() } }
}

/// Text editing keeps its own native history, separate from scene commands.
final class StudioFieldEditor: NSTextView {
    private let textHistory = UndoManager()
    override var undoManager: UndoManager? { textHistory }
    override var allowsUndo: Bool { get { true } set { super.allowsUndo = true } }
}
