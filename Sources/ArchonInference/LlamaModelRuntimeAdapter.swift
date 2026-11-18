import Foundation
import ArchonAgent
import ArchonModels

/// `ArchonModels.ModelRuntimeAdapter` bridge for GGUF artifacts.
///
/// While `ArchonModels` keeps raw `.gguf` files conversion-required for
/// user-facing MLX browsing, hosts that explicitly install or resolve GGUF
/// packages can wire `LlamaModelRuntimeAdapter` to load and run them safely.
public actor LlamaModelRuntimeAdapter: ModelRuntimeAdapter {
    private let configuration: LlamaConfiguration
    private let backend: any LlamaBackendDriver
    private var providers: [String: LlamaLocalProvider] = [:]

    public init(configuration: LlamaConfiguration = .standard) {
        self.configuration = configuration
        self.backend = LlamaNativeBackend()
    }

    init(configuration: LlamaConfiguration = .standard, backend: any LlamaBackendDriver) {
        self.configuration = configuration
        self.backend = backend
    }

    public func load(model: InstalledModel) async throws {
        guard model.manifest.format == .gguf else {
            throw ArchonModelsError.unsupportedArtifact("Only GGUF artifacts can be loaded by LlamaModelRuntimeAdapter.")
        }
        try configuration.validate()
        let ggufURL = try resolveSafeGGUFURL(for: model)
        let provider = providers[model.id] ?? LlamaLocalProvider(
            source: .localFile(ggufURL),
            configuration: configuration,
            predictedPeakMemoryBytes: model.manifest.estimatedMemoryBytes.flatMap { $0 > 0 ? UInt64($0) : nil },
            backend: backend,
            memoryBudgetProvider: { DeviceHardwareProfile.currentEffectiveModelMemoryBudgetBytes }
        )
        try await provider.prepare()
        providers[model.id] = provider
    }

    public func unload(model: InstalledModel) async {
        guard let provider = providers.removeValue(forKey: model.id) else { return }
        await provider.unload()
    }

    /// Returns the loaded `LlamaLocalProvider` after `load(model:)` succeeds.
    public func provider(for modelID: String) -> LlamaLocalProvider? {
        providers[modelID]
    }

    private func resolveSafeGGUFURL(for model: InstalledModel) throws -> URL {
        let candidate = model.artifactURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw ArchonModelsError.unsupportedArtifact("GGUF artifact does not exist at \(candidate.path).")
        }

        let targetURL: URL
        if isDirectory.boolValue {
            let contents = try fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            let ggufFiles = contents
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let first = ggufFiles.first else {
                throw ArchonModelsError.unsupportedArtifact("No .gguf file found inside \(candidate.lastPathComponent).")
            }
            targetURL = first
        } else {
            guard candidate.pathExtension.lowercased() == "gguf" else {
                throw ArchonModelsError.unsupportedArtifact("Expected a .gguf artifact at \(candidate.lastPathComponent).")
            }
            targetURL = candidate
        }

        if !configuration.allowSymlinks {
            let attributes = try fileManager.attributesOfItem(atPath: targetURL.path)
            if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw ArchonModelsError.unsupportedArtifact("Symbolic links are rejected for GGUF model artifacts.")
            }
        }
        return targetURL
    }
}
