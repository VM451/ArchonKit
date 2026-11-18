import Foundation

/// Incremental stop-sequence detector that withholds only the minimal ambiguous
/// trailing window so non-matching prefixes stream immediately without leaking a stop sequence.
struct LlamaStopSequenceFilter: Sendable {
    private let stopSequences: [String]
    private let maxHoldback: Int
    private var pending = ""
    private(set) var didMatchStopSequence = false

    init(stopSequences: [String]) {
        let nonEmpty = stopSequences.filter { !$0.isEmpty }
        self.stopSequences = nonEmpty
        self.maxHoldback = max(0, (nonEmpty.map(\.count).max() ?? 0) - 1)
    }

    mutating func push(_ chunk: String) -> String {
        guard !didMatchStopSequence else { return "" }
        guard !stopSequences.isEmpty else { return chunk }
        pending += chunk

        var earliestMatch: Range<String.Index>?
        for stop in stopSequences {
            if let range = pending.range(of: stop) {
                if earliestMatch == nil || range.lowerBound < earliestMatch!.lowerBound {
                    earliestMatch = range
                }
            }
        }
        if let match = earliestMatch {
            didMatchStopSequence = true
            let prefix = String(pending[..<match.lowerBound])
            pending = ""
            return prefix
        }

        if pending.count > maxHoldback {
            let emitEnd = pending.index(pending.endIndex, offsetBy: -maxHoldback)
            let safePrefix = String(pending[..<emitEnd])
            pending = String(pending[emitEnd...])
            return safePrefix
        }
        return ""
    }

    mutating func flush() -> String {
        guard !didMatchStopSequence else {
            pending = ""
            return ""
        }
        let remaining = pending
        pending = ""
        return remaining
    }
}

/// UTF-8 multi-byte boundary splitter for raw token pieces returned by `llama_token_to_piece`.
struct LlamaUTF8PieceDecoder: Sendable {
    private var buffer = Data()

    mutating func append(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        buffer.append(contentsOf: bytes)
        let splitIndex = validUTF8PrefixEnd(in: buffer)
        guard splitIndex > 0 else { return "" }
        let prefix = buffer.prefix(splitIndex)
        buffer.removeFirst(splitIndex)
        return String(decoding: prefix, as: UTF8.self)
    }

    mutating func flush() -> String {
        guard !buffer.isEmpty else { return "" }
        let flushed = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: false)
        return flushed
    }

    private func validUTF8PrefixEnd(in data: Data) -> Int {
        let count = data.count
        guard count > 0 else { return 0 }
        // Inspect at most the last 3 trailing bytes for an incomplete UTF-8 sequence.
        let tailCheckStart = max(0, count - 3)
        for index in stride(from: count - 1, through: tailCheckStart, by: -1) {
            let byte = data[data.startIndex + index]
            if byte < 0x80 {
                return count
            }
            if byte >= 0xC0 {
                let expectedLength: Int
                if (byte & 0xE0) == 0xC0 {
                    expectedLength = 2
                } else if (byte & 0xF0) == 0xE0 {
                    expectedLength = 3
                } else if (byte & 0xF8) == 0xF0 {
                    expectedLength = 4
                } else {
                    return count
                }
                let available = count - index
                return available < expectedLength ? index : count
            }
        }
        return count
    }
}
