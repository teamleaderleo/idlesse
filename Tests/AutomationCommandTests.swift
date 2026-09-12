import Foundation

@main struct AutomationCommandTests {
    static func main() throws {
        try urlCoverage()
        try cliCoverage()
        try validationCoverage()
        try codableCoverage()
        print("Automation command/parser checks passed")
    }

    static func expect(_ actual: AutomationCommand, _ expected: AutomationCommand, _ message: String) {
        precondition(actual == expected, "\(message): \(actual) != \(expected)")
    }

    static func reject(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) } catch {}
    }

    static func parseURL(_ raw: String) throws -> AutomationCommand {
        try AutomationURLParser.parse(URL(string: raw)!)
    }

    static func urlCoverage() throws {
        expect(try parseURL("idlesse://automation/apply-scene?id=builtin.Undertow"),
               .init(action: .applyScene, target: "builtin.Undertow"), "scene URL")
        expect(try parseURL("idlesse://automation/apply-collection?id=night"),
               .init(action: .applyCollection, target: "night"), "collection URL")
        expect(try parseURL("idlesse://automation/apply-ambient-set?id=late%20night"),
               .init(action: .applyAmbientSet, target: "late night"), "Ambient Set URL")
        expect(try parseURL("idlesse://automation/set-variant?name=Midnight&scene=builtin.Undertow"),
               .init(action: .setVariant, target: "Midnight", sceneID: "builtin.Undertow"), "variant URL")
        expect(try parseURL("idlesse://automation/next"), .init(action: .next), "next URL")
        expect(try parseURL("idlesse://automation/previous"), .init(action: .previous), "previous URL")
        expect(try parseURL("idlesse://automation/pause"), .init(action: .pause), "pause URL")
        expect(try parseURL("idlesse://automation/resume"), .init(action: .resume), "resume URL")
        expect(try parseURL("idlesse://automation/toggle-pause"), .init(action: .togglePause), "toggle URL")
        expect(try parseURL("idlesse://automation/pause-for?seconds=3600"), .init(action: .pauseFor, seconds: 3600), "timed pause URL")
        expect(try parseURL("idlesse://automation/clean-desktop"), .init(action: .cleanDesktop), "clean URL")
        expect(try parseURL("idlesse://automation/state"), .init(action: .state), "state URL")
        expect(try parseURL("idlesse://automation/login-item?enabled=on"), .init(action: .setLoginItem, enabled: true), "login URL")
        expect(try parseURL("idlesse://automation/screen-share-state"), .init(action: .screenShareState), "share URL")
        reject("accepted wrong scheme") { _ = try parseURL("https://automation/next") }
        reject("accepted wrong host") { _ = try parseURL("idlesse://wallpapers/next") }
        reject("accepted unknown URL action") { _ = try parseURL("idlesse://automation/wat") }
        reject("accepted missing scene ID") { _ = try parseURL("idlesse://automation/apply-scene") }
    }

    static func cliCoverage() throws {
        expect(try AutomationCLIParser.parse(["apply-scene", "builtin.Fireflies"]), .init(action: .applyScene, target: "builtin.Fireflies"), "scene CLI")
        expect(try AutomationCLIParser.parse(["apply-collection", "focus"]), .init(action: .applyCollection, target: "focus"), "collection CLI")
        expect(try AutomationCLIParser.parse(["apply-ambient-set", "presentation"]), .init(action: .applyAmbientSet, target: "presentation"), "set CLI")
        expect(try AutomationCLIParser.parse(["set-variant", "Calm", "--scene", "scene-42"]), .init(action: .setVariant, target: "Calm", sceneID: "scene-42"), "variant CLI")
        expect(try AutomationCLIParser.parse(["pause-for", "3600"]), .init(action: .pauseFor, seconds: 3600), "timed pause CLI")
        expect(try AutomationCLIParser.parse(["login-item", "off"]), .init(action: .setLoginItem, enabled: false), "login CLI")
        expect(try AutomationCLIParser.parse(["state"]), .init(action: .state), "state CLI")
        reject("accepted unknown CLI action") { _ = try AutomationCLIParser.parse(["wat"]) }
        reject("accepted missing CLI target") { _ = try AutomationCLIParser.parse(["apply-scene"]) }
    }

    static func validationCoverage() throws {
        reject("accepted zero timed pause") { _ = try AutomationCommand(action: .pauseFor, seconds: 0).validated() }
        reject("accepted overlong timed pause") { _ = try AutomationCommand(action: .pauseFor, seconds: 86_401).validated() }
        reject("accepted blank ID") { _ = try AutomationCommand(action: .applyScene, target: "  ").validated() }
        let huge = String(repeating: "x", count: AutomationCommand.maximumIdentifierLength + 1)
        reject("accepted huge ID") { _ = try AutomationCommand(action: .applyCollection, target: huge).validated() }
        let maxPause = try AutomationCommand(action: .pauseFor, seconds: 86_400).validated()
        precondition(maxPause == .init(action: .pauseFor, seconds: 86_400))
    }

    static func codableCoverage() throws {
        let request = AutomationRequest(id: UUID(uuidString: "C7362050-49FC-40D3-B09D-4A51B0786B68")!, command: .init(action: .setVariant, target: "Midnight", sceneID: "scene-a"), createdAt: Date(timeIntervalSince1970: 1234))
        let encoded = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(AutomationRequest.self, from: encoded)
        precondition(decodedRequest == request)
        let state = AutomationState(appRunning: true, sceneID: "scene-a", sceneTitle: "Aurora", paused: true, pauseUntil: Date(timeIntervalSince1970: 5678), desktopFilesVisible: false, desktopWidgetsVisible: false, loginItemEnabled: true, screenShare: .inactive)
        let stateBytes = try JSONEncoder().encode(state)
        let decodedState = try JSONDecoder().decode(AutomationState.self, from: stateBytes)
        precondition(decodedState == state)
    }
}
