// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Freeflow",
    platforms: [.macOS(.v14)],   // SMAppService + SwiftUI symbolEffect / material APIs
    products: [
        .executable(name: "Freeflow", targets: ["Freeflow"]),
        .library(name: "FreeflowCore", targets: ["FreeflowCore"]),
    ],
    dependencies: [
        // whisper.cpp wrapped for Swift; builds with Accelerate/Metal on Apple Silicon.
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master")
    ],
    targets: [
        // Streaming, text processing and endpointing: pure Swift, no model, no UI.
        .target(name: "FreeflowCore", path: "Sources/FreeflowCore"),
        .executableTarget(
            name: "Freeflow",
            dependencies: ["FreeflowCore", .product(name: "SwiftWhisper", package: "SwiftWhisper")],
            path: "Sources/Freeflow"
        ),
        .testTarget(name: "FreeflowCoreTests", dependencies: ["FreeflowCore"], path: "Tests/FreeflowCoreTests"),
    ]
)
