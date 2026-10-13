// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pausa",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-update (Linus). Embedded by App/build-app.sh into Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure scheduling logic, no UI (Mitchell).
        .target(name: "PausaCore", path: "Sources/PausaCore"),
        .executableTarget(name: "PausaCoreCheck", dependencies: ["PausaCore"], path: "Sources/PausaCoreCheck"),
        // App: Detection/ + Overlay/ (Linus), Core/ + MenuBar/ + app shell (Mitchell).
        .executableTarget(
            name: "Pausa",
            dependencies: ["PausaCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Pausa",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
