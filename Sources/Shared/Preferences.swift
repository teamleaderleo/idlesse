import AppKit
import Darwin
import Foundation
import ScreenSaver

enum IdlesseScalingMode: String, CaseIterable, Codable {
    case fit
    case fill
    case actual

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .actual: return "Actual Size"
        }
    }
}

enum IdlesseMultiDisplayMode: String, CaseIterable, Codable {
    case same
    case different

    var title: String {
        switch self {
        case .same: return "Same image on every display"
        case .different: return "Different image on each display"
        }
    }
}

enum IdlessePlaybackOrder: String, CaseIterable, Codable {
    case random
    case nameAscending
    case nameDescending
    case createdOldest
    case createdNewest
    case modifiedOldest
    case modifiedNewest

    var title: String {
        switch self {
        case .random: return "Random"
        case .nameAscending: return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .createdOldest: return "Date created (oldest first)"
        case .createdNewest: return "Date created (newest first)"
        case .modifiedOldest: return "Date modified (oldest first)"
        case .modifiedNewest: return "Date modified (newest first)"
        }
    }
}

final class IdlessePreferences {
    enum Role {
        case companion
        case saver
        case memory
    }

    static let moduleIdentifier = "com.teamleaderleo.idlesse"
    static let companion = IdlessePreferences(role: .companion)
    static let saver = IdlessePreferences(role: .saver)

    static func memory() -> IdlessePreferences {
        IdlessePreferences(role: .memory)
    }

