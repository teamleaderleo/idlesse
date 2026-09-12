import AppKit
import Foundation
import ObjectiveC

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
        if CommandLine.arguments.contains("--desktop-state") {
            for screen in NSScreen.screens {
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"
                let url = try? NSWorkspace.shared.desktopImageURL(for: screen)
                print("\(id): \(url?.path ?? "no image URL")")
            }
            return
        }
        if CommandLine.arguments.contains("--surface-check") {
            struct Destination { let size: CGSize; let scaleFactor: CGFloat = 1 }
            struct Request { let destination: Destination }
            do {
                let geometry = try ProbeGeometry(Request(destination: Destination(size: CGSize(width: 640, height: 360))))
                let store = ProbeSurfaceStore.shared
                let id = UUID()
                let first = try store.acquire(id: id, geometry: geometry)
                let second = try store.acquire(id: id, geometry: geometry)
                let a = try NSKeyedArchiver.archivedData(withRootObject: first, requiringSecureCoding: true)
                let b = try NSKeyedArchiver.archivedData(withRootObject: second, requiringSecureCoding: true)
                guard a == b else { throw probeError("Acquire did not reuse the context") }
                guard try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSClassFromString("WallpaperRemoteContextXPC")!], from: a) != nil else { throw probeError("Context round-trip failed") }
                let snapshot = try store.snapshot(id: id)
                print("Remote context round-trip/reuse and snapshot: \(type(of: snapshot))")
                store.invalidate(id: id)
                do { _ = try store.snapshot(id: id); throw probeError("Invalidation failed") }
                catch let error as NSError where error.localizedDescription == "Unknown snapshot surface" {}
                do { _ = try ProbeGeometry(Request(destination: Destination(size: CGSize(width: CGFloat.infinity, height: 360)))); throw probeError("Geometry guard failed") }
                catch let error as NSError where error.localizedDescription == "Destination exceeds synthetic probe budget" {}
                var ids: [UUID] = []
                for _ in 0..<4 {
                    let key = UUID(); ids.append(key)
                    _ = try store.acquire(id: key, geometry: geometry)
                }
                do { _ = try store.acquire(id: UUID(), geometry: geometry); throw probeError("Surface cap failed") }
                catch let error as NSError where error.localizedDescription == "Surface limit reached" {}
                for key in ids { store.invalidate(id: key) }
                let surface = try ProbeSurface(geometry: geometry)
                defer { surface.dispose() }
                surface.setPaused(true)
                let before = surface.elapsed
                let pixels = try surface.snapshotSurface()
                guard pixels.width == 640, pixels.height == 360, pixels.allocationSize <= 1_000_000 else {
                    throw probeError("Snapshot budget or dimensions failed")
                }
                pixels.lock(options: .readOnly, seed: nil)
                let corner = pixels.baseAddress.assumingMemoryBound(to: UInt8.self)
                let matchesBackground = corner[3] == 255 && corner[0] > corner[2]
                pixels.unlock(options: .readOnly, seed: nil)
                guard matchesBackground else { throw probeError("Snapshot background pixel mismatch") }
                for _ in 0..<100 { try autoreleasepool { _ = try surface.snapshot() } }
                guard surface.elapsed == before else { throw probeError("Paused scene time advanced") }
                surface.setPaused(false)
                guard surface.elapsed >= before else { throw probeError("Resumed scene time went backward") }
                print("Teardown, surface cap, geometry guards, BGRA pixels, 100 snapshots and pause/resume passed")
            } catch { fputs("Surface check failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--wire-inspect") {
            for name in ["WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperIDXPC"] {
                guard let cls = NSClassFromString(name) else { continue }
                print("\(name) size=\(class_getInstanceSize(cls))")
                var count: UInt32 = 0
                if let ivars = class_copyIvarList(cls, &count) {
                    defer { free(ivars) }
                    for i in 0..<Int(count) {
                        let v = ivars[i]
                        print("  ivar \(String(cString: ivar_getName(v)!)) offset=\(ivar_getOffset(v)) type=\(ivar_getTypeEncoding(v).map { String(cString: $0) } ?? "opaque")")
                    }
                }
                if let methods = class_copyMethodList(cls, &count) {
                    defer { free(methods) }
                    for i in 0..<Int(count) { print("  \(NSStringFromSelector(method_getName(methods[i])))") }
                }
            }
            return
        }
        let names = ["WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperSettingsViewModelsXPC", "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC"]
        let report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "frameworkLoaded": loaded,
            "classes": Dictionary(uniqueKeysWithValues: names.map { ($0, NSClassFromString($0) != nil) }),
            "renderingImplemented": true
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
