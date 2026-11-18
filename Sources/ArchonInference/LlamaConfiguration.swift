import Foundation

/// Execution and sampling configuration for `LlamaLocalProvider`.
public struct LlamaConfiguration: Sendable, Codable, Equatable, Hashable {
    /// Maximum context window size requested when creating the llama context.
    public var contextLength: Int

    /// Logical batch size used during prompt evaluation.
    public var batchSize: Int

    /// Number of transformer layers to offload to Metal GPU (`-1` offloads all layers;
    /// automatically clamped to `0` on simulator targets).
    public var gpuLayerCount: Int32

    /// Explicit CPU thread count, or `nil` for an adaptive hardware default.
    public var threadCount: Int?

    /// Whether to memory-map GGUF weights from disk when supported by the OS.
    public var useMemoryMap: Bool

    /// Flash attention policy (`nil` lets llama.cpp choose automatically).
    public var useFlashAttention: Bool?

    /// Top-K sampling cutoff (`<= 0` disables top-k filtering).
    public var topK: Int32

    /// Min-P sampling threshold (`<= 0` disables min-p filtering).
    public var minP: Float

    /// Repetition penalty (`1.0` disables penalty).
    public var repeatPenalty: Float

    /// Trailing token window examined by the repetition penalty (`0` disables).
    public var repeatLastN: Int32

    /// Optional deterministic RNG seed for sampling (`nil` uses a random seed).
    public var seed: UInt32?

    /// Optional Jinja/chat template override when formatting messages.
    public var chatTemplateOverride: String?

    /// Enables GBNF JSON grammar constraint when `GenerationOptions.responseFormatJSON` is true.
    public var jsonGrammarEnabled: Bool

    /// Optional explicit GBNF grammar string (root symbol `"root"`) applied during sampling.
    public var customGBNFGrammar: String?

    /// Whether symbolic links are permitted for local GGUF paths (disabled by default).
    public var allowSymlinks: Bool

    public init(
        contextLength: Int = 4096,
        batchSize: Int = 512,
        gpuLayerCount: Int32 = -1,
        threadCount: Int? = nil,
        useMemoryMap: Bool = true,
        useFlashAttention: Bool? = nil,
        topK: Int32 = 40,
        minP: Float = 0.05,
        repeatPenalty: Float = 1.1,
        repeatLastN: Int32 = 64,
        seed: UInt32? = nil,
        chatTemplateOverride: String? = nil,
        jsonGrammarEnabled: Bool = true,
        customGBNFGrammar: String? = nil,
        allowSymlinks: Bool = false
    ) {
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.gpuLayerCount = gpuLayerCount
        self.threadCount = threadCount
        self.useMemoryMap = useMemoryMap
        self.useFlashAttention = useFlashAttention
        self.topK = topK
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.seed = seed
        self.chatTemplateOverride = chatTemplateOverride
        self.jsonGrammarEnabled = jsonGrammarEnabled
        self.customGBNFGrammar = customGBNFGrammar
        self.allowSymlinks = allowSymlinks
    }

    public static let standard = LlamaConfiguration()

    public static let memoryConstrained = LlamaConfiguration(
        contextLength: 2048,
        batchSize: 256,
        gpuLayerCount: -1,
        useMemoryMap: true
    )

    /// Validates configuration invariants before loading model weights.
    public func validate() throws {
        guard contextLength >= 128, contextLength <= 1_048_576 else {
            throw LlamaProviderError.invalidConfiguration("contextLength must be within 128...1048576.")
        }
        guard batchSize >= 1, batchSize <= contextLength else {
            throw LlamaProviderError.invalidConfiguration("batchSize must be within 1...contextLength.")
        }
        if let threadCount, threadCount <= 0 {
            throw LlamaProviderError.invalidConfiguration("threadCount must be positive when specified.")
        }
        guard minP.isFinite, minP >= 0, minP <= 1 else {
            throw LlamaProviderError.invalidConfiguration("minP must be finite within 0...1.")
        }
        guard repeatPenalty.isFinite, repeatPenalty > 0 else {
            throw LlamaProviderError.invalidConfiguration("repeatPenalty must be finite and greater than zero.")
        }
        guard repeatLastN >= 0 else {
            throw LlamaProviderError.invalidConfiguration("repeatLastN must be non-negative.")
        }
    }
}
