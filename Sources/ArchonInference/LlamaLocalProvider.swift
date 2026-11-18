import Foundation
import ArchonAgent
import ArchonCore

/// Local on-device `LLMProvider` powered by `ggml-org/llama.cpp` (`LlamaFramework`).
///
/// Enforces ArchonKit's local-first, fail-closed safety contracts before loading
/// any GGUF weights:
/// - Validates prompt shape, generation hyperparameters, and context bounds.
/// - Inspects GGUF headers without loading tensor buffers and validates file
///   paths (rejecting symlinks by default and verifying GGUF magic/version).
/// - Rejects models whose predicted peak resident memory exceeds the current
///   device budget (`DeviceHardwareProfile.currentEffectiveModelMemoryBudgetBytes`).
/// - Isolates all mutable C state inside a coordinator so concurrent graph
///   calls never race on a shared `llama_context`.
public final class LlamaLocalProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    public let source: LlamaModelSource
    public let configuration: LlamaConfiguration
    public let predictedPeakMemoryBytes: UInt64?

    private let sessionCoordinator: LlamaSessionCoordinator

    /// Creates a provider backed by a single local GGUF file.
    public convenience init(
        modelURL: URL,
        configuration: LlamaConfiguration = .standard,
        capabilities: ModelCapabilities? = nil,
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.init(
            source: .localFile(modelURL),
            configuration: configuration,
            capabilities: capabilities,
            predictedPeakMemoryBytes: predictedPeakMemoryBytes
        )
    }

    /// Creates a provider backed by a local GGUF source (single file or shards).
    public convenience init(
        source: LlamaModelSource,
        configuration: LlamaConfiguration = .standard,
        capabilities: ModelCapabilities? = nil,
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.init(
            source: source,
            configuration: configuration,
            capabilities: capabilities,
            predictedPeakMemoryBytes: predictedPeakMemoryBytes,
            backend: LlamaNativeBackend(),
            memoryBudgetProvider: { DeviceHardwareProfile.currentEffectiveModelMemoryBudgetBytes }
        )
    }

    init(
        source: LlamaModelSource,
        configuration: LlamaConfiguration = .standard,
        capabilities: ModelCapabilities? = nil,
        predictedPeakMemoryBytes: UInt64? = nil,
        backend: any LlamaBackendDriver,
        memoryBudgetProvider: @escaping @Sendable () -> UInt64
    ) {
        self.source = source
        self.configuration = configuration
        self.id = "llama.\(source.identifier)"
        self.predictedPeakMemoryBytes = predictedPeakMemoryBytes
        self.capabilities = capabilities ?? ModelCapabilities(
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsVision: false,
            supportsJSONSchema: configuration.jsonGrammarEnabled,
            maxContextTokens: configuration.contextLength,
            isOnDevice: true
        )
        self.sessionCoordinator = LlamaSessionCoordinator(
            source: source,
            configuration: configuration,
            explicitPeakMemoryBytes: predictedPeakMemoryBytes,
            backend: backend,
            memoryBudgetProvider: memoryBudgetProvider
        )
    }

    /// Parses GGUF header metadata without allocating tensor buffers or loading weights.
    public func inspectMetadata() throws -> LlamaGGUFMetadata {
        try LlamaGGUFInspector.inspect(source: source, allowSymlinks: configuration.allowSymlinks)
    }

    /// Computes predicted resident peak memory from GGUF header metadata.
    public func predictedPeakMemory() throws -> LlamaMemoryEstimate {
        let metadata = try inspectMetadata()
        return metadata.estimatedMemory(contextLength: configuration.contextLength)
    }

    /// Eagerly validates GGUF metadata, verifies memory headroom, and loads the model.
    public func prepare() async throws {
        try configuration.validate()
        _ = try await sessionCoordinator.loadedSession()
    }

    /// Unloads the resident llama model, context, and KV buffers.
    public func unload() async {
        await sessionCoordinator.unload()
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        try Self.validateRequestShape(
            prompt: prompt,
            options: options,
            configuration: configuration,
            capabilities: capabilities
        )

        var rawText = ""
        var promptTokens = 0
        var completionTokens = 0
        var finishReason = "stop"

        for try await event in await sessionCoordinator.streamEvents(
            prompt: prompt,
            tools: tools,
            options: options
        ) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                rawText += delta
            case .completed(let pTokens, let cTokens, _):
                promptTokens = pTokens
                completionTokens = cTokens
            }
        }

        let trimmed = Self.applyingStopSequences(to: rawText, options: options)
        let (cleanedText, toolCalls) = LlamaChatFormatting.extractToolCalls(
            from: trimmed,
            allowedTools: tools
        )
        if !toolCalls.isEmpty {
            finishReason = "tool_calls"
        }

        return ModelResponse(
            text: cleanedText,
            toolCalls: toolCalls,
            finishReason: finishReason,
            usage: TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
        )
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [sessionCoordinator, prompt, tools, options, configuration, capabilities] in
                do {
                    try Self.validateRequestShape(
                        prompt: prompt,
                        options: options,
                        configuration: configuration,
                        capabilities: capabilities
                    )

                    var accumulated = ""
                    for try await event in await sessionCoordinator.streamEvents(
                        prompt: prompt,
                        tools: tools,
                        options: options
                    ) {
                        try Task.checkCancellation()
                        switch event {
                        case .textDelta(let delta):
                            accumulated += delta
                            if tools.isEmpty {
                                continuation.yield(ModelResponseChunk(deltaText: delta))
                            }
                        case .completed:
                            break
                        }
                    }

                    if !tools.isEmpty {
                        let trimmed = Self.applyingStopSequences(to: accumulated, options: options)
                        let (cleaned, toolCalls) = LlamaChatFormatting.extractToolCalls(
                            from: trimmed,
                            allowedTools: tools
                        )
                        if !cleaned.isEmpty {
                            continuation.yield(ModelResponseChunk(deltaText: cleaned))
                        }
                        if !toolCalls.isEmpty {
                            let chunks = toolCalls.enumerated().map { index, call in
                                ToolCallChunk(
                                    index: index,
                                    id: call.id,
                                    name: call.name,
                                    argumentsDelta: call.arguments
                                )
                            }
                            continuation.yield(ModelResponseChunk(toolCallChunks: chunks))
                        }
                    }

                    continuation.yield(ModelResponseChunk(isFinished: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Validates request shape before touching files or loading weights.
    static func validateRequestShape(
        prompt: [ChatMessage],
        options: GenerationOptions,
        configuration: LlamaConfiguration,
        capabilities: ModelCapabilities
    ) throws {
        try configuration.validate()
        guard !LocalRequestValidation.isEffectivelyEmpty(prompt) else {
            throw LlamaProviderError.emptyPrompt
        }
        if let problem = LocalRequestValidation.optionsProblem(options) {
            throw LlamaProviderError.invalidOptions(problem)
        }
        let effectiveMaxContext = min(capabilities.maxContextTokens, configuration.contextLength)
        let estimatedTokens = LocalRequestValidation.estimatedTokenCount(for: prompt)
        guard estimatedTokens <= effectiveMaxContext else {
            throw LlamaProviderError.contextWindowExceeded(estimatedTokens, effectiveMaxContext)
        }
    }

    private static func applyingStopSequences(to text: String, options: GenerationOptions) -> String {
        guard let range = options.stopSequences
            .filter({ !$0.isEmpty })
            .compactMap({ text.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            return text
        }
        return String(text[..<range.lowerBound])
    }
}
