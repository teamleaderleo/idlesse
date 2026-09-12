import AppKit
import Foundation

let helper = Bundle.main.bundleURL
let mainApp = helper
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // Idlesse.app parent calculation target below
    .appendingPathComponent("Idlesse.app", isDirectory: true)

// When installed at Idlesse.app/Contents/Library/LoginItems/IdlesseLoginItem.app,
// walking four parents lands beside Idlesse.app. Prefer the embedded parent when
// its path is available so renamed copies continue to launch themselves.
let embeddedMain = helper
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let target = embeddedMain.pathExtension == "app" ? embeddedMain : mainApp

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
