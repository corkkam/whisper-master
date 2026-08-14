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
        // Pinned exactly. Was 0.14.7 because 0.15.0's sliding-window
        // finish()/splicing rewrite coincided with vanished transcripts + cut-off
        // sentences in the field. Bumped to 0.15.5, which carries the long-form
        // splice fixes (#688 word-boundary chunk merges, #689
        // SlidingWindowAsrConfig). Re-tested against the audio bench
        // (`swift test --filter AudioReplayTests`): all seven reference paragraphs,
        // including the 122-word long-form P6, transcribe fully with output
        // byte-for-byte identical to 0.14.7 — no vanished/truncated/empty
        // transcript. Do not bump further without re-running that bench.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
        // On-device qwen cleanup (MLX). Pinned exact: the MLXLMCommon/ChatSession
        // API churns between minors; the service is written against 2.29.1.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", exact: "2.29.1"),
        // Clerk auth — the launch sign-in gate. Native macOS 14+ support.
        // ClerkKit = core/observable state, ClerkKitUI = prebuilt AuthView.
        .package(url: "https://github.com/clerk/clerk-ios.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperMaster",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ClerkKitUI", package: "clerk-ios")
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
                // Note: MLX is intentionally NOT a test dependency. mlx-swift's
                // Metal shaders only compile under xcodebuild (not SwiftPM CLI),
                // so MLX inference can't run under `swift test`. The cleanup guard
                // tests are pure Swift; qwen inference is validated in the app.
            ],
            path: "Tests/WhisperMasterTests"
        ),
        // Evaluation engine scoring (pure Swift, no app/MLX deps). The in-app
        // runner grades the real pipeline and writes results.json; this CLI reads
        // it and does keyword/WER/attribution scoring. Reuses the real guard via
        // the runner (no ported guard), so nothing here duplicates app logic.
        .target(
            name: "EvalScoreKit",
            path: "eval/text-cleanup/EvalScore"
        ),
        .executableTarget(
            name: "eval-score",
            dependencies: ["EvalScoreKit"],
            path: "eval/text-cleanup/EvalScoreCLI"
        ),
        .testTarget(
            name: "EvalScoreKitTests",
            dependencies: ["EvalScoreKit"],
            path: "eval/text-cleanup/EvalScoreTests"
        )
    ]
)
