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
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", revision: "c340197966ebd264f3135d3955874b40f8ed58bc"),
        // Parakeet TDT on Core ML / the Neural Engine. v0.17.7, pinned by commit.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "503b4bd1bbf7220882de39fe8ae6716aae4132da"),
    ],
    targets: [
        // Streaming, text processing and endpointing: pure Swift, no model, no UI.
        .target(name: "FreeflowCore", path: "Sources/FreeflowCore"),
        .executableTarget(
            name: "Freeflow",
            dependencies: ["FreeflowCore", .product(name: "SwiftWhisper", package: "SwiftWhisper"),
                           .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Freeflow"
        ),
        .testTarget(name: "FreeflowCoreTests", dependencies: ["FreeflowCore"], path: "Tests/FreeflowCoreTests"),
    ]
)
