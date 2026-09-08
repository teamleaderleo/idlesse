import AppKit
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
    static let moduleIdentifier = "com.teamleaderleo.idlesse"
    static let shared = IdlessePreferences()

    private enum LegacyKey {
        static let folderBookmark = "folderBookmark"
        static let folderDisplayPath = "folderDisplayPath"
        static let displayDuration = "displayDuration"
        static let transitionDuration = "transitionDuration"
        static let scalingMode = "scalingMode"
        static let backgroundColor = "backgroundColor"
        static let multiDisplayMode = "multiDisplayMode"
        static let playbackOrder = "playbackOrder"
        static let shuffle = "shuffle"
        static let includeSubfolders = "includeSubfolders"
    }

    private var settings: IdlesseStoredSettings

    private init() {
        if let stored = IdlesseSettingsFile.read() {
            settings = stored
            return
        }

        let migration = Self.readLegacySettings()
        settings = migration.settings

        // The old preview harness already wrote ScreenSaverDefaults. Migrate those
        // values once from the companion-app process. The saver process deliberately
        // does not create an empty shared file before the app gets a chance to migrate.
        if !IdlesseSettingsFile.isSaverProcess, migration.shouldMigrate {
            try? IdlesseSettingsFile.write(settings)
        }
    }

    var folderDisplayPath: String? {
        settings.folderDisplayPath
    }

    var displayDuration: TimeInterval {
        get { max(1, settings.displayDuration) }
        set { settings.displayDuration = max(1, newValue) }
    }

    var transitionDuration: TimeInterval {
        get { max(0, settings.transitionDuration) }
        set { settings.transitionDuration = min(30, max(0, newValue)) }
    }

    var scalingMode: IdlesseScalingMode {
        get { settings.scalingMode }
        set { settings.scalingMode = newValue }
    }

    var backgroundColor: NSColor {
        get {
            let values = settings.backgroundRGBA
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
            settings.backgroundRGBA = [
                Double(color.redComponent),
                Double(color.greenComponent),
                Double(color.blueComponent),
                Double(color.alphaComponent),
            ]
        }
    }

    var multiDisplayMode: IdlesseMultiDisplayMode {
        get { settings.multiDisplayMode }
        set { settings.multiDisplayMode = newValue }
    }

    var playbackOrder: IdlessePlaybackOrder {
        get { settings.playbackOrder }
        set { settings.playbackOrder = newValue }
    }

    var includeSubfolders: Bool {
        get { settings.includeSubfolders }
        set { settings.includeSubfolders = newValue }
    }

    /// Re-read the shared file. The companion app and the sandboxed saver point at
    /// the same underlying file through two different paths.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let stored = IdlesseSettingsFile.read() else { return false }
        let changed = stored != settings
        settings = stored
        return changed
    }

    /// Save a document-scoped security bookmark. Its owner document is the shared
    /// Idlesse settings file, which both Idlesse.app and legacyScreenSaver can read.
    /// That makes the folder grant transferable to the sandboxed saver instead of
    /// tying it to the companion app's signing identity.
    func saveFolder(_ url: URL) throws {
        // A document-scoped bookmark needs an existing owner document.
        try IdlesseSettingsFile.write(settings)

        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: IdlesseSettingsFile.runtimeURL
        )

        settings.folderBookmark = bookmark
        settings.folderDisplayPath = url.path
    }

    func resolveFolder() throws -> URL? {
        guard let bookmark = settings.folderBookmark else {
            return nil
        }

        var isStale = false

        // Current format: document-scoped bookmark owned by settings.json.
        if let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: IdlesseSettingsFile.runtimeURL,
            bookmarkDataIsStale: &isStale
        ) {
            if isStale, !IdlesseSettingsFile.isSaverProcess {
                try? saveFolder(url)
                try? save()
            }
            return url
        }

        // Compatibility with bookmarks written by early prototypes. These were
        // app-scoped and may still resolve inside Idlesse.app, allowing the user to
        // keep previewing until they reselect the folder and create a transferable one.
        isStale = false
        let legacyURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if !IdlesseSettingsFile.isSaverProcess {
            try? saveFolder(legacyURL)
            try? save()
        }

        return legacyURL
    }

    func save() throws {
        try IdlesseSettingsFile.write(settings)
    }

    private static func readLegacySettings() -> (settings: IdlesseStoredSettings, shouldMigrate: Bool) {
        var result = IdlesseStoredSettings()
        guard let defaults = ScreenSaverDefaults(forModuleWithName: moduleIdentifier) else {
            return (result, false)
        }

        let keys = [
            LegacyKey.folderBookmark,
            LegacyKey.folderDisplayPath,
            LegacyKey.displayDuration,
            LegacyKey.transitionDuration,
            LegacyKey.scalingMode,
            LegacyKey.backgroundColor,
            LegacyKey.multiDisplayMode,
            LegacyKey.playbackOrder,
            LegacyKey.shuffle,
            LegacyKey.includeSubfolders,
        ]
        let shouldMigrate = keys.contains { defaults.object(forKey: $0) != nil }

        result.folderBookmark = defaults.data(forKey: LegacyKey.folderBookmark)
        result.folderDisplayPath = defaults.string(forKey: LegacyKey.folderDisplayPath)

        if let value = defaults.object(forKey: LegacyKey.displayDuration) as? NSNumber {
            result.displayDuration = max(1, value.doubleValue)
        }
        if let value = defaults.object(forKey: LegacyKey.transitionDuration) as? NSNumber {
            result.transitionDuration = min(30, max(0, value.doubleValue))
        }
        if let raw = defaults.string(forKey: LegacyKey.scalingMode),
           let value = IdlesseScalingMode(rawValue: raw) {
            result.scalingMode = value
        }
        if let values = defaults.array(forKey: LegacyKey.backgroundColor)?
            .compactMap({ ($0 as? NSNumber)?.doubleValue }), values.count >= 4 {
            result.backgroundRGBA = Array(values.prefix(4))
        }
        if let raw = defaults.string(forKey: LegacyKey.multiDisplayMode),
           let value = IdlesseMultiDisplayMode(rawValue: raw) {
            result.multiDisplayMode = value
        }

        if let raw = defaults.string(forKey: LegacyKey.playbackOrder),
           let value = IdlessePlaybackOrder(rawValue: raw) {
            result.playbackOrder = value
        } else if let legacyShuffle = defaults.object(forKey: LegacyKey.shuffle) as? NSNumber {
            result.playbackOrder = legacyShuffle.boolValue ? .random : .nameAscending
        }

        if let value = defaults.object(forKey: LegacyKey.includeSubfolders) as? NSNumber {
            result.includeSubfolders = value.boolValue
        }

        return (result, shouldMigrate)
    }
}
