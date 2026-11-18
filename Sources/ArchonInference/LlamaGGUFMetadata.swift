import Foundation

/// Predicted resident memory breakdown for a GGUF model and context configuration.
public struct LlamaMemoryEstimate: Codable, Equatable, Hashable, Sendable {
    public let weightsBytes: UInt64
    public let runtimeOverheadBytes: UInt64
    public let kvCacheBytes: UInt64
    public let safetyMarginBytes: UInt64
    public let peakBytes: UInt64
    public let isHeuristic: Bool

    public init(
        weightsBytes: UInt64,
        runtimeOverheadBytes: UInt64,
        kvCacheBytes: UInt64,
        safetyMarginBytes: UInt64,
        peakBytes: UInt64,
        isHeuristic: Bool
    ) {
        self.weightsBytes = weightsBytes
        self.runtimeOverheadBytes = runtimeOverheadBytes
        self.kvCacheBytes = kvCacheBytes
        self.safetyMarginBytes = safetyMarginBytes
        self.peakBytes = peakBytes
        self.isHeuristic = isHeuristic
    }
}

/// Metadata parsed directly from a GGUF file header without loading tensor weights.
public struct LlamaGGUFMetadata: Codable, Equatable, Hashable, Sendable {
    public let formatVersion: UInt32
    public let tensorCount: UInt64
    public let metadataKVCount: UInt64
    public let architecture: String?
    public let modelName: String?
    public let fileTypeCode: UInt32?
    public let quantizationLabel: String?
    public let parameterCount: UInt64?
    public let contextLength: Int?
    public let embeddingLength: Int?
    public let blockCount: Int?
    public let attentionHeadCount: Int?
    public let attentionHeadCountKV: Int?
    public let keyLength: Int?
    public let valueLength: Int?
    public let chatTemplate: String?
    public let fileSizeBytes: UInt64
    public let shardCount: Int
    public let kvCacheBytesPerToken: UInt64?

    public init(
        formatVersion: UInt32,
        tensorCount: UInt64,
        metadataKVCount: UInt64,
        architecture: String? = nil,
        modelName: String? = nil,
        fileTypeCode: UInt32? = nil,
        quantizationLabel: String? = nil,
        parameterCount: UInt64? = nil,
        contextLength: Int? = nil,
        embeddingLength: Int? = nil,
        blockCount: Int? = nil,
        attentionHeadCount: Int? = nil,
        attentionHeadCountKV: Int? = nil,
        keyLength: Int? = nil,
        valueLength: Int? = nil,
        chatTemplate: String? = nil,
        fileSizeBytes: UInt64,
        shardCount: Int = 1,
        kvCacheBytesPerToken: UInt64? = nil
    ) {
        self.formatVersion = formatVersion
        self.tensorCount = tensorCount
        self.metadataKVCount = metadataKVCount
        self.architecture = architecture
        self.modelName = modelName
        self.fileTypeCode = fileTypeCode
        self.quantizationLabel = quantizationLabel
        self.parameterCount = parameterCount
        self.contextLength = contextLength
        self.embeddingLength = embeddingLength
        self.blockCount = blockCount
        self.attentionHeadCount = attentionHeadCount
        self.attentionHeadCountKV = attentionHeadCountKV
        self.keyLength = keyLength
        self.valueLength = valueLength
        self.chatTemplate = chatTemplate
        self.fileSizeBytes = fileSizeBytes
        self.shardCount = shardCount
        self.kvCacheBytesPerToken = kvCacheBytesPerToken
    }

    /// Predicts peak memory required to load and run this GGUF artifact at `contextLength`.
    public func estimatedMemory(contextLength requestedContextLength: Int) -> LlamaMemoryEstimate {
        let clampedContext = UInt64(max(1, requestedContextLength))
        let effectiveWeights = max(fileSizeBytes, 1)
        let runtimeOverhead = max(
            128 * 1_048_576,
            saturatingMultiply(effectiveWeights, numerator: 20, denominator: 100)
        )
        let kvCache: UInt64
        let isHeuristic: Bool
        if let kvCacheBytesPerToken, kvCacheBytesPerToken > 0 {
            let (product, overflow) = kvCacheBytesPerToken.multipliedReportingOverflow(by: clampedContext)
            kvCache = overflow ? UInt64.max : product
            isHeuristic = false
        } else {
            let contextMultiplier = min(max(Double(clampedContext) / 4_096.0, 1.0), 8.0)
            let heuristic = Double(effectiveWeights) * 0.10 * contextMultiplier
            kvCache = max(64 * 1_048_576, heuristic >= Double(UInt64.max) ? UInt64.max : UInt64(heuristic.rounded(.up)))
            isHeuristic = true
        }
        let subtotal = saturatingAdd(effectiveWeights, runtimeOverhead, kvCache)
        let safetyMargin = max(
            64 * 1_048_576,
            saturatingMultiply(subtotal, numerator: 10, denominator: 100)
        )
        let peak = saturatingAdd(subtotal, safetyMargin)
        return LlamaMemoryEstimate(
            weightsBytes: fileSizeBytes,
            runtimeOverheadBytes: runtimeOverhead,
            kvCacheBytes: kvCache,
            safetyMarginBytes: safetyMargin,
            peakBytes: peak,
            isHeuristic: isHeuristic
        )
    }

    private func saturatingMultiply(_ value: UInt64, numerator: UInt64, denominator: UInt64) -> UInt64 {
        let divided = value / denominator
        let remainder = value % denominator
        let (part1, ov1) = divided.multipliedReportingOverflow(by: numerator)
        let (part2, ov2) = remainder.multipliedReportingOverflow(by: numerator)
        if ov1 || ov2 { return UInt64.max }
        let (sum, ov3) = part1.addingReportingOverflow((part2 + denominator - 1) / denominator)
        return ov3 ? UInt64.max : sum
    }

    private func saturatingAdd(_ values: UInt64...) -> UInt64 {
        values.reduce(into: UInt64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? UInt64.max : sum
        }
    }
}
