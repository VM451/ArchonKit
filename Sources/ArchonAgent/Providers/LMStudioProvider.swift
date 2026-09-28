import Foundation

/// LM Studio local inference server over its OpenAI-compatible endpoint.
///
/// LM Studio runs models locally on the Mac and serves them at
/// `http://localhost:1234/v1` by default (`POST /v1/chat/completions` with
/// OpenAI request/response/SSE shapes). This adapter is a thin wrapper over
/// the shared `OpenAIProvider` transport: only the default base URL, the
/// provider id, the local capabilities baseline, and the ZeroCloud posture
/// differ.
///
/// Host responsibilities (macOS apps especially):
///
/// - Start the LM Studio server and load a model there first; this provider
///   performs inference only and never launches, downloads, or manages
///   LM Studio models.
/// - Pass the exact loaded model identifier via `model`. The server routes
///   to the loaded model; `"local-model"` is only a placeholder default.
/// - LM Studio ignores the API key unless the user sets one in the server
///   settings, so `apiKey` defaults to empty. A host-set server key belongs
///   in the app's own credential storage and is passed here per call site.
/// - Custom `baseURL` values (for example a changed port or a LAN host) are
///   allowed, but under `ZeroCloudMode` only loopback endpoints are
///   permitted; anything else fails closed with `GraphError.zeroCloudViolation`
///   before any request is built.
/// - Capabilities are a local baseline (on-device, streaming transport,
///   tool passthrough), not a per-model promise: tool calling, vision, and
///   context length depend on the model loaded in LM Studio. Hosts serving a
///   known model should narrow `capabilities` to what that model implements.
///
/// A localhost server is an explicit host integration, not an in-process
/// runtime: it never participates in user-facing catalog discovery or
/// adaptive on-device routing.
public final class LMStudioProvider: LLMProvider, @unchecked Sendable {
    /// LM Studio's default local server root (`POST /v1/chat/completions`).
    public static let defaultBaseURL = URL(string: "http://localhost:1234/v1")!

    public let id: String
    public let capabilities: ModelCapabilities
    public let endpoint: URL
    public let model: String
    private let openAIWrapper: OpenAIProvider

    public init(
        model: String = "local-model",
        baseURL: URL = LMStudioProvider.defaultBaseURL,
        apiKey: String = "",
        capabilities: ModelCapabilities = .mlxLocal,
        urlSession: URLSession = .shared
    ) {
        self.id = "lmstudio.\(model)"
        self.capabilities = capabilities
        self.endpoint = baseURL.appendingPathComponent("chat/completions")
        self.model = model
        self.openAIWrapper = OpenAIProvider(
            apiKey: apiKey,
            model: model,
            endpoint: endpoint,
            capabilities: capabilities,
            urlSession: urlSession,
            localServerName: "LM Studio"
        )
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        try await openAIWrapper.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        openAIWrapper.stream(prompt: prompt, tools: tools, options: options)
    }
}
