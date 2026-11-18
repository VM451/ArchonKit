import Foundation
import ArchonAgent
import ArchonCore
@testable import ArchonInference

final class StubLlamaBackend: LlamaBackendDriver, @unchecked Sendable {
    var loadCount = 0
    var lastOptions: GenerationOptions?
    var chunksToEmit: [String]
    var delayPerChunk: Duration

    init(chunksToEmit: [String] = ["Hello", " world"], delayPerChunk: Duration = .zero) {
        self.chunksToEmit = chunksToEmit
        self.delayPerChunk = delayPerChunk
    }

    func loadSession(
        source: LlamaModelSource,
        configuration: LlamaConfiguration,
        metadata: LlamaGGUFMetadata
    ) async throws -> any LlamaLoadedSession {
        loadCount += 1
        return StubLlamaSession(
            effectiveContextLength: configuration.contextLength,
            chunksToEmit: chunksToEmit,
            delayPerChunk: delayPerChunk,
            onRequest: { [weak self] options in
                self?.lastOptions = options
            }
        )
    }
}

final class StubLlamaSession: LlamaLoadedSession, @unchecked Sendable {
    let effectiveContextLength: Int
    private let chunksToEmit: [String]
    private let delayPerChunk: Duration
    private let onRequest: @Sendable (GenerationOptions) -> Void

    init(
        effectiveContextLength: Int,
        chunksToEmit: [String],
        delayPerChunk: Duration,
        onRequest: @escaping @Sendable (GenerationOptions) -> Void
    ) {
        self.effectiveContextLength = effectiveContextLength
        self.chunksToEmit = chunksToEmit
        self.delayPerChunk = delayPerChunk
        self.onRequest = onRequest
    }

    func generateStream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions,
        configuration: LlamaConfiguration
    ) -> AsyncThrowingStream<LlamaStreamTokenEvent, Error> {
        onRequest(options)
        let chunks = chunksToEmit
        let delay = delayPerChunk
        return AsyncThrowingStream { continuation in
            let task = Task {
                var stopFilter = LlamaStopSequenceFilter(stopSequences: options.stopSequences)
                var count = 0
                for chunk in chunks {
                    try Task.checkCancellation()
                    if delay > .zero {
                        try await Task.sleep(for: delay)
                    }
                    count += 1
                    let safe = stopFilter.push(chunk)
                    if !safe.isEmpty {
                        continuation.yield(.textDelta(safe))
                    }
                    if stopFilter.didMatchStopSequence {
                        break
                    }
                }
                let rem = stopFilter.flush()
                if !rem.isEmpty {
                    continuation.yield(.textDelta(rem))
                }
                continuation.yield(.completed(promptTokens: 12, completionTokens: count, hitEOG: true))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func unload() async {}
}
