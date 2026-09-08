import AppKit
import Foundation
import ScreenSaver

enum IdlesseScalingMode: String, CaseIterable {
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

enum IdlesseMultiDisplayMode: String, CaseIterable {
    case same
    case different

    var title: String {
        switch self {
        case .same: return "Same image on every display"
        case .different: return "Different image on each display"
        }
    }
}

final class IdlessePreferences {
    static let moduleIdentifier = "com.teamleaderleo.idlesse"
    static let shared = IdlessePreferences()

    private enum Key {
        static let folderBookmark = "folderBookmark"
        static let folderDisplayPath = "folderDisplayPath"
        static let displayDuration = "displayDuration"
        static let transitionDuration = "transitionDuration"
        static let scalingMode = "scalingMode"
        static let backgroundColor = "backgroundColor"
        static let multiDisplayMode = "multiDisplayMode"
        static let shuffle = "shuffle"
        static let includeSubfolders = "includeSubfolders"
    }

    let defaults: UserDefaults

    private init() {
        if let saverDefaults = ScreenSaverDefaults(forModuleWithName: Self.moduleIdentifier) {
            defaults = saverDefaults
        } else {
            defaults = .standard
        }

        defaults.register(defaults: [
            Key.displayDuration: 300.0,
            Key.transitionDuration: 2.0,
            Key.scalingMode: IdlesseScalingMode.fit.rawValue,
            Key.backgroundColor: [0.0, 0.0, 0.0, 1.0],
            Key.multiDisplayMode: IdlesseMultiDisplayMode.same.rawValue,
            Key.shuffle: true,
            Key.includeSubfolders: true,
        ])
    }

    var folderDisplayPath: String? {
        defaults.string(forKey: Key.folderDisplayPath)
    }

    var displayDuration: TimeInterval {
        get { max(1, defaults.double(forKey: Key.displayDuration)) }
        set { defaults.set(max(1, newValue), forKey: Key.displayDuration) }
    }

    var transitionDuration: TimeInterval {
        get { max(0, defaults.double(forKey: Key.transitionDuration)) }
        set { defaults.set(min(30, max(0, newValue)), forKey: Key.transitionDuration) }
    }

    var scalingMode: IdlesseScalingMode {
        get {
            guard let raw = defaults.string(forKey: Key.scalingMode),
                  let mode = IdlesseScalingMode(rawValue: raw) else {
                return .fit
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.scalingMode) }
    }

    var backgroundColor: NSColor {
        get {
            let values = defaults.array(forKey: Key.backgroundColor)?
                .compactMap { ($0 as? NSNumber)?.doubleValue }

            guard let values, values.count >= 4 else { return .black }
            return NSColor(
                srgbRed: CGFloat(values[0]),
                green: CGFloat(values[1]),
                blue: CGFloat(values[2]),
                alpha: CGFloat(values[3])
            )
        }
        set {
            let color = newValue.usingColorSpace(.sRGB) ?? .black
            defaults.set([
                Double(color.redComponent),
                Double(color.greenComponent),
                Double(color.blueComponent),
                Double(color.alphaComponent),
            ], forKey: Key.backgroundColor)
        }
    }

    var multiDisplayMode: IdlesseMultiDisplayMode {
        get {
            guard let raw = defaults.string(forKey: Key.multiDisplayMode),
                  let mode = IdlesseMultiDisplayMode(rawValue: raw) else {
                return .same
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.multiDisplayMode) }
    }

    var shuffle: Bool {
        get { defaults.bool(forKey: Key.shuffle) }
        set { defaults.set(newValue, forKey: Key.shuffle) }
    }

    var includeSubfolders: Bool {
        get { defaults.bool(forKey: Key.includeSubfolders) }
        set { defaults.set(newValue, forKey: Key.includeSubfolders) }
    }

    func saveFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        defaults.set(bookmark, forKey: Key.folderBookmark)
        defaults.set(url.path, forKey: Key.folderDisplayPath)
        defaults.synchronize()
    }

    func resolveFolder() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Key.folderBookmark) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            try? saveFolder(url)
        }

        return url
    }

    func save() {
        defaults.synchronize()
    }
}
