import AppKit
import Foundation
import UniformTypeIdentifiers

final class ImageLibrary {
    struct Item {
        let url: URL
        let image: NSImage
    }

    // Every ImageLibrary in the screen saver host shares this seed. That gives multiple
    // ScreenSaverView instances the same shuffled deck when the user asks for the same
    // image on every display, while still producing a fresh order on the next launch.
    private static let sessionShuffleSeed = UInt64.random(in: UInt64.min...UInt64.max)

    private let preferences: IdlessePreferences
    private var imageURLs: [URL] = []
    private var playbackOrder: [URL] = []
    private var cursor = 0
    private var cycle = 0
    private var folderURL: URL?
    private var securityScopeStarted = false

    var playbackOffset = 0
    private(set) var lastError: String?

    init(preferences: IdlessePreferences) {
        self.preferences = preferences
    }

    var count: Int { imageURLs.count }

    func reload() {
        stopAccess()
        imageURLs.removeAll()
        playbackOrder.removeAll()
        cursor = 0
        cycle = 0
        lastError = nil

        let folder: URL
        do {
            guard let resolved = try preferences.resolveFolder() else {
                lastError = "Choose a folder in Options…"
                return
            }
            folder = resolved
        } catch {
            lastError = "Idlesse could not reopen the selected folder. Choose it again in Options…"
            return
        }

        folderURL = folder
        securityScopeStarted = folder.startAccessingSecurityScopedResource()

        do {
            if preferences.includeSubfolders {
                try loadRecursively(from: folder)
            } else {
                try loadTopLevel(from: folder)
            }
        } catch {
            lastError = "Idlesse could not read \(folder.lastPathComponent). Choose the folder again in Options…"
            return
        }

        imageURLs.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        rebuildPlaybackOrder(avoiding: nil)

        if imageURLs.isEmpty {
            lastError = "No images found in \(folder.lastPathComponent)."
        }
    }

    func next(excluding currentURL: URL?) -> Item? {
        guard !playbackOrder.isEmpty else { return nil }

        var examined = 0
        while examined < imageURLs.count {
            if cursor >= playbackOrder.count {
                cycle += 1
                rebuildPlaybackOrder(avoiding: currentURL)
            }

            let url = playbackOrder[cursor]
            cursor += 1
            examined += 1

            if let image = NSImage(contentsOf: url) {
                return Item(url: url, image: image)
            }
        }

        lastError = "Idlesse found image files, but macOS could not open them."
        return nil
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
        playbackOrder = imageURLs

        if preferences.shuffle {
            let cycleSeed = Self.sessionShuffleSeed &+ UInt64(cycle) &* 0x9E3779B97F4A7C15
            playbackOrder.sort { lhs, rhs in
                let left = stableScore(for: lhs, seed: cycleSeed)
                let right = stableScore(for: rhs, seed: cycleSeed)
                if left == right {
                    return lhs.path < rhs.path
                }
                return left < right
            }
        }

        if playbackOrder.count > 1 {
            let offset = positiveModulo(playbackOffset, playbackOrder.count)
            if offset > 0 {
                playbackOrder = Array(playbackOrder[offset...] + playbackOrder[..<offset])
            }

            // Keep the shuffle a true bag: every image appears exactly once per cycle.
            // If a new cycle would immediately repeat the previous image, swap positions
            // instead of skipping that item and accidentally omitting it from the cycle.
            if let currentURL, playbackOrder.first == currentURL {
                playbackOrder.swapAt(0, 1)
            }
        }

        cursor = 0
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

    private func loadTopLevel(from folder: URL) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        imageURLs.append(contentsOf: urls.filter(isImageFile))
    }

    private func loadRecursively(from folder: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        for case let url as URL in enumerator where isImageFile(url) {
            imageURLs.append(url)
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}
