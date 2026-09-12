import AppKit
import Foundation

@main
struct Probe {
    static func main() {
        let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        let loaded = dlopen(path, RTLD_LAZY) != nil
        if let index = CommandLine.arguments.firstIndex(of: "--make-poster"), CommandLine.arguments.indices.contains(index + 1) {
            let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.04, green: 0.07, blue: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setStrokeColor(CGColor(red: 0.4, green: 0.8, blue: 0.9, alpha: 1))
            context.setLineWidth(8)
            context.strokeEllipse(in: CGRect(x: 190, y: 50, width: 260, height: 260))
            context.setFillColor(CGColor(red: 1, green: 0.68, blue: 0.42, alpha: 1))
            context.fillEllipse(in: CGRect(x: 402, y: 160, width: 44, height: 44))
            let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--catalog-check"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let result = try ProbeCatalog.boxed(poster: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("Catalog round-trip: \(type(of: result))")
            } catch { fputs("Catalog check failed: \(error)\n", stderr); exit(1) }
            return
        }
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
