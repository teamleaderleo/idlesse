import Foundation
import ExtensionFoundation
import os

/// Discovery probe: deliberately exports no methods and cannot acquire a surface.
@main
final class NativeWallpaperProbe: NSObject, AppExtension {
    override required init() {
        super.init()
        _ = dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_LAZY)
        Logger(subsystem: "dev.idlesse.nativeprobe", category: "extension").notice("Extension initialized")
    }
    var configuration: some AppExtensionConfiguration {
        Logger(subsystem: "dev.idlesse.nativeprobe", category: "extension").notice("Configuration requested")
        return ProbeConfiguration()
    }
}
struct ProbeConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        Logger(subsystem: "dev.idlesse.nativeprobe", category: "extension")
            .notice("Host requested connection; rendering disabled in discovery probe")
        return false
    }
}
