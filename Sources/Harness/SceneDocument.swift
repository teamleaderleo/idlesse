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
    var draft = false
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

    init() {
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
        for node in scene.nodes {
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
        let needed = Set(scenes.flatMap { $0.nodes.compactMap { $0.assetURL } })
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
