import Foundation

enum GGUFValueType: UInt32 {
    case uint8 = 0
    case int8 = 1
    case uint16 = 2
    case int16 = 3
    case uint32 = 4
    case int32 = 5
    case float32 = 6
    case bool = 7
    case string = 8
    case array = 9
    case uint64 = 10
    case int64 = 11
    case float64 = 12

    var fixedByteSize: Int? {
        switch self {
        case .uint8, .int8, .bool: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64: return 8
        case .string, .array: return nil
        }
    }
}

/// Forward-only buffered little-endian reader over a local `FileHandle`.
final class LlamaGGUFBinaryReader {
    private let handle: FileHandle
    private let fileSize: UInt64
    private var fileOffset: UInt64 = 0
    private var buffer = Data()
    private var bufferOffset = 0
    private let chunkSize = 65_536

    init(url: URL) throws {
        do {
            self.handle = try FileHandle(forReadingFrom: url)
            self.fileSize = try self.handle.seekToEnd()
            try self.handle.seek(toOffset: 0)
        } catch {
            throw LlamaProviderError.invalidGGUF("Unable to read GGUF file \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func close() {
        try? handle.close()
    }

    func readUInt8() throws -> UInt8 {
        try ensureAvailable(1)
        let byte = buffer[buffer.startIndex + bufferOffset]
        bufferOffset += 1
        return byte
    }

    func readUInt16() throws -> UInt16 {
        try readInteger(UInt16.self)
    }

    func readUInt32() throws -> UInt32 {
        try readInteger(UInt32.self)
    }

    func readUInt64() throws -> UInt64 {
        try readInteger(UInt64.self)
    }

    func readGGUFString(maxLength: UInt64) throws -> String {
        let len = try readUInt64()
        guard len <= maxLength else {
            throw LlamaProviderError.invalidGGUF("GGUF string length \(len) exceeds safety limit \(maxLength).")
        }
        let byteCount = Int(len)
        guard byteCount > 0 else { return "" }
        let bytes = try readBytes(count: byteCount)
        return String(decoding: bytes, as: UTF8.self)
    }

    func skipGGUFString(maxLength: UInt64) throws {
        let len = try readUInt64()
        guard len <= maxLength else {
            throw LlamaProviderError.invalidGGUF("GGUF string length \(len) exceeds safety limit \(maxLength).")
        }
        try skip(bytes: len)
    }

    func skip(bytes: UInt64) throws {
        guard bytes > 0 else { return }
        let bufferedRemaining = UInt64(buffer.count - bufferOffset)
        if bytes <= bufferedRemaining {
            bufferOffset += Int(bytes)
            return
        }
        let fileSeekIncrement = bytes - bufferedRemaining
        let (targetOffset, overflow) = fileOffset.addingReportingOverflow(fileSeekIncrement)
        guard !overflow, targetOffset <= fileSize else {
            throw LlamaProviderError.invalidGGUF("Unexpected end of GGUF file while skipping \(bytes) bytes.")
        }
        buffer.removeAll(keepingCapacity: true)
        bufferOffset = 0
        fileOffset = targetOffset
        do {
            try handle.seek(toOffset: targetOffset)
        } catch {
            throw LlamaProviderError.invalidGGUF("Failed to seek GGUF file: \(error.localizedDescription)")
        }
    }

    private func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try ensureAvailable(size)
        var value: T = 0
        let start = buffer.startIndex + bufferOffset
        withUnsafeMutableBytes(of: &value) { dest in
            _ = buffer[start ..< (start + size)].copyBytes(to: dest)
        }
        bufferOffset += size
        return T(littleEndian: value)
    }

    private func readBytes(count: Int) throws -> Data {
        if count <= buffer.count - bufferOffset {
            let start = buffer.startIndex + bufferOffset
            let slice = buffer[start ..< (start + count)]
            bufferOffset += count
            return Data(slice)
        }
        var result = Data()
        result.reserveCapacity(count)
        let existing = buffer.count - bufferOffset
        if existing > 0 {
            let start = buffer.startIndex + bufferOffset
            result.append(buffer[start ..< buffer.endIndex])
            bufferOffset = buffer.count
        }
        var remaining = count - result.count
        while remaining > 0 {
            let toRead = min(max(chunkSize, remaining), remaining)
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                throw LlamaProviderError.invalidGGUF("Unexpected end of GGUF file while reading string.")
            }
            fileOffset += UInt64(chunk.count)
            result.append(chunk)
            remaining -= chunk.count
        }
        return result
    }

    private func ensureAvailable(_ needed: Int) throws {
        let available = buffer.count - bufferOffset
        if available >= needed { return }

        var next = Data()
        if available > 0 {
            next.append(buffer[(buffer.startIndex + bufferOffset) ..< buffer.endIndex])
        }
        while next.count < needed {
            let toRead = max(chunkSize, needed - next.count)
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                throw LlamaProviderError.invalidGGUF("Unexpected end of GGUF file.")
            }
            fileOffset += UInt64(chunk.count)
            next.append(chunk)
        }
        buffer = next
        bufferOffset = 0
    }
}
