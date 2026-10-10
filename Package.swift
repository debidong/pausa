// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pausa",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure scheduling logic, no UI (Mitchell).
        .target(name: "PausaCore", path: "Sources/PausaCore"),
        .executableTarget(name: "PausaCoreCheck", dependencies: ["PausaCore"], path: "Sources/PausaCoreCheck"),
        // App: Detection/ + Overlay/ (Linus), Core/ + MenuBar/ + app shell (Mitchell).
        .executableTarget(
            name: "Pausa",
            dependencies: ["PausaCore"],
            path: "Sources/Pausa",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
