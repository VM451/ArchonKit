import Foundation
import Testing
@testable import ArchonInference

#if canImport(llama)
import llama
#endif

@Suite("GGUF Binary Inspector & Peak Memory Tests")
struct LlamaGGUFInspectorTests {
    @Test("Parses synthetic GGUF v3 metadata, skips large arrays, and computes KV cache estimate")
    func parsesSyntheticGGUFv3() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-gguf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("tiny-llama.gguf")
        var data = makeGGUFHeader(version: 3, tensorCount: 4, kvCount: 9)
        appendKVString("general.architecture", "llama", to: &data)
        appendKVString("general.name", "Tiny-Llama-Test", to: &data)
        appendKVUInt32("general.file_type", 15, to: &data) // Q4_K_M
        appendKVUInt64("general.parameter_count", 1_000_000_000, to: &data)
        appendKVUInt32("llama.context_length", 8192, to: &data)
        appendKVUInt32("llama.embedding_length", 2048, to: &data)
        appendKVUInt32("llama.block_count", 16, to: &data)
        appendKVUInt32("llama.attention.head_count", 16, to: &data)
        appendKVUInt32("llama.attention.head_count_kv", 4, to: &data)
        // Pad to simulate weight payload size
        data.append(Data(repeating: 0, count: 4096))
        try data.write(to: fileURL)

        let metadata = try LlamaGGUFInspector.inspect(source: .localFile(fileURL))
        #expect(metadata.formatVersion == 3)
        #expect(metadata.tensorCount == 4)
        #expect(metadata.metadataKVCount == 9)
        #expect(metadata.architecture == "llama")
        #expect(metadata.modelName == "Tiny-Llama-Test")
        #expect(metadata.quantizationLabel == "Q4_K_M")
        #expect(metadata.parameterCount == 1_000_000_000)
        #expect(metadata.contextLength == 8192)
        #expect(metadata.embeddingLength == 2048)
        #expect(metadata.blockCount == 16)
        #expect(metadata.attentionHeadCount == 16)
        #expect(metadata.attentionHeadCountKV == 4)
        // 2 (K+V) * 16 blocks * 4 kvHeads * 128 headDim * 2 bytes (fp16) = 32_768 bytes/token
        #expect(metadata.kvCacheBytesPerToken == 32_768)

