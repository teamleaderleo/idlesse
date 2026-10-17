import Foundation

@main struct AutomationCommandTests {
    static func main() async throws {
        try urlCoverage()
        try cliCoverage()
        try validationCoverage()
        try codableCoverage()
        await executorCoverage()
        print("Automation command/parser/executor checks passed")
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

    @MainActor
    static func executorCoverage() async {
        var calls: [String] = []
        var state = AutomationState(appRunning: true, paused: false)
        let dependencies = AutomationCommandExecutor.Dependencies(
            applyScene: { calls.append("scene:\($0)"); state.sceneID = $0 },
            applyCollection: { calls.append("collection:\($0)"); state.collectionID = $0 },
            applyAmbientSet: { calls.append("ambient:\($0)"); state.ambientSetID = $0 },
            setVariant: { variant, sceneID in calls.append("variant:\(variant):\(sceneID ?? "-")"); state.variantName = variant },
            step: { calls.append("step:\($0)") },
            setPaused: { paused in calls.append("paused:\(paused)"); state.paused = paused },
            togglePause: { calls.append("toggle"); state.paused.toggle() },
            pauseFor: { seconds in calls.append("pauseFor:\(seconds)"); state.pauseUntil = Date(timeIntervalSince1970: Double(seconds)) },
            cleanDesktop: { calls.append("clean") },
            currentState: { state },
            setLoginItem: { enabled in calls.append("login:\(enabled)"); state.loginItemEnabled = enabled },
            screenShareState: { .activeWindowStream })
        let executor = AutomationCommandExecutor(dependencies: dependencies)

        let fixedID = UUID(uuidString: "31E7AC1A-8EDC-4318-AE4B-A9CE372982BF")!
        let scene = await executor.execute(.init(action: .applyScene, target: "scene-a"), requestID: fixedID)
        precondition(scene.success && scene.id == fixedID && scene.state?.sceneID == "scene-a")
        let collection = await executor.execute(.init(action: .applyCollection, target: "night"))
        precondition(collection.success)
        let ambient = await executor.execute(.init(action: .applyAmbientSet, target: "focus"))
        precondition(ambient.success)
        let variant = await executor.execute(.init(action: .setVariant, target: "Midnight", sceneID: "scene-a"))
        precondition(variant.success)
        let next = await executor.execute(.init(action: .next))
        precondition(next.success)
        let previous = await executor.execute(.init(action: .previous))
        precondition(previous.success)
        let paused = await executor.execute(.init(action: .pause))
        precondition(paused.state?.paused == true)
        let resumed = await executor.execute(.init(action: .resume))
        precondition(resumed.state?.paused == false)
        let toggled = await executor.execute(.init(action: .togglePause))
        precondition(toggled.state?.paused == true)
        let timed = await executor.execute(.init(action: .pauseFor, seconds: 60))
        precondition(timed.state?.pauseUntil == Date(timeIntervalSince1970: 60))
        let cleaned = await executor.execute(.init(action: .cleanDesktop))
        precondition(cleaned.success)
        let login = await executor.execute(.init(action: .setLoginItem, enabled: true))
        precondition(login.state?.loginItemEnabled == true)
        let share = await executor.execute(.init(action: .screenShareState))
        precondition(share.success && share.state?.screenShare == .activeWindowStream)
        let current = await executor.execute(.init(action: .state))
        precondition(current.success && current.state?.sceneID == "scene-a")
        precondition(calls == ["scene:scene-a", "collection:night", "ambient:focus", "variant:Midnight:scene-a",
                               "step:1", "step:-1", "paused:true", "paused:false", "toggle", "pauseFor:60", "clean", "login:true"])

        let invalid = await executor.execute(.init(action: .pauseFor, seconds: 0))
        precondition(!invalid.success && invalid.state?.sceneID == "scene-a", "validation failure must return current state")

        enum TestFailure: LocalizedError { case expected; var errorDescription: String? { "expected dependency failure" } }
        let failing = AutomationCommandExecutor(dependencies: .init(
            applyScene: { _ in throw TestFailure.expected },
            applyCollection: { _ in }, applyAmbientSet: { _ in }, setVariant: { _, _ in }, step: { _ in },
            setPaused: { _ in }, togglePause: {}, pauseFor: { _ in }, cleanDesktop: {}, currentState: { state },
            setLoginItem: { _ in }, screenShareState: { .unknown }))
        let failure = await failing.execute(.init(action: .applyScene, target: "scene-b"))
        precondition(!failure.success && failure.message == "expected dependency failure" && failure.state?.sceneID == "scene-a")
    }
}
