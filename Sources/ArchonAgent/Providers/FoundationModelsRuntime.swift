import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Production adapter for Apple's Foundation Models runtime.
///
/// Uses the system model (`SystemLanguageModel.default`) unless the runtime
/// was initialized with an explicit Foundation Models-compatible `LanguageModel`,
/// such as an exported Apple Core AI asset. Both paths execute through
/// `LanguageModelSession`.
public struct FoundationModelsRuntime: AppleFoundationModelRuntime, Sendable {
#if canImport(FoundationModels)
    /// Builds a `LanguageModelSession` around an explicitly supplied model.
    /// `nil` means the runtime uses `SystemLanguageModel.default`.
    private let explicitModelSession: (@Sendable (String?) -> LanguageModelSession)?

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    package init<ExplicitModel: LanguageModel>(model: ExplicitModel) {
        self.explicitModelSession = { instructions in
            LanguageModelSession(model: model, instructions: instructions)
        }
    }

    private func makeSession(systemInstructions: String?) -> LanguageModelSession {
        if let explicitModelSession {
            return explicitModelSession(systemInstructions)
        }
        return LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: systemInstructions
        )
    }
#endif

    public init() {
        #if canImport(FoundationModels)
        self.explicitModelSession = nil
        #endif
    }

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *), explicitModelSession != nil {
            return true
        }
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public func respond(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) async throws -> AppleFoundationModelRuntimeResponse {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleFoundationModelError.emptyPrompt
        }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            guard isAvailable else {
                throw AppleFoundationModelError.modelUnavailable
            }
            let session = makeSession(systemInstructions: systemInstructions)
            let foundationOptions = FoundationModels.GenerationOptions(
                temperature: options.temperature,
                maximumResponseTokens: options.maxTokens
            )
            let response = try await session.respond(to: prompt, options: foundationOptions)
            let promptTokens = response.usage.input.totalTokenCount
            let completionTokens = response.usage.output.totalTokenCount
            let usage = TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
            return AppleFoundationModelRuntimeResponse(text: response.content, usage: usage)
        }
        #endif

        throw AppleFoundationModelError.modelUnavailable
    }

    public func stream(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AppleFoundationModelError.emptyPrompt
                    }

                    #if canImport(FoundationModels)
                    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                        guard isAvailable else {
                            throw AppleFoundationModelError.modelUnavailable
                        }
                        let session = makeSession(systemInstructions: systemInstructions)
                        let foundationOptions = FoundationModels.GenerationOptions(
                            temperature: options.temperature,
                            maximumResponseTokens: options.maxTokens
                        )
                        var previousText = ""
                        for try await snapshot in session.streamResponse(to: prompt, options: foundationOptions) {
                            try Task.checkCancellation()
                            let currentText = snapshot.content
                            let delta: String
                            if currentText.hasPrefix(previousText) {
                                delta = String(currentText.dropFirst(previousText.count))
                            } else {
                                delta = currentText
                            }
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                            previousText = currentText
                        }
                        continuation.finish()
                        return
                    }
                    #endif

                    throw AppleFoundationModelError.modelUnavailable
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
