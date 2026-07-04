// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperMaster",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "WhisperMaster",
            targets: ["WhisperMaster"]
        )
    ],
    dependencies: [
        // Pinned exactly: 0.15.x changed sliding-window finish()/splicing behavior
        // and coincided with vanished transcripts + cut-off sentences in the field.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.7"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperMaster",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK")
            ],
            path: "Sources/WhisperMaster",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "WhisperMasterTests",
            dependencies: [
                "WhisperMaster",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Tests/WhisperMasterTests"
        )
    ]
)
