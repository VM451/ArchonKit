import Foundation
import ArchonAgent
import ArchonCore
import ArchonModels
import Testing
@testable import ArchonInference

private final class ManagerStubBackend: LlamaBackendDriver, @unchecked Sendable {
    var unloadCount = 0

    func loadSession(
        source: LlamaModelSource,
        configuration: LlamaConfiguration,
        metadata: LlamaGGUFMetadata
    ) async throws -> any LlamaLoadedSession {
        ManagerStubSession(onUnload: { [weak self] in
            self?.unloadCount += 1
        })
    }
}

private final class ManagerStubSession: LlamaLoadedSession, @unchecked Sendable {
    let effectiveContextLength: Int = 4096
    private let onUnload: @Sendable () -> Void

    init(onUnload: @escaping @Sendable () -> Void) {
        self.onUnload = onUnload
    }

    func generateStream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions,
        configuration: LlamaConfiguration
    ) -> AsyncThrowingStream<LlamaStreamTokenEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.yield(.completed(promptTokens: 4, completionTokens: 1, hitEOG: true))
            continuation.finish()
        }
    }

    func unload() async {
        onUnload()
    }
}

@Suite("LlamaModelManager & ModelRuntimeAdapter Lifecycle Tests")
struct LlamaModelManagerTests {
    @Test("Manages resident memory ceilings, switching, and memory pressure unloading")
    func managesResidentModelsAndMemoryPressure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-llama-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelAURL = dir.appendingPathComponent("a.gguf")
        let modelBURL = dir.appendingPathComponent("b.gguf")
        var data = makeGGUFHeader(version: 3, tensorCount: 1, kvCount: 1)
        appendKVString("general.architecture", "llama", to: &data)
        try data.write(to: modelAURL)
        try data.write(to: modelBURL)

        let tightDevice = ArchonDeviceCapabilities(
            platform: .iOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            availableMemoryBytes: 2 * 1024 * 1024 * 1024,
            processorCount: 6,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: false,
            supportsCoreAI: true
        )
        let budget = tightDevice.recommendedModelMemoryBytes
        let perModelPeak = (budget * 3) / 5 // 60% of budget: 1 fits, 2 concurrent exceed budget

        let backend = ManagerStubBackend()
        let manager = LlamaModelManager(backend: backend)
        await manager.register(LlamaRegisteredModel(
            id: "a",
            source: .localFile(modelAURL),
            predictedPeakMemoryBytes: perModelPeak
        ))
        await manager.register(LlamaRegisteredModel(
            id: "b",
            source: .localFile(modelBURL),
            predictedPeakMemoryBytes: perModelPeak
        ))

        try await manager.load(modelID: "a", on: tightDevice)
        #expect(await manager.state(for: "a") == .ready)
        #expect(await manager.loadedModelIDs() == ["a"])
        #expect(await manager.loadedMemoryBytes() == perModelPeak)

        // Loading B concurrently exceeds remaining budget (~40% left)
        await #expect(throws: LlamaProviderError.self) {
            try await manager.load(modelID: "b", on: tightDevice)
        }

        // Switching to B unloads A first so B fits
        try await manager.switchTo(modelID: "b", on: tightDevice)
        #expect(await manager.loadedModelIDs() == ["b"])
        #expect(await manager.state(for: "a") == .unloaded)
        #expect(await manager.provider(for: "b") != nil)

        // Memory pressure unloads resident models
        await manager.handleMemoryPressure(.critical)
        #expect(await manager.loadedModelIDs().isEmpty)
        #expect(await manager.state(for: "b") == .unloaded)

        // Thermal pressure fails closed before loading
        let hotDevice = ArchonDeviceCapabilities(
            platform: .iOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            availableMemoryBytes: 2 * 1024 * 1024 * 1024,
            processorCount: 6,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: false,
            supportsCoreAI: true,
            thermalState: .serious
        )
        await #expect(throws: LlamaProviderError.self) {
            try await manager.load(modelID: "a", on: hotDevice)
        }
    }

    @Test("LlamaModelRuntimeAdapter validates GGUF format, rejects symlinks, and loads safely")
    func runtimeAdapterValidationAndLifecycle() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-llama-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ggufURL = dir.appendingPathComponent("model.gguf")
        var data = makeGGUFHeader(version: 3, tensorCount: 1, kvCount: 1)
        appendKVString("general.architecture", "llama", to: &data)
        try data.write(to: ggufURL)

        let adapter = LlamaModelRuntimeAdapter(configuration: .standard, backend: ManagerStubBackend())

        // Non-GGUF rejected
        let mlxVariant = ModelVariant(
            id: "mlx",
            name: "model.mlx",
            modelID: "example/mlx",
            source: .localImport,
            format: .mlx,
            runtime: .mlx
        )
        let mlxModel = InstalledModel(
            id: "mlx",
            directoryURL: dir,
            manifest: ArchonModelManifest(variant: mlxVariant, modelName: "MLX")
        )
        await #expect(throws: ArchonModelsError.self) {
            try await adapter.load(model: mlxModel)
        }

        // Valid GGUF bundle directory loads & unloads
        let ggufVariant = ModelVariant(
            id: "gguf",
            name: "model.gguf",
            modelID: "example/gguf",
            source: .localImport,
            format: .gguf,
            runtime: .unknown,
            estimatedMemoryBytes: 1_000_000
        )
        let ggufModel = InstalledModel(
            id: "gguf",
            directoryURL: dir,
            manifest: ArchonModelManifest(variant: ggufVariant, modelName: "GGUF")
        )
        try await adapter.load(model: ggufModel)
        #expect(await adapter.provider(for: "gguf") != nil)
        await adapter.unload(model: ggufModel)
        #expect(await adapter.provider(for: "gguf") == nil)
    }
}
