import AppKit
import Foundation
import UniformTypeIdentifiers

final class ImageLibrary {
    struct Item {
        let url: URL
        let image: NSImage
    }

    private let preferences: IdlessePreferences
    private var imageURLs: [URL] = []
    private var playbackOrder: [URL] = []
    private var cursor = 0
    private var folderURL: URL?
    private var securityScopeStarted = false

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
        rebuildPlaybackOrder()

        if imageURLs.isEmpty {
            lastError = "No images found in \(folder.lastPathComponent)."
        }
    }

    func next(excluding currentURL: URL?) -> Item? {
        guard !playbackOrder.isEmpty else { return nil }

        var attempts = 0
        while attempts < playbackOrder.count {
            if cursor >= playbackOrder.count {
                if preferences.shuffle {
                    playbackOrder.shuffle()
                }
                cursor = 0
            }

            let url = playbackOrder[cursor]
            cursor += 1
            attempts += 1

            if playbackOrder.count > 1, url == currentURL {
                continue
            }

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

    private func rebuildPlaybackOrder() {
        playbackOrder = imageURLs
        if preferences.shuffle {
            playbackOrder.shuffle()
        }
        cursor = 0
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
