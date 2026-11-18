import Foundation
import ArchonAgent
import ArchonCore

/// Serializes session loading, unloading, and single-context generation execution.
actor LlamaSessionCoordinator {
    private let source: LlamaModelSource
    private let configuration: LlamaConfiguration
    private let explicitPeakMemoryBytes: UInt64?
    private let backend: any LlamaBackendDriver
    private let memoryBudgetProvider: @Sendable () -> UInt64

    private var cachedSession: (any LlamaLoadedSession)?
    private var loadingTask: Task<any LlamaLoadedSession, Error>?
    private var activeGenerationLock = false
    private var generationWaiters: [CheckedContinuation<Void, Error>] = []

    init(
        source: LlamaModelSource,
        configuration: LlamaConfiguration,
        explicitPeakMemoryBytes: UInt64?,
        backend: any LlamaBackendDriver,
        memoryBudgetProvider: @escaping @Sendable () -> UInt64
    ) {
        self.source = source
        self.configuration = configuration
        self.explicitPeakMemoryBytes = explicitPeakMemoryBytes
        self.backend = backend
        self.memoryBudgetProvider = memoryBudgetProvider
    }

    func loadedSession() async throws -> any LlamaLoadedSession {
        if let cachedSession {
            return cachedSession
        }
        if let loadingTask {
            return try await loadingTask.value
        }

        let source = self.source
        let configuration = self.configuration
        let explicitPeak = self.explicitPeakMemoryBytes
        let backend = self.backend
        let budgetProvider = self.memoryBudgetProvider

        let task = Task<any LlamaLoadedSession, Error> {
            try configuration.validate()
            let metadata = try LlamaGGUFInspector.inspect(
                source: source,
                allowSymlinks: configuration.allowSymlinks
            )
            let predictedPeak = explicitPeak
                ?? metadata.estimatedMemory(contextLength: configuration.contextLength).peakBytes
            guard predictedPeak > 0 else {
                throw LlamaProviderError.memoryEstimateUnavailable
            }
            let availableBudget = budgetProvider()
            guard predictedPeak <= availableBudget else {
                throw LlamaProviderError.insufficientMemory(
                    predictedPeakBytes: predictedPeak,
                    availableBudgetBytes: availableBudget
                )
            }
            try Task.checkCancellation()
            return try await backend.loadSession(
                source: source,
                configuration: configuration,
                metadata: metadata
            )
        }

        loadingTask = task
        do {
            let session = try await task.value
            cachedSession = session
            loadingTask = nil
            return session
        } catch {
            loadingTask = nil
            throw error
        }
    }

    func streamEvents(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<LlamaStreamTokenEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await acquireGenerationSlot()
                    defer { releaseGenerationSlot() }

                    let session = try await loadedSession()
                    for try await event in session.generateStream(
                        prompt: prompt,
                        tools: tools,
                        options: options,
                        configuration: configuration
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
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

    func unload() async {
        loadingTask?.cancel()
        loadingTask = nil
        if let session = cachedSession {
            cachedSession = nil
            await session.unload()
        }
    }

    private func acquireGenerationSlot() async throws {
        try Task.checkCancellation()
        if !activeGenerationLock {
            activeGenerationLock = true
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            generationWaiters.append(continuation)
        }
    }

    private func releaseGenerationSlot() {
        while !generationWaiters.isEmpty {
            let next = generationWaiters.removeFirst()
            next.resume()
            return
        }
        activeGenerationLock = false
    }
}
