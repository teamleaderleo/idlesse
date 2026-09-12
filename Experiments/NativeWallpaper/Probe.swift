import AppKit
import Foundation

@main
struct Probe {
    static func main() {
        let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        let loaded = dlopen(path, RTLD_LAZY) != nil
        let names = ["WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperSettingsViewModelsXPC", "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC"]
        let report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "frameworkLoaded": loaded,
            "classes": Dictionary(uniqueKeysWithValues: names.map { ($0, NSClassFromString($0) != nil) }),
            "renderingImplemented": false
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.contains("--inspect") {
            FileHandle.standardOutput.write(data)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 320),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Idlesse Native Wallpaper Probe"
        window.isReleasedWhenClosed = false
        let text = NSTextField(wrappingLabelWithString: "Registration probe only — no wallpaper changes.\n\n" + String(decoding: data, as: UTF8.self))
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.frame = NSRect(x: 24, y: 24, width: 532, height: 272)
        window.contentView?.addSubview(text)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
