import Foundation

/// Pure-Swift, bounded GGUF binary header inspector.
///
/// Inspects GGUF v2/v3 metadata and validates path safety without loading
/// tensor weights or allocating inference buffers.
public enum LlamaGGUFInspector: Sendable {
    private static let magic: UInt32 = 0x4655_4747 // "GGUF" little-endian
    private static let supportedVersions: Set<UInt32> = [2, 3]
    private static let maximumKVCount: UInt64 = 100_000
    private static let maximumTensorCount: UInt64 = 1_000_000
    private static let maximumKeyLength: UInt64 = 4_096
    private static let maximumRetainedStringLength: UInt64 = 262_144
    private static let maximumSkippableStringLength: UInt64 = 64 * 1_048_576
    private static let maximumArrayCount: UInt64 = 1_000_000

    /// Validates paths and parses GGUF metadata from `source`.
    public static func inspect(
        source: LlamaModelSource,
        allowSymlinks: Bool = false
    ) throws -> LlamaGGUFMetadata {
        let urls = source.fileURLs
        guard !urls.isEmpty else {
            throw LlamaProviderError.invalidModelPath("GGUF model source contains no file URLs.")
        }

        var totalBytes: UInt64 = 0
        for url in urls {
            totalBytes = saturatingAdd(totalBytes, try validateFileURL(url, allowSymlinks: allowSymlinks))
        }

        let metadata = try inspectSingleHeader(at: urls[0], totalSizeBytes: totalBytes, shardCount: urls.count)
        // For split shards, ensure subsequent files are also valid GGUF headers.
        for shardURL in urls.dropFirst() {
            let cursor = try LlamaGGUFBinaryReader(url: shardURL)
            defer { cursor.close() }
            _ = try readValidatedPrefix(from: cursor, fileName: shardURL.lastPathComponent)
        }
        return metadata
    }

