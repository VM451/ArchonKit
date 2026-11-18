import Foundation
import os
import ArchonAgent
import ArchonCore

#if canImport(llama)

final class LlamaNativeSession: LlamaLoadedSession, @unchecked Sendable {
    let effectiveContextLength: Int
    private let box: LlamaContextBox
    private let stateLock = OSAllocatedUnfairLock(initialState: false) // true = unloaded

    init(box: LlamaContextBox) {
        self.box = box
        self.effectiveContextLength = box.effectiveContextLength
    }

    func generateStream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions,
        configuration: LlamaConfiguration
    ) -> AsyncThrowingStream<LlamaStreamTokenEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = self.box
            let isUnloaded = self.stateLock.withLock { $0 }
            if isUnloaded {
                continuation.finish(throwing: LlamaProviderError.contextCreationFailed("Session has already been unloaded."))
                return
            }

            box.abortFlag.reset()
            box.queue.async { [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                if self.stateLock.withLock({ $0 }) || box.abortFlag.isAborted {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                do {
                    try LlamaNativeGeneration.run(
                        box: box,
                        prompt: prompt,
                        tools: tools,
                        options: options,
                        configuration: configuration,
                        onEvent: { event in
                            continuation.yield(event)
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                box.abortFlag.abort()
            }
        }
    }

    func unload() async {
        box.abortFlag.abort()
        let shouldFree = stateLock.withLock { unloaded -> Bool in
            if unloaded { return false }
            unloaded = true
            return true
        }
        guard shouldFree else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.queue.async { [box] in
                box.freeResources()
                continuation.resume()
            }
        }
    }
}

#endif
