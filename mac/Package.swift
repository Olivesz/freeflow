// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Freeflow",
    platforms: [.macOS(.v14)],   // SMAppService + SwiftUI symbolEffect / material APIs
    dependencies: [
        // whisper.cpp wrapped for Swift; builds with Accelerate/Metal on Apple Silicon.
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master")
    ],
    targets: [
        .executableTarget(
            name: "Freeflow",
            dependencies: [.product(name: "SwiftWhisper", package: "SwiftWhisper")],
            path: "Sources/Freeflow"
        )
    ]
)
