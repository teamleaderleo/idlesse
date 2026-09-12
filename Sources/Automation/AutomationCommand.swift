import Foundation

enum AutomationAction: String, Codable, CaseIterable, Sendable {
    case applyScene
    case applyCollection
    case applyAmbientSet
    case setVariant
    case next
    case previous
    case pause
    case resume
    case togglePause
    case pauseFor
    case cleanDesktop
    case state
    case setLoginItem
    case screenShareState
}

struct AutomationCommand: Codable, Equatable, Sendable {
    static let maximumIdentifierLength = 1024
    static let maximumPauseSeconds = 86_400

    var action: AutomationAction
    var target: String?
    var sceneID: String?
    var seconds: Int?
    var enabled: Bool?

    init(action: AutomationAction,
         target: String? = nil,
         sceneID: String? = nil,
         seconds: Int? = nil,
         enabled: Bool? = nil) {
        self.action = action
        self.target = target
        self.sceneID = sceneID
        self.seconds = seconds
        self.enabled = enabled
    }

    func validated() throws -> AutomationCommand {
        func checked(_ value: String?, name: String) throws -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumIdentifierLength else {
                throw AutomationParseError.invalidValue(name)
            }
            return trimmed
        }
        var result = self
        result.target = try checked(target, name: "target")
        result.sceneID = try checked(sceneID, name: "scene")

        switch action {
        case .applyScene, .applyCollection, .applyAmbientSet, .setVariant:
            guard result.target != nil else { throw AutomationParseError.missingValue("target") }
        case .pauseFor:
            guard let seconds, (1...Self.maximumPauseSeconds).contains(seconds) else {
                throw AutomationParseError.invalidValue("seconds")
            }
        case .setLoginItem:
            guard enabled != nil else { throw AutomationParseError.missingValue("enabled") }
        case .next, .previous, .pause, .resume, .togglePause, .cleanDesktop, .state, .screenShareState:
            break
        }
        return result
    }
}

struct AutomationState: Codable, Equatable, Sendable {
    var appRunning: Bool
    var sceneID: String?
    var sceneTitle: String?
    var collectionID: String?
    var variantID: String?
    var variantName: String?
    var ambientSetID: String?
    var ambientSetName: String?
    var paused: Bool
    var pauseUntil: Date?
    var desktopFilesVisible: Bool?
    var desktopWidgetsVisible: Bool?
    var loginItemEnabled: Bool?
    var screenShare: ScreenShareState

    init(appRunning: Bool = false,
         sceneID: String? = nil,
         sceneTitle: String? = nil,
         collectionID: String? = nil,
         variantID: String? = nil,
         variantName: String? = nil,
         ambientSetID: String? = nil,
         ambientSetName: String? = nil,
         paused: Bool = false,
         pauseUntil: Date? = nil,
         desktopFilesVisible: Bool? = nil,
         desktopWidgetsVisible: Bool? = nil,
         loginItemEnabled: Bool? = nil,
         screenShare: ScreenShareState = .unknown) {
        self.appRunning = appRunning
        self.sceneID = sceneID
        self.sceneTitle = sceneTitle
        self.collectionID = collectionID
        self.variantID = variantID
        self.variantName = variantName
        self.ambientSetID = ambientSetID
        self.ambientSetName = ambientSetName
        self.paused = paused
        self.pauseUntil = pauseUntil
        self.desktopFilesVisible = desktopFilesVisible
        self.desktopWidgetsVisible = desktopWidgetsVisible
        self.loginItemEnabled = loginItemEnabled
        self.screenShare = screenShare
    }
}

enum ScreenShareState: String, Codable, Equatable, Sendable {
    case unknown
    case inactive
    case activeWindowStream
    case permissionRequired
    case unavailable
}

struct AutomationRequest: Codable, Equatable, Sendable {
    var id: UUID
    var command: AutomationCommand
    var createdAt: Date

    init(id: UUID = UUID(), command: AutomationCommand, createdAt: Date = Date()) {
        self.id = id
        self.command = command
        self.createdAt = createdAt
    }
}

struct AutomationResponse: Codable, Equatable, Sendable {
    var id: UUID
    var success: Bool
    var message: String
    var state: AutomationState?
}

enum AutomationParseError: LocalizedError, Equatable {
    case wrongScheme
    case wrongHost
    case unknownAction(String)
    case missingValue(String)
    case invalidValue(String)
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .wrongScheme: return "Use the idlesse URL scheme."
        case .wrongHost: return "Automation URLs use idlesse://automation/…"
        case .unknownAction(let value): return "Unknown automation action: \(value)"
        case .missingValue(let value): return "Missing automation value: \(value)"
        case .invalidValue(let value): return "Invalid automation value: \(value)"
        case .usage(let value): return value
        }
    }
}

