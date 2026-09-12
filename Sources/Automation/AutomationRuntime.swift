#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ServiceManagement

private enum AutomationRuntimeError: LocalizedError {
    case appBundleUnavailable
    case requestTimedOut
    var errorDescription: String? {
        switch self {
        case .appBundleUnavailable: return "Could not locate the Idlesse application bundle."
        case .requestTimedOut: return "Idlesse did not answer the automation request."
        }
    }
}

enum AutomationMailbox {
    static let notification = Notification.Name("com.teamleaderleo.idlesse.automation.request")
    static let bundleIdentifier = "com.teamleaderleo.idlesse.app"

    static var root: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Idlesse/Automation", isDirectory: true)
    }
    static var requests: URL { root.appendingPathComponent("Requests", isDirectory: true) }
    static var stateURL: URL { root.appendingPathComponent("state.json") }
    static func requestURL(_ id: UUID) -> URL { requests.appendingPathComponent(id.uuidString + ".request.json") }
    static func responseURL(_ id: UUID) -> URL { requests.appendingPathComponent(id.uuidString + ".response.json") }

    static var hasPendingRequests: Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) else { return false }
        return names.contains { $0.hasSuffix(".request.json") }
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    }

    static func writeState(_ state: AutomationState) {
        do {
            try prepare()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch { NSLog("Idlesse automation state write failed: %@", error.localizedDescription) }
    }

    static func readState(appRunning: Bool) -> AutomationState {
        guard let data = try? Data(contentsOf: stateURL),
              var state = try? JSONDecoder().decode(AutomationState.self, from: data) else {
            return AutomationState(appRunning: appRunning)
        }
        state.appRunning = appRunning
        return state
    }
}

@MainActor
final class AutomationRuntimeRegistry {
    static let shared = AutomationRuntimeRegistry()
    private var executor: AutomationCommandExecutor?
    private var server: AutomationMailboxServer?

    func install(_ executor: AutomationCommandExecutor) {
        self.executor = executor
        let server = AutomationMailboxServer(executor: executor)
        self.server = server
        server.start()
        AutomationMailbox.writeState(currentState())
    }

    func execute(_ command: AutomationCommand, requestID: UUID = UUID()) async -> AutomationResponse {
        guard let executor else {
            return AutomationResponse(id: requestID, success: false, message: "Idlesse automation is still starting.", state: nil)
        }
        let response = await executor.execute(command, requestID: requestID)
        if let state = response.state { AutomationMailbox.writeState(state) }
        return response
    }

    func currentState() -> AutomationState {
        AutomationMailbox.readState(appRunning: true)
    }
}

@MainActor
private final class AutomationMailboxServer {
    private let executor: AutomationCommandExecutor
    private var observer: NSObjectProtocol?
    private var draining = false

    init(executor: AutomationCommandExecutor) { self.executor = executor }

    func start() {
        try? AutomationMailbox.prepare()
        observer = DistributedNotificationCenter.default().addObserver(forName: AutomationMailbox.notification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.drain() }
        }
        Task { @MainActor in await drain() }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: AutomationMailbox.requests,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for url in urls.filter({ $0.lastPathComponent.hasSuffix(".request.json") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: url)
                let request = try JSONDecoder().decode(AutomationRequest.self, from: data)
                guard abs(request.createdAt.timeIntervalSinceNow) <= 60 else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                let response = await executor.execute(request.command, requestID: request.id)
                if let state = response.state { AutomationMailbox.writeState(state) }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(response).write(to: AutomationMailbox.responseURL(request.id), options: .atomic)
                try? FileManager.default.removeItem(at: url)
            } catch {
                NSLog("Idlesse automation request failed: %@", error.localizedDescription)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}

enum AutomationClient {
    static func submit(_ command: AutomationCommand, timeout: TimeInterval = 8) throws -> AutomationResponse {
        let command = try command.validated()
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: AutomationMailbox.bundleIdentifier).isEmpty
        if command.action == .state, !running {
            return AutomationResponse(id: UUID(), success: true, message: "Idlesse is not running.",
                                      state: AutomationMailbox.readState(appRunning: false))
        }
        try AutomationMailbox.prepare()
        let request = AutomationRequest(command: command)
        let requestURL = AutomationMailbox.requestURL(request.id)
        let responseURL = AutomationMailbox.responseURL(request.id)
        defer { try? FileManager.default.removeItem(at: requestURL) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: .atomic)
        DistributedNotificationCenter.default().post(name: AutomationMailbox.notification, object: nil)
        if !running { try launchAppWithoutActivation() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL),
               let response = try? JSONDecoder().decode(AutomationResponse.self, from: data) {
                try? FileManager.default.removeItem(at: responseURL)
                return response
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        try? FileManager.default.removeItem(at: responseURL)
        throw AutomationRuntimeError.requestTimedOut
    }

    private static func launchAppWithoutActivation() throws {
        let bundleURL: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            bundleURL = Bundle.main.bundleURL
        } else {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let parts = executable.pathComponents
            guard let index = parts.lastIndex(where: { $0.hasSuffix(".app") }) else { throw AutomationRuntimeError.appBundleUnavailable }
            bundleURL = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...index])), isDirectory: true)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--automation-wake"]
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            launchError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 4)
        if let launchError { throw launchError }
    }
}

enum AutomationCLI {
    static func run(arguments: [String]) -> Int32 {
        do {
            let command = try AutomationCLIParser.parse(arguments)
            let response = try AutomationClient.submit(command)
            if command.action == .state || command.action == .screenShareState, let state = response.state {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(state)
                print(String(decoding: data, as: UTF8.self))
            } else {
                let stream = response.success ? stdout : stderr
                fputs(response.message + "\n", stream)
            }
            return response.success ? EXIT_SUCCESS : EXIT_FAILURE
        } catch let error as AutomationParseError {
            fputs((error.localizedDescription + "\n"), stderr)
            return 2
        } catch {
            fputs((error.localizedDescription + "\n"), stderr)
            return EXIT_FAILURE
        }
    }
}

enum LoginItemService {
    static let helperIdentifier = "com.teamleaderleo.idlesse.login"
    static var service: SMAppService { SMAppService.loginItem(identifier: helperIdentifier) }
    static var enabled: Bool { service.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        let service = service
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }
}

enum ScreenShareProbe {
    /// Explicit capability probe only. Idlesse deliberately does not poll this in
    /// the background: `SCWindow.isActive` covers active window streams, while the
    /// public API does not expose a reliable event for every whole-display or
    /// non-ScreenCaptureKit sharing path.
    static func probe() async -> ScreenShareState {
        guard CGPreflightScreenCaptureAccess() else { return .permissionRequired }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let ownBundle = Bundle.main.bundleIdentifier
            let active = content.windows.contains { window in
                window.isActive && window.owningApplication?.bundleIdentifier != ownBundle
            }
            return active ? .activeWindowStream : .inactive
        } catch {
            return .unavailable
        }
    }
}
#endif
