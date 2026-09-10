import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    struct ThumbnailRevision: Equatable {
        let source: PosterRevision
        let sidecarPath: String?
        let sidecarDate: Date?
        let sidecarSize: Int?
    }

    final class ThumbnailCache {
        struct Entry {
            let revision: ThumbnailRevision
            let image: NSImage?
            let bytes: Int
        }
        let lock = NSLock()
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var budget: Int
        let maxEntries: Int
        var used = 0

        init(budget: Int, maxEntries: Int) {
            self.budget = budget
            self.maxEntries = maxEntries
        }

        func latest(_ id: String) -> NSImage? {
            lock.lock(); defer { lock.unlock() }
            return entries[id]?.image
        }

        func lookup(_ id: String, revision: ThumbnailRevision) -> (found: Bool, image: NSImage?) {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[id], entry.revision == revision else { return (false, nil) }
            order.removeAll { $0 == id }
            order.append(id)
            return (true, entry.image)
        }

        func insert(_ image: NSImage?, id: String, revision: ThumbnailRevision, bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            if let old = entries.removeValue(forKey: id) { used -= old.bytes }
            order.removeAll { $0 == id }
            guard bytes <= budget else { return }
            while (used + bytes > budget || order.count >= maxEntries), let first = order.first {
                order.removeFirst()
                if let removed = entries.removeValue(forKey: first) { used -= removed.bytes }
            }
            entries[id] = Entry(revision: revision, image: image, bytes: bytes)
            order.append(id)
            used += bytes
        }

        func remove(_ id: String) {
            lock.lock(); defer { lock.unlock() }
            if let old = entries.removeValue(forKey: id) { used -= old.bytes }
            order.removeAll { $0 == id }
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
            order.removeAll()
            used = 0
        }

        func byteCount() -> Int {
            lock.lock(); defer { lock.unlock() }
            return used
        }
    }

    final class ThumbnailOperation: Operation, @unchecked Sendable {
        let body: (ThumbnailOperation) -> Void
        let generatorLock = NSLock()
        var generator: AVAssetImageGenerator?

        init(body: @escaping (ThumbnailOperation) -> Void) {
            self.body = body
            super.init()
        }
        override func main() {
            if !isCancelled { body(self) }
        }
        func installGenerator(_ value: AVAssetImageGenerator) {
            generatorLock.lock()
            generator = value
            let cancelled = isCancelled
            generatorLock.unlock()
            if cancelled { value.cancelAllCGImageGeneration() }
        }
        override func cancel() {
            super.cancel()
            generatorLock.lock()
            generator?.cancelAllCGImageGeneration()
            generatorLock.unlock()
        }
    }
}