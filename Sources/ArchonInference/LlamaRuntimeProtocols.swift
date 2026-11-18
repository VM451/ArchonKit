import Foundation
import ArchonAgent
import ArchonCore

/// Capabilities and runtime diagnostics reported by the linked `llama.cpp` framework.
public struct LlamaRuntimeInfo: Codable, Equatable, Sendable {
    public let isAvailable: Bool
    public let llamaVersion: String?
    public let supportsMemoryMap: Bool
    public let supportsGPUOffload: Bool
    public let maxDevices: Int
    public let builtinChatTemplates: [String]

    public init(
        isAvailable: Bool,
        llamaVersion: String?,
        supportsMemoryMap: Bool,
        supportsGPUOffload: Bool,
        maxDevices: Int,
        builtinChatTemplates: [String]
    ) {
        self.isAvailable = isAvailable
        self.llamaVersion = llamaVersion
        self.supportsMemoryMap = supportsMemoryMap
        self.supportsGPUOffload = supportsGPUOffload
        self.maxDevices = maxDevices
        self.builtinChatTemplates = builtinChatTemplates
    }
}

// MARK: - Internal Engine Seam for Deterministic Testing

enum LlamaStreamTokenEvent: Sendable {
    case textDelta(String)
    case completed(promptTokens: Int, completionTokens: Int, hitEOG: Bool)
}

protocol LlamaLoadedSession: AnyObject, Sendable {
    var effectiveContextLength: Int { get }
    func generateStream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions,
        configuration: LlamaConfiguration
    ) -> AsyncThrowingStream<LlamaStreamTokenEvent, Error>
    func unload() async
}

protocol LlamaBackendDriver: Sendable {
    func loadSession(
        source: LlamaModelSource,
        configuration: LlamaConfiguration,
        metadata: LlamaGGUFMetadata
    ) async throws -> any LlamaLoadedSession
}
