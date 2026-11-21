// swift-tools-version: 6.4

import CompilerPluginSupport
import Foundation
import PackageDescription

let isGitHub = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
let isXcodeToolchain = developerDir.contains("Xcode.app")
// LOCAL_STUB is only needed for CLT macOS builds that lack Xcode macro plugins
// (@State, @Model, @Generable). iOS / iPadOS / visionOS always build with Xcode
// (which has the plugins), and macOS Xcode builds also have them — only CLT
// macOS needs the stub. Gating to macOS + `!isXcodeToolchain` ensures a local
// Xcode host (iOS or macOS) always gets the full implementation, never the
// AppKit stub that fails to import on iOS.
let isLocalForStubs = !isGitHub && !isXcodeToolchain
let localStubSettings: [SwiftSetting] = isLocalForStubs ? [.define("LOCAL_STUB", .when(platforms: [.macOS]))] : []

let package = Package(
    name: "ArchonKit",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
        .visionOS(.v27)
    ],
    products: [
        .library(name: "ArchonCore", targets: ["ArchonCore"]),
        .library(name: "ArchonModels", targets: ["ArchonModels"]),
        .library(name: "ArchonAgent", targets: ["ArchonAgent"]),
        .library(name: "ArchonContext", targets: ["ArchonContext"]),
        .library(name: "ArchonMemory", targets: ["ArchonMemory"]),
        .library(name: "ArchonMemoryProxima", targets: ["ArchonMemoryProxima"]),
        .library(name: "ArchonSearch", targets: ["ArchonSearch"]),
        .library(name: "ArchonSandbox", targets: ["ArchonSandbox"]),
        .library(name: "ArchonConnect", targets: ["ArchonConnect"]),
        .library(name: "ArchonComputerUse", targets: ["ArchonComputerUse"]),
        .library(name: "ArchonModelsUI", targets: ["ArchonModelsUI"]),
        .library(name: "ArchonInference", targets: ["ArchonInference"]),
        .library(name: "ArchonFull", targets: ["ArchonFull"]),
        .executable(name: "archon-model", targets: ["ArchonModelCLI"]),
        .executable(name: "archon-example-app", targets: ["ArchonExampleApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0" ..< "604.0.0"),
        // The post-0.31.6 MLX core fixes Metal address-space diagnostics in the
        // current Xcode toolchain while preserving the public MLX Swift APIs.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", revision: "ab924c82ead3b970caaa1c0ac11171de23f0305a"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", "6.29.3" ..< "8.0.0"),
        .package(url: "https://github.com/vivekptnk/ProximaKit.git", revision: "9074a52e28baa4fb3abbb971bbc4b43ad8a24a65"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/coreai-models.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "ArchonCore",
            path: "Sources/ArchonCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonModels",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonModels",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonContext",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonContext",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonConnect",
            dependencies: [
                "ArchonCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/ArchonConnect",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonComputerUse",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonComputerUse",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .macro(
            name: "ArchonAgentMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax")
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonAgent",
            dependencies: [
                "ArchonCore",
                "ArchonModels",
                "ArchonAgentMacros",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/ArchonAgent",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonMemory",
            dependencies: [
                "ArchonCore",
                "ArchonContext",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/ArchonMemory",
            exclude: ["Documentation.docc"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonMemoryProxima",
            dependencies: [
                "ArchonMemory",
                .product(name: "ProximaKit", package: "ProximaKit")
            ],
            path: "Sources/ArchonMemoryProxima",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonSearch",
            dependencies: [
                "ArchonCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/ArchonSearch",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonSandbox",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonSandbox",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonModelsUI",
            dependencies: ["ArchonCore", "ArchonModels"],
            path: "Sources/ArchonModelsUI",
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12492/llama-b12492-xcframework.zip",
            checksum: "7905f33221e4c562099fa6a8be5f2279b607653ecd4c77989bd3b13f7d3c15c7"
        ),
        .target(
            name: "ArchonInference",
            dependencies: [
                "ArchonCore",
                "ArchonModels",
                "ArchonAgent",
                .target(name: "LlamaFramework", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "CoreAILM", package: "coreai-models", condition: .when(platforms: [.macOS, .iOS]))
            ],
            path: "Sources/ArchonInference",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .target(
            name: "ArchonFull",
            dependencies: [
                "ArchonCore",
                "ArchonModels",
                "ArchonAgent",
                "ArchonContext",
                "ArchonMemory",
                "ArchonSearch",
                "ArchonSandbox",
                "ArchonConnect",
                "ArchonComputerUse",
                "ArchonModelsUI"
            ],
            path: "Sources/ArchonFull",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .executableTarget(
            name: "ArchonModelCLI",
            dependencies: [
                "ArchonAgent",
                "ArchonModels",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Tools/ArchonModelCLI",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .executableTarget(
            name: "ArchonExampleApp",
            dependencies: ["ArchonAgent", "ArchonModels", "ArchonModelsUI"],
            path: "Examples/ArchonExampleApp",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonCoreTests",
            dependencies: ["ArchonCore"],
            path: "Tests/ArchonCoreTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonModelsTests",
            dependencies: ["ArchonModels"],
            path: "Tests/ArchonModelsTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonContextTests",
            dependencies: ["ArchonContext"],
            path: "Tests/ArchonContextTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonConnectTests",
            dependencies: [
                "ArchonConnect",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/ArchonConnectTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonComputerUseTests",
            dependencies: ["ArchonComputerUse", "ArchonCore"],
            path: "Tests/ArchonComputerUseTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonAgentTests",
            dependencies: [
                "ArchonAgent",
                "ArchonModels",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            path: "Tests/ArchonAgentTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonMemoryTests",
            dependencies: ["ArchonMemory", "ArchonContext"],
            path: "Tests/ArchonMemoryTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonMemoryProximaTests",
            dependencies: ["ArchonMemoryProxima"],
            path: "Tests/ArchonMemoryProximaTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonSearchTests",
            dependencies: ["ArchonSearch"],
            path: "Tests/ArchonSearchTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonSandboxTests",
            dependencies: ["ArchonSandbox"],
            path: "Tests/ArchonSandboxTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonFullTests",
            dependencies: ["ArchonFull", "ArchonContext", "ArchonComputerUse", "ArchonConnect"],
            path: "Tests/ArchonFullTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonModelsUITests",
            dependencies: ["ArchonModelsUI", "ArchonModels"],
            path: "Tests/ArchonModelsUITests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        ),
        .testTarget(
            name: "ArchonInferenceTests",
            dependencies: ["ArchonInference", "ArchonAgent", "ArchonModels", "ArchonCore"],
            path: "Tests/ArchonInferenceTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")] + localStubSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