enum AutomationURLParser {
    static func parse(_ url: URL) throws -> AutomationCommand {
        guard url.scheme?.lowercased() == "idlesse" else { throw AutomationParseError.wrongScheme }
        guard url.host?.lowercased() == "automation" else { throw AutomationParseError.wrongHost }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AutomationParseError.invalidValue("url")
        }
        let action = url.path.split(separator: "/").first.map(String.init) ?? ""
        func value(_ name: String) -> String? {
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        let command: AutomationCommand
        switch action {
        case "apply-scene": command = .init(action: .applyScene, target: value("id") ?? value("path"))
        case "apply-collection": command = .init(action: .applyCollection, target: value("id"))
        case "apply-ambient-set": command = .init(action: .applyAmbientSet, target: value("id"))
        case "set-variant": command = .init(action: .setVariant, target: value("variant") ?? value("name"), sceneID: value("scene"))
        case "next": command = .init(action: .next)
        case "previous": command = .init(action: .previous)
        case "pause": command = .init(action: .pause)
        case "resume": command = .init(action: .resume)
        case "toggle-pause": command = .init(action: .togglePause)
        case "pause-for":
            guard let raw = value("seconds"), let seconds = Int(raw) else { throw AutomationParseError.invalidValue("seconds") }
            command = .init(action: .pauseFor, seconds: seconds)
        case "clean-desktop": command = .init(action: .cleanDesktop)
        case "state": command = .init(action: .state)
        case "login-item":
            guard let raw = value("enabled"), let enabled = parseBoolean(raw) else { throw AutomationParseError.invalidValue("enabled") }
            command = .init(action: .setLoginItem, enabled: enabled)
        case "screen-share-state": command = .init(action: .screenShareState)
        default: throw AutomationParseError.unknownAction(action)
        }
        return try command.validated()
    }

    private static func parseBoolean(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}

enum AutomationCLIParser {
    static let usage = """
    Idlesse --ctl <command>
      apply-scene <library-id|path>
      apply-collection <collection-id>
      apply-ambient-set <ambient-set-id>
      set-variant <variant-name-or-uuid> [--scene <library-id>]
      next | previous
      pause | resume | toggle-pause
      pause-for <seconds>
      clean-desktop
      state
      login-item <on|off>
      screen-share-state
    """

    static func parse(_ arguments: [String]) throws -> AutomationCommand {
        guard let verb = arguments.first else { throw AutomationParseError.usage(usage) }
        let command: AutomationCommand
        switch verb {
        case "apply-scene": command = .init(action: .applyScene, target: try positional(arguments, at: 1, name: "scene"))
        case "apply-collection": command = .init(action: .applyCollection, target: try positional(arguments, at: 1, name: "collection"))
        case "apply-ambient-set": command = .init(action: .applyAmbientSet, target: try positional(arguments, at: 1, name: "ambient-set"))
        case "set-variant":
            let variant = try positional(arguments, at: 1, name: "variant")
            var scene: String?
            if let index = arguments.firstIndex(of: "--scene") {
                scene = try positional(arguments, at: index + 1, name: "scene")
            }
            command = .init(action: .setVariant, target: variant, sceneID: scene)
        case "next": command = .init(action: .next)
        case "previous": command = .init(action: .previous)
        case "pause": command = .init(action: .pause)
        case "resume": command = .init(action: .resume)
        case "toggle-pause": command = .init(action: .togglePause)
        case "pause-for":
            let raw = try positional(arguments, at: 1, name: "seconds")
            guard let seconds = Int(raw) else { throw AutomationParseError.invalidValue("seconds") }
            command = .init(action: .pauseFor, seconds: seconds)
        case "clean-desktop": command = .init(action: .cleanDesktop)
        case "state": command = .init(action: .state)
        case "login-item":
            let raw = try positional(arguments, at: 1, name: "login-item")
            let enabled: Bool
            switch raw.lowercased() {
            case "on", "true", "1", "yes": enabled = true
            case "off", "false", "0", "no": enabled = false
            default: throw AutomationParseError.invalidValue("login-item")
            }
            command = .init(action: .setLoginItem, enabled: enabled)
        case "screen-share-state": command = .init(action: .screenShareState)
        case "help", "--help", "-h": throw AutomationParseError.usage(usage)
        default: throw AutomationParseError.unknownAction(verb)
        }
        return try command.validated()
    }

    private static func positional(_ args: [String], at index: Int, name: String) throws -> String {
        guard args.indices.contains(index), !args[index].hasPrefix("--") else { throw AutomationParseError.missingValue(name) }
        return args[index]
    }
}