        let estimate = metadata.estimatedMemory(contextLength: 4096)
        #expect(!estimate.isHeuristic)
        #expect(estimate.kvCacheBytes == 32_768 * 4096)
        #expect(estimate.peakBytes > metadata.fileSizeBytes)
    }

    @Test("Aggregates size across split GGUF shards and validates all shard headers")
    func inspectsSplitGGUFShards() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-gguf-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let shard1 = dir.appendingPathComponent("model-00001-of-00002.gguf")
        let shard2 = dir.appendingPathComponent("model-00002-of-00002.gguf")

        var data1 = makeGGUFHeader(version: 3, tensorCount: 2, kvCount: 1)
        appendKVString("general.architecture", "qwen2", to: &data1)
        data1.append(Data(repeating: 1, count: 100))
        try data1.write(to: shard1)

        var data2 = makeGGUFHeader(version: 3, tensorCount: 2, kvCount: 0)
        data2.append(Data(repeating: 2, count: 200))
        try data2.write(to: shard2)

        let metadata = try LlamaGGUFInspector.inspect(source: .splitLocalFiles([shard1, shard2]))
        #expect(metadata.shardCount == 2)
        #expect(metadata.architecture == "qwen2")
        #expect(metadata.fileSizeBytes == UInt64(data1.count + data2.count))
    }

    @Test("Rejects symlinks, non-file URLs, bad magic, unsupported versions, and excessive KV counts")
    func failsClosedOnInvalidInputs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-gguf-err-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Non-file URL
        #expect(throws: LlamaProviderError.self) {
            _ = try LlamaGGUFInspector.inspect(source: .localFile(URL(string: "https://example.com/model.gguf")!))
        }

        // Bad magic
        let badMagic = dir.appendingPathComponent("bad.gguf")
        try Data("NOT_A_GGUF_FILE_WITH_ENOUGH_BYTES".utf8).write(to: badMagic)
        #expect(throws: LlamaProviderError.self) {
            _ = try LlamaGGUFInspector.inspect(source: .localFile(badMagic))
        }

        // Unsupported version (v1)
        let badVersion = dir.appendingPathComponent("v1.gguf")
        try makeGGUFHeader(version: 1, tensorCount: 0, kvCount: 0).write(to: badVersion)
        #expect(throws: LlamaProviderError.self) {
            _ = try LlamaGGUFInspector.inspect(source: .localFile(badVersion))
        }

        // Excessive KV count DoS guard
        let hugeKV = dir.appendingPathComponent("dos.gguf")
        try makeGGUFHeader(version: 3, tensorCount: 0, kvCount: 999_999).write(to: hugeKV)
        #expect(throws: LlamaProviderError.self) {
            _ = try LlamaGGUFInspector.inspect(source: .localFile(hugeKV))
        }

        // Symlink rejected by default, permitted when allowSymlinks is true
        let realFile = dir.appendingPathComponent("real.gguf")
        var validData = makeGGUFHeader(version: 3, tensorCount: 0, kvCount: 1)
        appendKVString("general.architecture", "gemma2", to: &validData)
        try validData.write(to: realFile)

        let linkFile = dir.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: realFile)
        #expect(throws: LlamaProviderError.symlinkRejected(linkFile.path)) {
            _ = try LlamaGGUFInspector.inspect(source: .localFile(linkFile), allowSymlinks: false)
        }
        let allowed = try LlamaGGUFInspector.inspect(source: .localFile(linkFile), allowSymlinks: true)
        #expect(allowed.architecture == "gemma2")
    }

    #if canImport(llama)
    @Test("Round-trips a real GGUF written by ggml's native C writer")
    func interopsWithNativeGGUFWriter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-gguf-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("native.gguf")
        guard let ctx = gguf_init_empty() else {
            Issue.record("gguf_init_empty returned nil")
            return
        }
        defer { gguf_free(ctx) }

        gguf_set_val_str(ctx, "general.architecture", "llama")
        gguf_set_val_str(ctx, "general.name", "Native-Interop-Model")
        gguf_set_val_u32(ctx, "general.file_type", 7) // Q8_0
        gguf_set_val_u32(ctx, "llama.context_length", 4096)
        gguf_set_val_str(ctx, "tokenizer.chat_template", "{{bos_token}}")
        let token1 = strdup("<s>")
        let token2 = strdup("hello")
        defer {
            free(token1)
            free(token2)
        }
        var tokenPtrs: [UnsafePointer<CChar>?] = [UnsafePointer(token1), UnsafePointer(token2)]
        gguf_set_arr_str(ctx, "tokenizer.ggml.tokens", &tokenPtrs, tokenPtrs.count)

        let wrote = fileURL.path.withCString { pathPtr in
            gguf_write_to_file(ctx, pathPtr, true)
        }
        #expect(wrote)

        let metadata = try LlamaGGUFInspector.inspect(source: .localFile(fileURL))
        #expect(metadata.formatVersion == 3)
        #expect(metadata.architecture == "llama")
        #expect(metadata.modelName == "Native-Interop-Model")
        #expect(metadata.quantizationLabel == "Q8_0")
        #expect(metadata.contextLength == 4096)
        #expect(metadata.chatTemplate == "{{bos_token}}")
    }
    #endif
}

// MARK: - Test Fixture Helpers

func makeGGUFHeader(version: UInt32, tensorCount: UInt64, kvCount: UInt64) -> Data {
    var data = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
    appendLittleEndian(version, to: &data)
    appendLittleEndian(tensorCount, to: &data)
    appendLittleEndian(kvCount, to: &data)
    return data
}

func appendKVString(_ key: String, _ value: String, to data: inout Data) {
    appendGGUFString(key, to: &data)
    appendLittleEndian(UInt32(8), to: &data) // GGUF_TYPE_STRING
    appendGGUFString(value, to: &data)
}

func appendKVUInt32(_ key: String, _ value: UInt32, to data: inout Data) {
    appendGGUFString(key, to: &data)
    appendLittleEndian(UInt32(4), to: &data) // GGUF_TYPE_UINT32
    appendLittleEndian(value, to: &data)
}

func appendKVUInt64(_ key: String, _ value: UInt64, to data: inout Data) {
    appendGGUFString(key, to: &data)
    appendLittleEndian(UInt32(10), to: &data) // GGUF_TYPE_UINT64
    appendLittleEndian(value, to: &data)
}

private func appendGGUFString(_ value: String, to data: inout Data) {
    let utf8 = Array(value.utf8)
    appendLittleEndian(UInt64(utf8.count), to: &data)
    data.append(contentsOf: utf8)
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}
