#if os(macOS)
import AppIntents
import Foundation

private enum AutomationIntentRunner {
    @MainActor
    static func run(_ command: AutomationCommand) async throws -> AutomationResponse {
        if AutomationAppHost.current != nil {
            let response = await AutomationRuntimeRegistry.shared.execute(command)
            if !response.success { throw IntentAutomationError.failed(response.message) }
            return response
        }
        let response = try await Task.detached(priority: .userInitiated) {
            try AutomationClient.submit(command)
        }.value
        if !response.success { throw IntentAutomationError.failed(response.message) }
        return response
    }
}

private enum IntentAutomationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

struct ApplyAmbientSetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Ambient Set"
    static var description = IntentDescription("Apply a named Idlesse Ambient Set using normal manual-hold semantics.")

    @Parameter(title: "Ambient Set ID or Name") var ambientSet: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .applyAmbientSet, target: ambientSet))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct SetWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Wallpaper"
    static var description = IntentDescription("Set an Idlesse Library wallpaper by ID, title, catalog ID, or path.")

    @Parameter(title: "Wallpaper ID, Title, or Path") var wallpaper: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .applyScene, target: wallpaper))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct SetVariantIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Variant"
    static var description = IntentDescription("Apply a named variant to the current Idlesse scene.")

    @Parameter(title: "Variant Name or UUID") var variant: String
    @Parameter(title: "Wallpaper ID", description: "Optional Library wallpaper to select before applying the variant.") var wallpaper: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .setVariant, target: variant, sceneID: wallpaper))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct NextWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Wallpaper"
    static var description = IntentDescription("Advance Idlesse to the next wallpaper.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .next))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct PreviousWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Wallpaper"
    static var description = IntentDescription("Move Idlesse to the previous wallpaper.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .previous))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct PauseResumeWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause or Resume Wallpaper"
    static var description = IntentDescription("Toggle Idlesse wallpaper playback pause state.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .togglePause))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct PauseWallpaperOneHourIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Wallpaper for One Hour"
    static var description = IntentDescription("Pause Idlesse for one hour, then resume automatically.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .pauseFor, seconds: 3600))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct CleanDesktopIntent: AppIntent {
    static var title: LocalizedStringResource = "Clean Desktop"
    static var description = IntentDescription("Hide desktop files and widgets through Idlesse's existing desktop visibility controls.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AutomationIntentRunner.run(.init(action: .cleanDesktop))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct IdlesseAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ApplyAmbientSetIntent(),
                    phrases: ["Apply Ambient Set in \(.applicationName)"],
                    shortTitle: "Apply Ambient Set", systemImageName: "sparkles")
        AppShortcut(intent: SetWallpaperIntent(),
                    phrases: ["Set wallpaper in \(.applicationName)"],
                    shortTitle: "Set Wallpaper", systemImageName: "photo")
        AppShortcut(intent: SetVariantIntent(),
                    phrases: ["Set variant in \(.applicationName)"],
                    shortTitle: "Set Variant", systemImageName: "slider.horizontal.3")
        AppShortcut(intent: NextWallpaperIntent(),
                    phrases: ["Next wallpaper in \(.applicationName)"],
                    shortTitle: "Next Wallpaper", systemImageName: "arrow.right")
        AppShortcut(intent: PreviousWallpaperIntent(),
                    phrases: ["Previous wallpaper in \(.applicationName)"],
                    shortTitle: "Previous Wallpaper", systemImageName: "arrow.left")
        AppShortcut(intent: PauseResumeWallpaperIntent(),
                    phrases: ["Pause or resume wallpaper in \(.applicationName)"],
                    shortTitle: "Pause / Resume", systemImageName: "pause.circle")
        AppShortcut(intent: PauseWallpaperOneHourIntent(),
                    phrases: ["Pause wallpaper for one hour in \(.applicationName)"],
                    shortTitle: "Pause One Hour", systemImageName: "timer")
        AppShortcut(intent: CleanDesktopIntent(),
                    phrases: ["Clean desktop with \(.applicationName)"],
                    shortTitle: "Clean Desktop", systemImageName: "rectangle.dashed")
    }
}
#endif
