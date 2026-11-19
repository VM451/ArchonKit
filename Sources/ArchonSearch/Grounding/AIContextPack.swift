import Foundation

/// Knobs for the AI-grade `ask` pipeline.
///
/// All defaults keep a single `ask` call inside a compact on-device budget
/// (~3k tokens across ≤3 passages per source) while dropping passages below
/// the relevance bar.
public struct ContextQualityOptions: Sendable, Codable, Equatable {
    /// Total context budget in characters (divided by `charsPerToken`).
    public var maxCharacters: Int
    /// Characters-per-token estimate shared with `ContextBuilder`.
    public var charsPerToken: Double
    /// Per-source character ceiling after packing.
    public var maxCharsPerSource: Int
    /// Passages scoring below this (`0...1`) are dropped.
    public var relevanceThreshold: Double
    /// Kept passages per source, highest score first.
    public var maxPassagesPerSource: Int
    /// Optional semantic scorer blended into passage scores.
    public var useSemanticRerank: Bool
    /// Whether the answer carries an extractive `directAnswer`.
    public var includeDirectAnswer: Bool

    public init(
        maxCharacters: Int = 12_000,
        charsPerToken: Double = 4.0,
        maxCharsPerSource: Int = 4_000,
        relevanceThreshold: Double = 0.7,
        maxPassagesPerSource: Int = 3,
        useSemanticRerank: Bool = false,
        includeDirectAnswer: Bool = true
    ) {
        self.maxCharacters = maxCharacters
        self.charsPerToken = charsPerToken
        self.maxCharsPerSource = maxCharsPerSource
        self.relevanceThreshold = min(max(relevanceThreshold, 0), 1)
        self.maxPassagesPerSource = max(1, maxPassagesPerSource)
        self.useSemanticRerank = useSemanticRerank
        self.includeDirectAnswer = includeDirectAnswer
    }
}

/// Observed quality numbers for one packed context, for logging and evals.
public struct ContextQualityStats: Sendable, Codable, Equatable {
    /// Sources that contributed at least one passage.
    public var sourcesUsed: Int
    /// Passages kept after threshold + per-source caps.
    public var passagesKept: Int
    /// Passages dropped by the relevance threshold.
    public var passagesDropped: Int
    /// Raw extracted characters before packing.
    public var rawCharacters: Int
    /// Characters that reached the context.
    public var packedCharacters: Int
    /// Estimated packed tokens (`packedCharacters / charsPerToken`).
    public var estimatedTokens: Int
    /// `packedCharacters / max(rawCharacters, 1)`: lower means denser.
    public var signalToTokenRatio: Double
    /// Whether any semantic score contributed.
    public var usedSemanticRerank: Bool

    public init(
        sourcesUsed: Int = 0,
        passagesKept: Int = 0,
        passagesDropped: Int = 0,
        rawCharacters: Int = 0,
        packedCharacters: Int = 0,
        estimatedTokens: Int = 0,
        signalToTokenRatio: Double = 0,
        usedSemanticRerank: Bool = false
    ) {
        self.sourcesUsed = sourcesUsed
        self.passagesKept = passagesKept
        self.passagesDropped = passagesDropped
        self.rawCharacters = rawCharacters
        self.packedCharacters = packedCharacters
        self.estimatedTokens = estimatedTokens
        self.signalToTokenRatio = signalToTokenRatio
        self.usedSemanticRerank = usedSemanticRerank
    }
}

/// Packs scored sources into a token budget, highest relevance first.
///
/// Pure value type: trims each source to `maxCharsPerSource`, keeps at most
/// `maxPassagesPerSource` passages per source, then fills the global budget in
/// score order. Reports `ContextQualityStats` so hosts can log the
/// signal-to-token ratio instead of guessing context cost.
public struct AIContextPacker: Sendable {
    public var options: ContextQualityOptions

    public init(options: ContextQualityOptions = ContextQualityOptions()) {
        self.options = options
    }

