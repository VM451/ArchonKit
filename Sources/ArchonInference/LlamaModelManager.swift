import Foundation
import ArchonAgent
import ArchonCore
import ArchonModels

/// Managed lifecycle state for a GGUF model registered with `LlamaModelManager`.
public enum LlamaManagedModelState: String, Codable, Equatable, Sendable {
    case unregistered
    case registered
    case warming
    case ready
    case cancelled
    case failed
    case unloaded
}

/// Registered GGUF model descriptor held by `LlamaModelManager`.
public struct LlamaRegisteredModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: LlamaModelSource
    public let configuration: LlamaConfiguration
    public let capabilities: ModelCapabilities
    public let predictedPeakMemoryBytes: UInt64?

    public init(
        id: String,
        source: LlamaModelSource,
        configuration: LlamaConfiguration = .standard,
        capabilities: ModelCapabilities? = nil,
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.id = id
        self.source = source
        self.configuration = configuration
        self.capabilities = capabilities ?? ModelCapabilities(
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsVision: false,
            supportsJSONSchema: configuration.jsonGrammarEnabled,
            maxContextTokens: configuration.contextLength,
            isOnDevice: true
        )
        self.predictedPeakMemoryBytes = predictedPeakMemoryBytes
    }
}

/// Thread-safe lifecycle coordinator for managing one or more GGUF models
/// under ArchonKit's process memory budget, pressure events, and switching semantics.
public actor LlamaModelManager {
    private let backend: any LlamaBackendDriver
    private var entries: [String: LlamaRegisteredModel] = [:]
    private var providers: [String: LlamaLocalProvider] = [:]
    private var peakEstimates: [String: UInt64] = [:]
    private var states: [String: LlamaManagedModelState] = [:]
    private var loadingTasks: [String: Task<Void, Error>] = [:]

    public init() {
        self.backend = LlamaNativeBackend()
    }

    init(backend: any LlamaBackendDriver) {
        self.backend = backend
    }

    /// Registers a GGUF model for managed loading and switching.
    public func register(_ model: LlamaRegisteredModel) {
        entries[model.id] = model
        if states[model.id] == nil {
            states[model.id] = .registered
        }
    }

    public func state(for modelID: String) -> LlamaManagedModelState {
        states[modelID] ?? .unregistered
    }

    public func loadedModelIDs() -> [String] {
        states.compactMap { id, state in
            state == .ready ? id : nil
        }.sorted()
    }

    /// Returns total predicted peak bytes across all currently loaded GGUF models.
    public func loadedMemoryBytes() -> UInt64 {
        loadedModelIDs().reduce(into: UInt64(0)) { total, id in
            let estimate = peakEstimates[id] ?? UInt64.max
            let (sum, overflow) = total.addingReportingOverflow(estimate)
            total = overflow ? UInt64.max : sum
        }
    }

    /// Returns the loaded `LlamaLocalProvider` when `modelID` is ready.
    public func provider(for modelID: String) -> LlamaLocalProvider? {
        guard states[modelID] == .ready else { return nil }
        return providers[modelID]
    }

    /// Loads a registered GGUF model after inspecting metadata and enforcing the
    /// aggregate memory budget across resident GGUF models.
    public func load(
        modelID: String,
        on device: ArchonDeviceCapabilities = .current
    ) async throws {
        if states[modelID] == .ready, providers[modelID] != nil {
            return
        }
        guard let entry = entries[modelID] else {
            throw LlamaProviderError.modelNotRegistered(modelID)
        }
        if let existingTask = loadingTasks[modelID] {
            try await existingTask.value
            return
        }

        if device.thermalState == .serious || device.thermalState == .critical {
            throw LlamaProviderError.insufficientMemory(
                predictedPeakBytes: entry.predictedPeakMemoryBytes ?? 1,
                availableBudgetBytes: 0
            )
        }

        try entry.configuration.validate()
        let metadata = try LlamaGGUFInspector.inspect(
            source: entry.source,
            allowSymlinks: entry.configuration.allowSymlinks
        )
        let candidatePeak = entry.predictedPeakMemoryBytes
            ?? metadata.estimatedMemory(contextLength: entry.configuration.contextLength).peakBytes
        let residentOtherBytes = loadedModelIDs()
            .filter { $0 != modelID }
            .reduce(into: UInt64(0)) { total, id in
                let estimate = peakEstimates[id] ?? UInt64.max
                let (sum, overflow) = total.addingReportingOverflow(estimate)
                total = overflow ? UInt64.max : sum
            }

        let budget = device.recommendedModelMemoryBytes
        let remainingBudget = budget > residentOtherBytes ? budget - residentOtherBytes : 0
        guard candidatePeak <= remainingBudget else {
            throw LlamaProviderError.insufficientMemory(
                predictedPeakBytes: candidatePeak,
                availableBudgetBytes: remainingBudget
            )
        }

        states[modelID] = .warming
        let provider = LlamaLocalProvider(
            source: entry.source,
            configuration: entry.configuration,
            capabilities: entry.capabilities,
            predictedPeakMemoryBytes: candidatePeak,
            backend: backend,
            memoryBudgetProvider: { remainingBudget }
        )

        let task = Task {
            try await provider.prepare()
            try Task.checkCancellation()
        }
        loadingTasks[modelID] = task

        do {
            try await task.value
            loadingTasks[modelID] = nil
            providers[modelID] = provider
            peakEstimates[modelID] = candidatePeak
            states[modelID] = .ready
        } catch is CancellationError {
            loadingTasks[modelID] = nil
            await provider.unload()
            states[modelID] = .cancelled
            throw CancellationError()
        } catch {
            loadingTasks[modelID] = nil
            await provider.unload()
            states[modelID] = .failed
            throw error
        }
    }

    /// Unloads all currently resident GGUF models, then loads `modelID`.
    public func switchTo(
        modelID: String,
        on device: ArchonDeviceCapabilities = .current
    ) async throws {
        guard entries[modelID] != nil else {
            throw LlamaProviderError.modelNotRegistered(modelID)
        }
        for loadedID in loadedModelIDs() where loadedID != modelID {
            await unload(modelID: loadedID)
        }
        try await load(modelID: modelID, on: device)
    }

    /// Unloads a single model if warming or ready.
    public func unload(modelID: String) async {
        loadingTasks[modelID]?.cancel()
        loadingTasks[modelID] = nil
        if let provider = providers.removeValue(forKey: modelID) {
            await provider.unload()
        }
        peakEstimates.removeValue(forKey: modelID)
        if entries[modelID] != nil {
            states[modelID] = .unloaded
        }
    }

    /// Releases every resident model.
    public func unloadAll() async {
        for id in Array(Set(providers.keys).union(loadingTasks.keys)) {
            await unload(modelID: id)
        }
    }

    /// Responds to OS memory-pressure warnings by unloading resident models on warning/critical pressure.
    public func handleMemoryPressure(_ pressure: ModelMemoryPressure) async {
        switch pressure {
        case .normal:
            break
        case .warning, .critical:
            await unloadAll()
        }
    }
}
