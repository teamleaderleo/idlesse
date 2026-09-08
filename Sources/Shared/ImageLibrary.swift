import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ImageLibrary {
    struct Item {
        let url: URL
        let image: NSImage
    }

    private struct Entry: Equatable {
        let url: URL
        let creationDate: Date?
        let modificationDate: Date?
    }

    // Every ImageLibrary in the screen saver host shares this seed. That gives multiple
    // ScreenSaverView instances the same shuffled deck when the user asks for the same
    // image on every display, while still producing a fresh order on the next launch.
    private static let sessionShuffleSeed = UInt64.random(in: UInt64.min...UInt64.max)

    private let preferences: IdlessePreferences
    private var imageEntries: [Entry] = []
    private var playbackOrder: [URL] = []
    private var cursor = 0
    private var cycle = 0
    private var folderURL: URL?
    private var securityScopeStarted = false

    var displayPixelSize = CGSize(width: 1920, height: 1080)
    var playbackOffset = 0
    private(set) var lastError: String?

    init(preferences: IdlessePreferences) {
        self.preferences = preferences
    }

    var count: Int { imageEntries.count }

    func reload() {
        stopAccess()
        imageEntries.removeAll()
        playbackOrder.removeAll()
        cursor = 0
        cycle = 0
        lastError = nil

        let folder: URL
        do {
            guard let resolved = try preferences.resolveFolder() else {
                lastError = "Choose a folder in Idlesse Settings."
                return
            }
            folder = resolved
        } catch {
            lastError = "Idlesse could not reopen the selected folder. Choose it again in Idlesse Settings."
            return
        }

        folderURL = folder
        securityScopeStarted = folder.startAccessingSecurityScopedResource()

        do {
            imageEntries = try scanFolder(folder)
        } catch {
            lastError = "Idlesse could not read \(folder.lastPathComponent). Choose the folder again in Idlesse Settings."
            return
        }

        rebuildPlaybackOrder(avoiding: nil)
        updateEmptyState(for: folder)
    }

    /// Re-scan the selected folder while the saver is running. Returns true when files
    /// were added, removed, or their creation/modification metadata changed.
    func refreshIfChanged(currentURL: URL?) -> Bool {
        guard let folderURL else { return false }

        do {
            let refreshed = try scanFolder(folderURL)
            guard refreshed != imageEntries else { return false }

            imageEntries = refreshed
            cycle += 1
            rebuildPlaybackOrder(avoiding: currentURL)
            lastError = nil
            updateEmptyState(for: folderURL)
            return true
        } catch {
            lastError = "Idlesse could not refresh \(folderURL.lastPathComponent)."
            return false
        }
    }

    func next(excluding currentURL: URL?) -> Item? {
        guard !playbackOrder.isEmpty else { return nil }

        var examined = 0
        while examined < imageEntries.count {
            if cursor >= playbackOrder.count {
                cycle += 1
                rebuildPlaybackOrder(avoiding: currentURL)
            }

            let url = playbackOrder[cursor]
            cursor += 1
            examined += 1

            if let image = autoreleasepool(invoking: {
                DisplayImageDecoder.load(url, target: displayPixelSize, mode: preferences.scalingMode)
            }) {
                return Item(url: url, image: image)
            }
        }

        lastError = "Idlesse found image files, but macOS could not open them."
        return nil
    }

    func releaseContents() {
        imageEntries = []
        playbackOrder = []
        stopAccess()
    }

    func stopAccess() {
        if securityScopeStarted, let folderURL {
            folderURL.stopAccessingSecurityScopedResource()
        }
        securityScopeStarted = false
        folderURL = nil
    }

    deinit {
        stopAccess()
    }

    private func rebuildPlaybackOrder(avoiding currentURL: URL?) {
        switch preferences.playbackOrder {
        case .random:
            let cycleSeed = Self.sessionShuffleSeed &+ UInt64(cycle) &* 0x9E3779B97F4A7C15
            // Hash each path once, rather than twice per sort comparison.
            // Preserve the existing ordering so displays still share one deck.
            playbackOrder = imageEntries.map { entry in
                (url: entry.url, score: stableScore(for: entry.url, seed: cycleSeed))
            }.sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.url.path < rhs.url.path
                }
                return lhs.score < rhs.score
            }.map(\.url)

        case .nameAscending:
            playbackOrder = imageEntries.map(\.url).sorted(by: compareNamesAscending)

        case .nameDescending:
            playbackOrder = imageEntries.map(\.url).sorted { compareNamesAscending($1, $0) }

        case .createdOldest:
            playbackOrder = sortedByDate(\.creationDate, ascending: true)

        case .createdNewest:
            playbackOrder = sortedByDate(\.creationDate, ascending: false)

        case .modifiedOldest:
            playbackOrder = sortedByDate(\.modificationDate, ascending: true)

        case .modifiedNewest:
            playbackOrder = sortedByDate(\.modificationDate, ascending: false)
        }

        if playbackOrder.count > 1 {
            let offset = positiveModulo(playbackOffset, playbackOrder.count)
            if offset > 0 {
                playbackOrder = Array(playbackOrder[offset...] + playbackOrder[..<offset])
            }

            // A random cycle should never begin with the image that just ended the
            // previous cycle. Swap rather than skip so the shuffle remains a true bag.
            if preferences.playbackOrder == .random,
               let currentURL,
               playbackOrder.first == currentURL {
                playbackOrder.swapAt(0, 1)
            }
        }

        cursor = 0
    }

    private func sortedByDate(_ keyPath: KeyPath<Entry, Date?>, ascending: Bool) -> [URL] {
        imageEntries.sorted { lhs, rhs in
            let left = lhs[keyPath: keyPath]
            let right = rhs[keyPath: keyPath]

            switch (left, right) {
            case let (left?, right?) where left != right:
                return ascending ? left < right : left > right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return compareNamesAscending(lhs.url, rhs.url)
            }
        }.map(\.url)
    }

    private func compareNamesAscending(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private func stableScore(for url: URL, seed: UInt64) -> UInt64 {
        var hash = 1469598103934665603 ^ seed
        for byte in url.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        let result = value % modulus
        return result >= 0 ? result : result + modulus
    }

    private func scanFolder(_ folder: URL) throws -> [Entry] {
        let entries: [Entry]
        if preferences.includeSubfolders {
            entries = try scanRecursively(from: folder)
        } else {
            entries = try scanTopLevel(from: folder)
        }

        return entries.sorted { compareNamesAscending($0.url, $1.url) }
    }

    private func scanTopLevel(from folder: URL) throws -> [Entry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap(makeEntry)
    }

    private func scanRecursively(from folder: URL) throws -> [Entry] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            if let entry = makeEntry(url) {
                entries.append(entry)
            }
        }
        return entries
    }

    private var resourceKeys: [URLResourceKey] {
        [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
    }

    private func makeEntry(_ url: URL) -> Entry? {
        guard isImageFile(url) else { return nil }

        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        if values?.isRegularFile == false { return nil }

        return Entry(
            url: url,
            creationDate: values?.creationDate,
            modificationDate: values?.contentModificationDate
        )
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private func updateEmptyState(for folder: URL) {
        if imageEntries.isEmpty {
            lastError = "No images found in \(folder.lastPathComponent)."
        }
    }
}
