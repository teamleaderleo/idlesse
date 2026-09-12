// swift-tools-version: 6.0
import PackageDescription

// SPIKE: SwiftPM wrapper for true incremental builds. build.sh still owns
// .app/.saver bundling, code signing, and the FinderSync appex (which needs
// -application-extension flags SwiftPM cannot express). This package only
// produces the compiled executables.
let package = Package(
    name: "Idlesse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IdlesseApp", targets: ["IdlesseApp"]),
    ],
    targets: [
        .executableTarget(
            name: "IdlesseApp",
            path: "Sources",
            exclude: [
                "DesktopMenu",
                "Harness/Info.plist",
                "Saver/Info.plist",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Metal"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AppKit"),
                .linkedFramework("AppIntents"),
                .linkedFramework("Photos"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ScreenSaver"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
