import Foundation
import ArchonAgent

#if canImport(CoreAILanguageModels) && canImport(FoundationModels)
import CoreAILanguageModels
import FoundationModels
#endif

/// Errors raised when no supported on-device inference backend can be selected.
public enum InferenceSelectionError: Error, LocalizedError, Sendable, Equatable {
    case noAvailableBackend

    public var errorDescription: String? {
        "Supply an Apple Core AI model or GGUF model supported by this device."
    }
}

/// Selects an on-device text provider for an explicitly supplied local model.
///
/// `ArchonInference` exposes exactly two runtime choices: Apple Core AI first,
/// then llama.cpp. Neither path downloads weights, falls back to a cloud
/// provider, or selects the Apple Intelligence system model implicitly — a
/// Core AI asset directory or a GGUF file must be supplied explicitly.
public enum ArchonInference {
    /// A locally exported Apple Core AI model asset.
    ///
    /// `directory` must point at a Core AI bundle containing the compiled
    /// `.aimodel` assets plus tokenizer/config files, as produced by Apple's
    /// Core AI tooling. `predictedPeakMemoryBytes` must come from the model's
    /// catalog or measurement data; preparation is refused without it.
    public struct CoreAIModel: Sendable {
        public let directory: URL
        public let maxContextTokens: Int
        public let predictedPeakMemoryBytes: UInt64

        public init(directory: URL, maxContextTokens: Int, predictedPeakMemoryBytes: UInt64) {
            self.directory = directory
            self.maxContextTokens = maxContextTokens
            self.predictedPeakMemoryBytes = predictedPeakMemoryBytes
        }
    }

    /// Whether this device can run an exported Apple Core AI model.
    public static var isCoreAIAvailable: Bool {
        #if canImport(CoreAILanguageModels) && canImport(FoundationModels) && !targetEnvironment(simulator)
        return CoreAIProvider.isAvailable
        #else
        return false
        #endif
    }

    /// Prefers Core AI. Falls back to llama.cpp only when Core AI is unavailable
    /// or no Core AI asset was supplied; native preparation errors propagate.
    public static func makeProvider(
        coreAIModel: CoreAIModel? = nil,
        ggufModelURL: URL? = nil,
        llamaConfiguration: LlamaConfiguration = .standard
    ) async throws -> any LLMProvider {
        #if canImport(CoreAILanguageModels) && canImport(FoundationModels) && !targetEnvironment(simulator)
        if let coreAIModel, isCoreAIAvailable {
            guard coreAIModel.directory.isFileURL else {
                throw CoreAIProviderError.invalidModelAsset(coreAIModel.directory.absoluteString)
            }
            guard coreAIModel.maxContextTokens > 0 else {
                throw CoreAIProviderError.invalidOptions("Core AI context length must be positive.")
            }
            guard coreAIModel.predictedPeakMemoryBytes > 0 else {
                throw CoreAIProviderError.memoryEstimateUnavailable
            }
            let availableBudgetBytes = DeviceHardwareProfile.currentEffectiveModelMemoryBudgetBytes
            guard coreAIModel.predictedPeakMemoryBytes <= availableBudgetBytes else {
                throw CoreAIProviderError.insufficientMemory(
                    predictedPeakBytes: coreAIModel.predictedPeakMemoryBytes,
                    availableBudgetBytes: availableBudgetBytes
                )
            }
            let model = try await CoreAILanguageModel(resourcesAt: coreAIModel.directory, mode: .eager)
            return AppleFoundationModelProvider(
                id: "coreai.\(coreAIModel.directory.lastPathComponent)",
                capabilities: ModelCapabilities(
                    supportsToolCalling: false,
                    supportsJSONSchema: false,
                    maxContextTokens: coreAIModel.maxContextTokens,
                    isOnDevice: true
                ),
                runtime: FoundationModelsRuntime(model: model)
            )
        }
        #endif
        #if canImport(llama)
        if let ggufModelURL {
            return LlamaLocalProvider(modelURL: ggufModelURL, configuration: llamaConfiguration)
        }
        #endif
        throw InferenceSelectionError.noAvailableBackend
    }
}