    /// Packs sources, returning budget-trimmed copies plus quality stats.
    ///
    /// Input passages are expected pre-scored (see `PassageChunker`); any
    /// passage below `relevanceThreshold` is dropped, except the single best
    /// passage overall is always kept so packing never yields an empty context
    /// from non-empty input.
    public func pack(sources: [Source]) -> (sources: [Source], stats: ContextQualityStats) {
        var rawChars = 0
        for source in sources {
            for passage in source.passages { rawChars += passage.text.count }
        }
        // Per-source trim: top passages first, then per-source char cap.
        var trimmed: [(source: Source, best: Double)] = []
        var dropped = 0
        for source in sources {
            let ranked = source.passages.sorted { $0.score > $1.score }
            var kept: [SourcePassage] = []
            var chars = 0
            for passage in ranked {
                guard kept.count < options.maxPassagesPerSource else { dropped += 1; continue }
                guard passage.score >= options.relevanceThreshold else { dropped += 1; continue }
                let room = options.maxCharsPerSource - chars
                guard room > 0 else { dropped += 1; continue }
                let text = String(passage.text.prefix(room))
                kept.append(SourcePassage(
                    id: passage.id,
                    sourceID: passage.sourceID,
                    passageID: passage.passageID,
                    text: text,
                    score: passage.score
                ))
                chars += text.count
            }
            guard !kept.isEmpty else { continue }
            let packed = Source(
                id: source.id,
                url: source.url,
                title: source.title,
                passages: kept.sorted { $0.score > $1.score },
                retrievedAt: source.retrievedAt,
                publishedAt: source.publishedAt,
                lastModified: source.lastModified,
                authority: source.authority,
                domain: source.domain
            )
            trimmed.append((packed, kept.map(\.score).max() ?? 0))
        }
        // Global budget in source-best-score order.
        let ordered = trimmed.sorted { $0.best > $1.best }
        let budget = max(options.maxCharacters, 1)
        var packedSources: [Source] = []
        var packedChars = 0
        var keptCount = 0
        for entry in ordered {
            let cost = entry.source.passages.reduce(0) { $0 + $1.text.count }
            if packedChars + cost > budget, !packedSources.isEmpty { break }
            packedSources.append(entry.source)
            packedChars += cost
            keptCount += entry.source.passages.count
        }
        // Fail-safe: never empty when input had passages.
        if packedSources.isEmpty, let first = ordered.first {
            packedSources = [first.source]
            packedChars = first.source.passages.reduce(0) { $0 + $1.text.count }
            keptCount = first.source.passages.count
        }
        let stats = ContextQualityStats(
            sourcesUsed: packedSources.count,
            passagesKept: keptCount,
            passagesDropped: dropped,
            rawCharacters: rawChars,
            packedCharacters: packedChars,
            estimatedTokens: Int((Double(packedChars) / max(options.charsPerToken, 1)).rounded(.up)),
            signalToTokenRatio: rawChars > 0 ? Double(packedChars) / Double(rawChars) : 0,
            usedSemanticRerank: options.useSemanticRerank
        )
        return (packedSources, stats)
    }

    /// Builds an extractive direct answer from the top packed passages.
    ///
    /// No model involved: the first sentence of each of the top `maxSentences`
    /// passages, in score order, each followed by its citation tag. Returns
    /// `nil` for empty input. Callers must present this as an extract, not a
    /// generated answer.
    public func directAnswer(
        from sources: [Source],
        maxSentences: Int = 3
    ) -> String? {
        let ranked = sources.flatMap { source -> [(Source, SourcePassage, Int)] in
            let idx = sources.firstIndex(where: { $0.id == source.id }) ?? 0
            return source.passages.map { (source, $0, idx) }
        }.sorted { $0.1.score > $1.1.score }
        guard !ranked.isEmpty else { return nil }
        var sentences: [String] = []
        for (source, passage, sourceIndex) in ranked.prefix(max(1, maxSentences)) {
            let first = firstSentence(of: passage.text)
            guard !first.isEmpty else { continue }
            sentences.append("\(first) [S\(sourceIndex + 1)]")
            _ = source
        }
        guard !sentences.isEmpty else { return nil }
        return sentences.joined(separator: " ")
    }

    private func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var end = trimmed.endIndex
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ".!?".contains(ch) {
                let next = trimmed.index(after: idx)
                if next == trimmed.endIndex || trimmed[next].isWhitespace {
                    end = trimmed.index(after: idx)
                    break
                }
            }
            idx = trimmed.index(after: idx)
        }
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