    private static func validateFileURL(_ url: URL, allowSymlinks: Bool) throws -> UInt64 {
        guard url.isFileURL else {
            throw LlamaProviderError.invalidModelPath("Only local file:// URLs are permitted.")
        }
        let path = url.path
        guard !path.isEmpty else {
            throw LlamaProviderError.invalidModelPath("Model file path must not be empty.")
        }

        let fileManager = FileManager.default
        if !allowSymlinks {
            if let attributes = try? fileManager.attributesOfItem(atPath: path),
               (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw LlamaProviderError.symlinkRejected(path)
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw LlamaProviderError.invalidModelPath("GGUF file does not exist at \(path).")
        }
        guard !isDirectory.boolValue else {
            throw LlamaProviderError.invalidModelPath("GGUF source must be a regular file, not a directory: \(path).")
        }

        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 24 else {
            throw LlamaProviderError.invalidGGUF("File at \(url.lastPathComponent) is too small to contain a valid GGUF header.")
        }
        return UInt64(size)
    }

    private static func readValidatedPrefix(
        from cursor: LlamaGGUFBinaryReader,
        fileName: String
    ) throws -> (version: UInt32, tensorCount: UInt64, kvCount: UInt64) {
        let readMagic = try cursor.readUInt32()
        guard readMagic == magic else {
            throw LlamaProviderError.invalidGGUF("Missing GGUF magic header in \(fileName).")
        }
        let version = try cursor.readUInt32()
        guard supportedVersions.contains(version) else {
            throw LlamaProviderError.invalidGGUF("Unsupported GGUF version \(version) in \(fileName).")
        }
        let tensorCount = try cursor.readUInt64()
        let kvCount = try cursor.readUInt64()
        guard tensorCount <= maximumTensorCount else {
            throw LlamaProviderError.invalidGGUF("GGUF tensor count \(tensorCount) exceeds safe inspection ceiling.")
        }
        guard kvCount <= maximumKVCount else {
            throw LlamaProviderError.invalidGGUF("GGUF metadata KV count \(kvCount) exceeds safe inspection ceiling.")
        }
        return (version, tensorCount, kvCount)
    }

    private static func inspectSingleHeader(
        at url: URL,
        totalSizeBytes: UInt64,
        shardCount: Int
    ) throws -> LlamaGGUFMetadata {
        let cursor = try LlamaGGUFBinaryReader(url: url)
        defer { cursor.close() }

        let (version, tensorCount, kvCount) = try readValidatedPrefix(
            from: cursor,
            fileName: url.lastPathComponent
        )

        var architecture: String?
        var modelName: String?
        var fileTypeCode: UInt32?
        var parameterCount: UInt64?
        var chatTemplate: String?
        var rawScalars: [String: UInt64] = [:]

        for _ in 0..<kvCount {
            let key = try cursor.readGGUFString(maxLength: maximumKeyLength)
            let valueTypeRaw = try cursor.readUInt32()
            guard let valueType = GGUFValueType(rawValue: valueTypeRaw) else {
                throw LlamaProviderError.invalidGGUF("Unknown GGUF metadata type \(valueTypeRaw) for key '\(key)'.")
            }

            switch valueType {
            case .string:
                if key == "general.architecture" || key == "general.name" || key == "tokenizer.chat_template" {
                    let value = try cursor.readGGUFString(maxLength: maximumRetainedStringLength)
                    switch key {
                    case "general.architecture": architecture = value
                    case "general.name": modelName = value
                    case "tokenizer.chat_template": chatTemplate = value
                    default: break
                    }
                } else {
                    try cursor.skipGGUFString(maxLength: maximumSkippableStringLength)
                }
            case .array:
                try skipGGUFArray(cursor: cursor)
            default:
                if let scalar = try readScalarAsUInt64(type: valueType, cursor: cursor),
                   isInterestingScalarKey(key) {
                    if key == "general.file_type", scalar <= UInt64(UInt32.max) {
                        fileTypeCode = UInt32(scalar)
                    } else if key == "general.parameter_count" {
                        parameterCount = scalar
                    } else {
                        rawScalars[key] = scalar
                    }
                }
            }
        }

        let archPrefix = architecture.map { "\($0)." }
        let contextLength = archInt("context_length", prefix: archPrefix, rawScalars: rawScalars)
        let embeddingLength = archInt("embedding_length", prefix: archPrefix, rawScalars: rawScalars)
        let blockCount = archInt("block_count", prefix: archPrefix, rawScalars: rawScalars)
        let headCount = archInt("attention.head_count", prefix: archPrefix, rawScalars: rawScalars)
        let headCountKV = archInt("attention.head_count_kv", prefix: archPrefix, rawScalars: rawScalars) ?? headCount
        let keyLength = archInt("attention.key_length", prefix: archPrefix, rawScalars: rawScalars)
        let valueLength = archInt("attention.value_length", prefix: archPrefix, rawScalars: rawScalars)

        let kvBytes = LlamaGGUFMetadataDerivation.deriveKVCacheBytesPerToken(
            blockCount: blockCount,
            attentionHeadCount: headCount,
            attentionHeadCountKV: headCountKV,
            embeddingLength: embeddingLength,
            keyLength: keyLength,
            valueLength: valueLength
        )
        return LlamaGGUFMetadata(
            formatVersion: version,
            tensorCount: tensorCount,
            metadataKVCount: kvCount,
            architecture: architecture,
            modelName: modelName,
            fileTypeCode: fileTypeCode,
            quantizationLabel: fileTypeCode.flatMap(LlamaGGUFMetadataDerivation.quantizationName(forFileType:)),
            parameterCount: parameterCount,
            contextLength: contextLength,
            embeddingLength: embeddingLength,
            blockCount: blockCount,
            attentionHeadCount: headCount,
            attentionHeadCountKV: headCountKV,
            keyLength: keyLength,
            valueLength: valueLength,
            chatTemplate: chatTemplate,
            fileSizeBytes: totalSizeBytes,
            shardCount: shardCount,
            kvCacheBytesPerToken: kvBytes
        )
    }

    private static func isInterestingScalarKey(_ key: String) -> Bool {
        key == "general.file_type" ||
            key == "general.parameter_count" ||
            key.hasSuffix(".context_length") ||
            key.hasSuffix(".embedding_length") ||
            key.hasSuffix(".block_count") ||
            key.hasSuffix(".attention.head_count") ||
            key.hasSuffix(".attention.head_count_kv") ||
            key.hasSuffix(".attention.key_length") ||
            key.hasSuffix(".attention.value_length")
    }

    private static func archInt(_ suffix: String, prefix: String?, rawScalars: [String: UInt64]) -> Int? {
        if let prefix, let val = rawScalars["\(prefix)\(suffix)"] {
            return val <= UInt64(Int.max) ? Int(val) : nil
        }
        if let match = rawScalars.first(where: { $0.key.hasSuffix(".\(suffix)") })?.value {
            return match <= UInt64(Int.max) ? Int(match) : nil
        }
        return nil
    }

    private static func skipGGUFArray(cursor: LlamaGGUFBinaryReader) throws {
        let elemRaw = try cursor.readUInt32()
        guard let elemType = GGUFValueType(rawValue: elemRaw), elemType != .array else {
            throw LlamaProviderError.invalidGGUF("Unsupported nested or unknown GGUF array type \(elemRaw).")
        }
        let count = try cursor.readUInt64()
        guard count <= maximumArrayCount else {
            throw LlamaProviderError.invalidGGUF("GGUF array count \(count) exceeds safe inspection ceiling.")
        }
        if let fixedSize = elemType.fixedByteSize {
            let (bytesToSkip, overflow) = count.multipliedReportingOverflow(by: UInt64(fixedSize))
            guard !overflow else {
                throw LlamaProviderError.invalidGGUF("GGUF array byte length overflowed.")
            }
            try cursor.skip(bytes: bytesToSkip)
            return
        }
        for _ in 0..<count {
            try cursor.skipGGUFString(maxLength: maximumSkippableStringLength)
        }
    }

    private static func readScalarAsUInt64(type: GGUFValueType, cursor: LlamaGGUFBinaryReader) throws -> UInt64? {
        switch type {
        case .uint8: return UInt64(try cursor.readUInt8())
        case .int8:
            let val = Int8(bitPattern: try cursor.readUInt8())
            return val >= 0 ? UInt64(val) : nil
        case .uint16: return UInt64(try cursor.readUInt16())
        case .int16:
            let val = Int16(bitPattern: try cursor.readUInt16())
            return val >= 0 ? UInt64(val) : nil
        case .uint32: return UInt64(try cursor.readUInt32())
        case .int32:
            let val = Int32(bitPattern: try cursor.readUInt32())
            return val >= 0 ? UInt64(val) : nil
        case .uint64: return try cursor.readUInt64()
        case .int64:
            let val = Int64(bitPattern: try cursor.readUInt64())
            return val >= 0 ? UInt64(val) : nil
        case .float32:
            _ = try cursor.readUInt32()
            return nil
        case .float64:
            _ = try cursor.readUInt64()
            return nil
        case .bool: return try cursor.readUInt8() != 0 ? 1 : 0
        case .string, .array: return nil
        }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
