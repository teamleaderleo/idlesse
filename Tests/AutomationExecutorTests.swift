import Foundation

@main struct AutomationExecutorTests {
    @MainActor
    static func main() async {
        var calls: [String] = []
        var paused = false
        var login = false
        let executor = AutomationCommandExecutor(dependencies: .init(
            applyScene: { calls.append("scene:\($0)") },
            applyCollection: { calls.append("collection:\($0)") },
            applyAmbientSet: { calls.append("set:\($0)") },
            setVariant: { variant, scene in calls.append("variant:\(variant):\(scene ?? "-")") },
            step: { calls.append("step:\($0)") },
            setPaused: { paused = $0; calls.append("paused:\($0)") },
            togglePause: { paused.toggle(); calls.append("toggle") },
            pauseFor: { paused = true; calls.append("pause-for:\($0)") },
            cleanDesktop: { calls.append("clean") },
            currentState: { AutomationState(appRunning: true, paused: paused, loginItemEnabled: login) },
            setLoginItem: { login = $0; calls.append("login:\($0)") },
            screenShareState: { .activeWindowStream }
        ))

        for command in [
            AutomationCommand(action: .applyScene, target: "s"),
            .init(action: .applyCollection, target: "c"),
            .init(action: .applyAmbientSet, target: "a"),
            .init(action: .setVariant, target: "Night", sceneID: "s"),
            .init(action: .next), .init(action: .previous),
            .init(action: .pause), .init(action: .resume), .init(action: .togglePause),
            .init(action: .pauseFor, seconds: 3600), .init(action: .cleanDesktop),
            .init(action: .setLoginItem, enabled: true)
        ] {
            let response = await executor.execute(command)
            precondition(response.success, response.message)
        }
        precondition(calls == ["scene:s", "collection:c", "set:a", "variant:Night:s", "step:1", "step:-1", "paused:true", "paused:false", "toggle", "pause-for:3600", "clean", "login:true"])
        let screen = await executor.execute(.init(action: .screenShareState))
        precondition(screen.success && screen.state?.screenShare == .activeWindowStream)
        let invalid = await executor.execute(.init(action: .pauseFor, seconds: 0))
        precondition(!invalid.success)
        let state = await executor.execute(.init(action: .state))
        precondition(state.success && state.state?.appRunning == true)
        print("Automation executor checks passed")
    }
}
