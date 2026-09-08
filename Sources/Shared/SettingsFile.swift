import Darwin
import Foundation

struct IdlesseStoredSettings: Codable, Equatable {
    var schemaVersion: Int = 1
    var folderBookmark: Data?
    var folderDisplayPath: String?
    var displayDuration: Double = 300
    var transitionDuration: Double = 2
    var scalingMode: IdlesseScalingMode = .fit
    var backgroundRGBA: [Double] = [0, 0, 0, 1]
    var multiDisplayMode: IdlesseMultiDisplayMode = .same
    var playbackOrder: IdlessePlaybackOrder = .random
    var includeSubfolders: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case folderBookmark
        case folderDisplayPath
        case displayDuration
        case transitionDuration
        case scalingMode
        case backgroundRGBA
        case multiDisplayMode
        case playbackOrder
        case includeSubfolders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderDisplayPath = try container.decodeIfPresent(String.self, forKey: .folderDisplayPath)
        displayDuration = try container.decodeIfPresent(Double.self, forKey: .displayDuration) ?? 300
        transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 2
        scalingMode = try container.decodeIfPresent(IdlesseScalingMode.self, forKey: .scalingMode) ?? .fit
        backgroundRGBA = try container.decodeIfPresent([Double].self, forKey: .backgroundRGBA) ?? [0, 0, 0, 1]
        multiDisplayMode = try container.decodeIfPresent(IdlesseMultiDisplayMode.self, forKey: .multiDisplayMode) ?? .same
        playbackOrder = try container.decodeIfPresent(IdlessePlaybackOrder.self, forKey: .playbackOrder) ?? .random
        includeSubfolders = try container.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? true
    }
}

enum IdlesseSettingsFile {
    private static let supportPath = "Library/Application Support/Idlesse/settings.json"
    private static let legacySaverContainer = "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data"

    /// A sandboxed companion app sees its own container as NSHomeDirectory(). Use
    /// the account database to recover the real user home before addressing the
    /// legacyScreenSaver container.
    private static var realUserHomeDirectory: URL {
        if let passwd = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var appURL: URL {
        realUserHomeDirectory
            .appendingPathComponent(legacySaverContainer, isDirectory: true)
            .appendingPathComponent(supportPath)
    }

    static var saverURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(supportPath)
    }

    static var isSaverProcess: Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        return home.contains("/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data")
    }

    static var runtimeURL: URL {
        isSaverProcess ? saverURL : appURL
    }

    static func read() -> IdlesseStoredSettings? {
        guard let data = try? Data(contentsOf: runtimeURL) else { return nil }
        return try? JSONDecoder().decode(IdlesseStoredSettings.self, from: data)
    }

    static func write(_ settings: IdlesseStoredSettings) throws {
        let url = runtimeURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
