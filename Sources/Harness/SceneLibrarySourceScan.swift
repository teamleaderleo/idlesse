import Foundation

extension SceneLibraryController {
    nonisolated static func scanSource(_ root: URL) throws -> [SceneLibraryStore.SourceEntry] {
        let maxSourceScanItems = 20_000
        let sourceNativeExtensions: Set<String> = ["idlesse", "jpg", "jpeg", "png", "heic", "mp4", "mov"]
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw NSError(domain: "IdlesseLibrary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The Source folder could not be scanned."])
        }
        var visited = 0
        var entries: [SceneLibraryStore.SourceEntry] = []
        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            guard visited <= maxSourceScanItems else {
                throw NSError(domain: "IdlesseLibrary", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The Source contains more than 20,000 items. Choose a narrower folder."])
            }
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
            let ext = candidate.pathExtension.lowercased()
            if values.isDirectory == true {
                if ext == "idlesse" {
                    let relative = try SceneLibraryStore.relativePath(from: root, to: candidate)
                    entries.append(.init(relativeMediaPath: relative,
                        title: candidate.deletingPathExtension().lastPathComponent, mediaType: "scene"))
                    enumerator.skipDescendants()
                }
            } else if sourceNativeExtensions.contains(ext) {
                let relative = try SceneLibraryStore.relativePath(from: root, to: candidate)
                let type = ext == "idlesse" ? "scene" : (["mp4", "mov"].contains(ext) ? "video" : "image")
                entries.append(.init(relativeMediaPath: relative,
                    title: candidate.deletingPathExtension().lastPathComponent, mediaType: type))
            }
            guard entries.count <= SceneLibraryStore.maxSourceEntries else {
                throw NSError(domain: "IdlesseLibrary", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The Library supports up to 4096 source-backed entries."])
            }
        }
        if let enumerationError { throw enumerationError }
        return entries.sorted { $0.relativeMediaPath.localizedStandardCompare($1.relativeMediaPath) == .orderedAscending }
    }
}
