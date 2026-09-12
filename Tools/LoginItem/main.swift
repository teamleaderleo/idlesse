import AppKit
import Foundation

// Embedded at Idlesse.app/Contents/Library/LoginItems/IdlesseLoginItem.app.
// Walk from the helper bundle itself so renamed copies launch their containing app
// instead of assuming the application is literally named Idlesse.app.
let target = Bundle.main.bundleURL
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // containing .app

guard target.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
      FileManager.default.fileExists(atPath: target.path) else {
    fputs("Idlesse login launch failed: containing application bundle is unavailable.\n", stderr)
    exit(EXIT_FAILURE)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.addsToRecentItems = false
configuration.arguments = ["--login-wake"]

let semaphore = DispatchSemaphore(value: 0)
var result: Error?
NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
    result = error
    semaphore.signal()
}
_ = semaphore.wait(timeout: .now() + 8)
if let result {
    fputs("Idlesse login launch failed: \(result.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
exit(EXIT_SUCCESS)
