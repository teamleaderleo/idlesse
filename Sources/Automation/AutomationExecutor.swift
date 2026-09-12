import Foundation

@MainActor
final class AutomationCommandExecutor {
    struct Dependencies {
        var applyScene: (String) throws -> Void
        var applyCollection: (String) throws -> Void
        var applyAmbientSet: (String) throws -> Void
        var setVariant: (_ variant: String, _ sceneID: String?) async throws -> Void
        var step: (Int) throws -> Void
        var setPaused: (Bool) -> Void
        var togglePause: () -> Void
        var pauseFor: (Int) -> Void
        var cleanDesktop: () -> Void
        var currentState: () -> AutomationState
        var setLoginItem: (Bool) throws -> Void
        var screenShareState: () async -> ScreenShareState
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func execute(_ rawCommand: AutomationCommand, requestID: UUID = UUID()) async -> AutomationResponse {
        do {
            let command = try rawCommand.validated()
            var message: String
            switch command.action {
            case .applyScene:
                try dependencies.applyScene(command.target!)
                message = "Scene applied"
            case .applyCollection:
                try dependencies.applyCollection(command.target!)
                message = "Collection applied"
            case .applyAmbientSet:
                try dependencies.applyAmbientSet(command.target!)
                message = "Ambient Set applied"
            case .setVariant:
                try await dependencies.setVariant(command.target!, command.sceneID)
                message = "Variant applied"
            case .next:
                try dependencies.step(1)
                message = "Advanced to next wallpaper"
            case .previous:
                try dependencies.step(-1)
                message = "Moved to previous wallpaper"
            case .pause:
                dependencies.setPaused(true)
                message = "Wallpaper paused"
            case .resume:
                dependencies.setPaused(false)
                message = "Wallpaper resumed"
            case .togglePause:
                dependencies.togglePause()
                message = "Wallpaper pause state toggled"
            case .pauseFor:
                dependencies.pauseFor(command.seconds!)
                message = "Wallpaper paused for \(command.seconds!) seconds"
            case .cleanDesktop:
                dependencies.cleanDesktop()
                message = "Desktop cleaned"
            case .state:
                message = "Current state"
            case .setLoginItem:
                try dependencies.setLoginItem(command.enabled!)
                message = command.enabled! ? "Launch at Login enabled" : "Launch at Login disabled"
            case .screenShareState:
                let screenShare = await dependencies.screenShareState()
                var state = dependencies.currentState()
                state.screenShare = screenShare
                return AutomationResponse(id: requestID, success: true, message: "Screen-share state", state: state)
            }
            return AutomationResponse(id: requestID, success: true, message: message, state: dependencies.currentState())
        } catch {
            return AutomationResponse(id: requestID, success: false, message: error.localizedDescription, state: dependencies.currentState())
        }
    }
}