    private struct StoredSettings: Codable, Equatable {
        var version = 1
        var folderBookmark: Data?
        var folderDisplayPath: String?
        var displayDuration: Double = 300
        var transitionDuration: Double = 2
        var scalingMode: IdlesseScalingMode = .fit
        var backgroundColor: [Double] = [0, 0, 0, 1]
        var multiDisplayMode: IdlesseMultiDisplayMode = .same
        var playbackOrder: IdlessePlaybackOrder = .random
        var includeSubfolders = true

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
            folderDisplayPath = try container.decodeIfPresent(String.self, forKey: .folderDisplayPath)
            displayDuration = try container.decodeIfPresent(Double.self, forKey: .displayDuration) ?? 300
            transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 2
            scalingMode = try container.decodeIfPresent(IdlesseScalingMode.self, forKey: .scalingMode) ?? .fit
            backgroundColor = try container.decodeIfPresent([Double].self, forKey: .backgroundColor) ?? [0, 0, 0, 1]
            multiDisplayMode = try container.decodeIfPresent(IdlesseMultiDisplayMode.self, forKey: .multiDisplayMode) ?? .same
            playbackOrder = try container.decodeIfPresent(IdlessePlaybackOrder.self, forKey: .playbackOrder) ?? .random
            includeSubfolders = try container.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? true
        }
    }

    private let role: Role
    private let settingsURL: URL?
    private var stored: StoredSettings
    private var lastLoadedModificationDate: Date?

    private init(role: Role) {
        self.role = role
        self.settingsURL = Self.settingsURL(for: role)

        if let settingsURL,
           let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            self.stored = decoded
            self.lastLoadedModificationDate = try? settingsURL
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        } else {
            self.stored = Self.legacySettings(includeFolder: role == .saver)
        }
    }

    var isCompanion: Bool { role == .companion }

    var folderDisplayPath: String? {
        stored.folderDisplayPath
    }

    var displayDuration: TimeInterval {
        get { max(1, stored.displayDuration) }
        set { stored.displayDuration = max(1, newValue) }
    }

    var transitionDuration: TimeInterval {
        get { max(0, stored.transitionDuration) }
        set { stored.transitionDuration = min(30, max(0, newValue)) }
    }

    var scalingMode: IdlesseScalingMode {
        get { stored.scalingMode }
        set { stored.scalingMode = newValue }
    }

    var backgroundColor: NSColor {
        get {
            let values = stored.backgroundColor
            guard values.count >= 4 else { return .black }
            return NSColor(
                srgbRed: CGFloat(values[0]),
                green: CGFloat(values[1]),
                blue: CGFloat(values[2]),
                alpha: CGFloat(values[3])
            )
        }
        set {
            let color = newValue.usingColorSpace(.sRGB) ?? .black
            stored.backgroundColor = [
                Double(color.redComponent),
                Double(color.greenComponent),
                Double(color.blueComponent),
                Double(color.alphaComponent),
            ]
        }
    }

    var multiDisplayMode: IdlesseMultiDisplayMode {
        get { stored.multiDisplayMode }
        set { stored.multiDisplayMode = newValue }
    }

    var playbackOrder: IdlessePlaybackOrder {
        get { stored.playbackOrder }
        set { stored.playbackOrder = newValue }
    }

    var includeSubfolders: Bool {
        get { stored.includeSubfolders }
        set { stored.includeSubfolders = newValue }
    }

    /// Store a document-scoped security bookmark owned by the shared settings file.
    /// Both the companion app and legacyScreenSaver can resolve it because both have
    /// access to that owner document.
    func saveFolder(_ url: URL) throws {
        guard let settingsURL else {
            stored.folderDisplayPath = url.path
            stored.folderBookmark = nil
            return
        }

        try ensureSettingsDocumentExists()

        do {
            stored.folderBookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: settingsURL
            )
        } catch {
            // Fallback for hosts that reject a document-scoped bookmark. This is
            // intentionally kept as a compatibility experiment while Tahoe behavior
            // is still being verified on real machines.
            stored.folderBookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        stored.folderDisplayPath = url.path
    }

    func resolveFolder() throws -> URL? {
        guard let bookmark = stored.folderBookmark else { return nil }

        if let settingsURL {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: settingsURL,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    try? saveFolder(url)
                    try? save()
                }
                return url
            }
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    func save() throws {
        guard role != .memory else { return }
        try writeStoredSettings(stored)
    }

    func reload() {
        guard let settingsURL,
              let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            return
        }

        stored = decoded
        lastLoadedModificationDate = try? settingsURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    @discardableResult
    func reloadIfChanged() -> Bool {
        guard let settingsURL,
              let modified = try? settingsURL
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
              modified != lastLoadedModificationDate else {
            return false
        }

        let before = stored
        reload()
        return before != stored
    }

    private func ensureSettingsDocumentExists() throws {
        guard let settingsURL else { return }
        if FileManager.default.fileExists(atPath: settingsURL.path) { return }
        try writeStoredSettings(stored)
    }

    private func writeStoredSettings(_ settings: StoredSettings) throws {
        guard let settingsURL else { return }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)

        lastLoadedModificationDate = try? settingsURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private static func settingsURL(for role: Role) -> URL? {
        if let override = ProcessInfo.processInfo.environment["IDLESSE_SETTINGS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        switch role {
        case .memory:
            return nil

        case .saver:
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/Idlesse", isDirectory: true)
                .appendingPathComponent("idlesse-settings.json")

        case .companion:
            return realUserHomeDirectory
                .appendingPathComponent(
                    "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data",
                    isDirectory: true
                )
                .appendingPathComponent("Library/Application Support/Idlesse", isDirectory: true)
                .appendingPathComponent("idlesse-settings.json")
        }
    }

    private static var realUserHomeDirectory: URL {
        if let passwd = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func legacySettings(includeFolder: Bool) -> StoredSettings {
        var settings = StoredSettings()
        guard let defaults = ScreenSaverDefaults(forModuleWithName: moduleIdentifier) else {
            return settings
        }

        if defaults.object(forKey: "displayDuration") != nil {
            settings.displayDuration = max(1, defaults.double(forKey: "displayDuration"))
        }

        if defaults.object(forKey: "transitionDuration") != nil {
            settings.transitionDuration = max(0, defaults.double(forKey: "transitionDuration"))
        }

        if let raw = defaults.string(forKey: "scalingMode"),
           let mode = IdlesseScalingMode(rawValue: raw) {
            settings.scalingMode = mode
        }

        if let values = defaults.array(forKey: "backgroundColor")?
            .compactMap({ ($0 as? NSNumber)?.doubleValue }),
           values.count >= 4 {
            settings.backgroundColor = Array(values.prefix(4))
        }

        if let raw = defaults.string(forKey: "multiDisplayMode"),
           let mode = IdlesseMultiDisplayMode(rawValue: raw) {
            settings.multiDisplayMode = mode
        }

        if let raw = defaults.string(forKey: "playbackOrder"),
           let order = IdlessePlaybackOrder(rawValue: raw) {
            settings.playbackOrder = order
        } else if let shuffle = (defaults.object(forKey: "shuffle") as? NSNumber)?.boolValue {
            settings.playbackOrder = shuffle ? .random : .nameAscending
        }

        if defaults.object(forKey: "includeSubfolders") != nil {
            settings.includeSubfolders = defaults.bool(forKey: "includeSubfolders")
        }

        if includeFolder {
            settings.folderBookmark = defaults.data(forKey: "folderBookmark")
            settings.folderDisplayPath = defaults.string(forKey: "folderDisplayPath")
        }

        return settings
    }
}
