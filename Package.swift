// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperMasterPrototype",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "WhisperMasterPrototype",
            targets: ["WhisperMasterPrototype"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperMasterPrototype",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/WhisperMasterPrototype",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
