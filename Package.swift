// swift-tools-version: 6.2
import PackageDescription

// Swift 5 language mode: the AppKit/Carbon/CoreMotion glue relies on callbacks whose
// isolation the SDK does not annotate, and the research snippets were validated in this mode.
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "AirFocus",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "AirFocusCore",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "AirFocus",
            dependencies: ["AirFocusCore"],
            swiftSettings: swiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreMotion"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuartzCore"),
                // No SkyLight / login.framework link flags: private symbols are resolved with dlsym.
            ]
        ),
        .testTarget(
            name: "AirFocusCoreTests",
            dependencies: ["AirFocusCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
