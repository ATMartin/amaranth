// swift-tools-version: 6.2
// AmaranthKit: domain logic and adapters for the Amaranth app.
// Target paths map onto the module ownership directories in docs/development-plan.txt §9.
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "AmaranthKit",
    platforms: [.macOS("26.5")],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "DomainFixtures", targets: ["DomainFixtures"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Models", targets: ["Models"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "ASR", targets: ["ASR"]),
        .library(name: "Diarization", targets: ["Diarization"]),
        .library(name: "ProcessingCore", targets: ["ProcessingCore"]),
        .library(name: "ProcessingRuntime", targets: ["ProcessingRuntime"]),
        .library(name: "Notes", targets: ["Notes"]),
        .library(name: "Export", targets: ["Export"]),
        .library(name: "Presentation", targets: ["Presentation"]),
    ],
    dependencies: [
        // Pins from docs/decisions/models/candidates.md. Exact versions only; never branches.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "Domain", path: "Domain", swiftSettings: strict),
        .target(name: "DomainFixtures", dependencies: ["Domain"], path: "DomainFixtures", swiftSettings: strict),
        .target(name: "CaptureRT", path: "Capture/RealtimeC",
                cSettings: [.unsafeFlags(["-O3", "-Wall", "-Werror"])]),
        .target(name: "Storage", dependencies: ["Domain"], path: "Storage", swiftSettings: strict),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "Domain", "DomainFixtures"], path: "Tests/Storage", swiftSettings: strict),
        .target(name: "Capture", dependencies: ["Domain", "CaptureRT", "Storage"], path: "Capture", exclude: ["RealtimeC"],
                swiftSettings: strict),
        .target(name: "Models", dependencies: ["Domain"], path: "Models", exclude: ["CLI"], swiftSettings: strict),
        .executableTarget(name: "amaranth-models", dependencies: ["Models", "Domain"], path: "Models/CLI"),
        .testTarget(name: "ModelsTests", dependencies: ["Models", "Domain"], path: "Tests/Models", swiftSettings: strict),
        .target(name: "ASR", dependencies: ["Domain", "Capture", .product(name: "FluidAudio", package: "FluidAudio")],
                path: "ASR", swiftSettings: strict),
        .testTarget(name: "ASRTests", dependencies: ["ASR", "Capture", "Domain", "Scoring"], path: "Tests/ASR", swiftSettings: strict),
        .target(name: "Diarization", dependencies: ["Domain", "ASR", .product(name: "FluidAudio", package: "FluidAudio")],
                path: "Diarization", swiftSettings: strict),
        .testTarget(name: "DiarizationTests", dependencies: ["Diarization", "ASR", "Capture", "Domain", "DomainFixtures", "Scoring"],
                    path: "Tests/Diarization", swiftSettings: strict),
        .target(name: "Notes", dependencies: ["Domain", "llama"], path: "Notes", swiftSettings: strict),
        .target(name: "Export", dependencies: ["Domain"], path: "Export", swiftSettings: strict),
        .target(name: "Presentation", dependencies: ["Domain", "Storage"], path: "Presentation", swiftSettings: strict),
        .testTarget(name: "PresentationTests", dependencies: ["Presentation", "Storage", "Domain", "DomainFixtures", "ProcessingCore", "Export"],
                    path: "Tests/UI", swiftSettings: strict),
        .testTarget(name: "DataLifecycleTests", dependencies: ["Export", "Storage", "ProcessingCore", "Domain"], path: "Tests/DataLifecycle", swiftSettings: strict),
        .testTarget(name: "NotesTests", dependencies: ["Notes", "Domain", "DomainFixtures", "Scoring"], path: "Tests/Notes", swiftSettings: strict),
        .target(name: "ProcessingCore", dependencies: ["Domain", "Storage"], path: "InferenceWorker/Core", swiftSettings: strict),
        .target(name: "ProcessingRuntime", dependencies: ["Domain", "ProcessingCore", "ASR", "Diarization", "Models", "Notes"],
                path: "InferenceWorker/Runtime", swiftSettings: strict),
        .testTarget(name: "JobsTests", dependencies: ["ProcessingCore", "ProcessingRuntime", "Storage", "Capture", "Domain", "ASR", "Scoring", "Notes"],
                    path: "Tests/Jobs", swiftSettings: strict),
        .target(name: "Scoring", path: "Benchmarks/Scoring", swiftSettings: strict),
        // llama.cpp b11669 (= release v0.7.0), Metal embedded.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-xcframework.zip",
            checksum: "937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c"
        ),
        .target(name: "BenchEngines",
                dependencies: ["Domain", "Scoring", "llama",
                               .product(name: "FluidAudio", package: "FluidAudio"),
                               .product(name: "WhisperKit", package: "argmax-oss-swift")],
                path: "Benchmarks/Engines"),
        .executableTarget(name: "amaranth-bench", dependencies: ["BenchEngines", "Scoring", "Domain", "Models", "ASR", "Diarization", "Notes", "llama",
                                                         "Storage", "Presentation"],
                          path: "Benchmarks/Harness"),
        .testTarget(name: "ScoringTests", dependencies: ["Scoring"], path: "Tests/Benchmarks", swiftSettings: strict),
        .executableTarget(name: "amaranth-recorder-child", dependencies: ["Capture", "Domain", "Storage"], path: "Tests/RecoveryChild"),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "Domain", "CaptureRT", "Storage", "amaranth-recorder-child"], path: "Tests/Capture",
                    swiftSettings: strict),
        .testTarget(
            name: "ContractTests",
            dependencies: ["Domain", "DomainFixtures"],
            path: "Tests/Contract",
            swiftSettings: strict
        ),
    ]
)
