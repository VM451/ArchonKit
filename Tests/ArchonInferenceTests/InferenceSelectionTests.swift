import Foundation
import ArchonAgent
import ArchonInference
import Testing

@Suite("ArchonInference provider selection")
struct InferenceSelectionTests {
    @Test("Rejects provider selection when neither a Core AI nor GGUF model is supplied")
    func rejectsMissingModels() async {
        await #expect(throws: InferenceSelectionError.noAvailableBackend) {
            _ = try await ArchonInference.makeProvider()
        }
    }

    @Test("Selects an explicit GGUF model through llama.cpp when no Core AI model is supplied", .enabled(if: LlamaNativeRuntime.info().isAvailable))
    func selectsExplicitGGUFWithoutCoreAI() async throws {
        let provider = try await ArchonInference.makeProvider(
            ggufModelURL: URL(fileURLWithPath: "/test-model.gguf")
        )
        #expect(provider is LlamaLocalProvider)
    }

    @Test("Validates a supplied Core AI model before considering the GGUF fallback", .enabled(if: ArchonInference.isCoreAIAvailable))
    func validatesNativeModelBeforeConsideringGGUFFallback() async {
        let model = ArchonInference.CoreAIModel(
            directory: URL(fileURLWithPath: "/test-model"),
            maxContextTokens: 4096,
            predictedPeakMemoryBytes: 0
        )
        await #expect(throws: CoreAIProviderError.memoryEstimateUnavailable) {
            _ = try await ArchonInference.makeProvider(
                coreAIModel: model,
                ggufModelURL: URL(fileURLWithPath: "/test-model.gguf")
            )
        }
    }
}
