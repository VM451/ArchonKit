import Foundation

/// A query-scored chunk of a retrieved document, ready for context packing.
public struct ScoredPassage: Sendable, Hashable {
    /// Passage body, already sanitized for length upstream.
    public let text: String
    /// Nearest preceding Markdown heading (`#`/`##`/all-caps line), if any.
    public let heading: String?
    /// Normalized relevance in `0...1` against the query.
    public let score: Double

    public init(text: String, heading: String? = nil, score: Double = 0.0) {
        self.text = text
        self.heading = heading
        self.score = score
    }
}

/// Splits extracted documents into paragraph-aware passages and scores each
/// against the agent's query.
///
/// The pipeline previously injected a single `prefix(800)` slice per page with
/// a hard-coded `score: 1.0`, so boilerplate ranked equal to the answer. The
/// chunker instead keeps document structure (headings travel with their
/// passages), scores every paragraph on normalized query-term coverage blended
/// with an optional semantic scorer, and drops passages below a threshold so
/// compact local models never spend context on filler.
public struct PassageChunker: Sendable {
    /// Target ceiling per passage; longer paragraphs split on sentence bounds.
    public var maxCharsPerPassage: Int
    /// Passages shorter than this merge into the previous one.
    public var minCharsPerPassage: Int
    /// Passages scoring below this are dropped (`0...1`).
    public var relevanceThreshold: Double

    public init(
        maxCharsPerPassage: Int = 1200,
        minCharsPerPassage: Int = 120,
        relevanceThreshold: Double = 0.7
    ) {
        self.maxCharsPerPassage = max(200, maxCharsPerPassage)
        self.minCharsPerPassage = max(0, minCharsPerPassage)
        self.relevanceThreshold = min(max(relevanceThreshold, 0), 1)
    }

    /// Chunks `text`, scores each passage, and drops below-threshold ones.
    ///
    /// When filtering removes everything but input was non-empty, the single
    /// best passage is kept so the pipeline degrades to one chunk instead of
    /// an empty context.
    public func chunk(
        _ text: String,
        query: String,
        similarity: (any SemanticSimilarity)? = nil
    ) -> [ScoredPassage] {
        let raw = splitParagraphs(text)
        guard !raw.isEmpty else { return [] }
        let scored = raw.map { passage in
            ScoredPassage(
                text: passage.text,
                heading: passage.heading,
                score: score(passage.text, query: query, similarity: similarity)
            )
        }
        let kept = scored.filter { $0.score >= relevanceThreshold }
        if kept.isEmpty, let best = scored.max(by: { $0.score < $1.score }) {
            return [best]
        }
        return kept
    }

    /// Normalized relevance `0...1` for one passage.
    ///
    /// Blends query-term coverage (fraction of distinctive query terms present,
    /// stopwords removed) with the optional semantic scorer at equal weight.
    /// Without a scorer the coverage term counts twice, keeping the result
    /// deterministic and on-device.
    public func score(
        _ passage: String,
        query: String,
        similarity: (any SemanticSimilarity)? = nil
    ) -> Double {
        let coverage = termCoverage(passage: passage, query: query)
        if let similarity, let semantic = similarity.similarity(between: query, and: passage) {
            return min(max(0.5 * coverage + 0.5 * semantic, 0), 1)
        }
        return coverage
    }

    // MARK: - Paragraph splitting

    private struct RawPassage {
        let text: String
        let heading: String?
    }

    private func splitParagraphs(_ text: String) -> [RawPassage] {
        var out: [RawPassage] = []
        var currentHeading: String? = nil
        var current: String = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                for piece in splitLongPassage(trimmed) {
                    out.append(RawPassage(text: piece, heading: currentHeading))
                }
            }
            current = ""
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if isHeading(trimmed) {
                flush()
                currentHeading = headingText(trimmed)
                continue
            }
            if !current.isEmpty { current += " " }
            current += trimmed
        }
        flush()
        // Merge a tiny tail into its predecessor so models never get a stub.
        if out.count >= 2, let last = out.last, last.text.count < minCharsPerPassage {
            let merged = (out[out.count - 2].text + " " + last.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out[out.count - 2] = RawPassage(text: merged, heading: out[out.count - 2].heading)
            out.removeLast()
        }
        return out.filter { !$0.text.isEmpty }
    }

    private func isHeading(_ line: String) -> Bool {
        if line.hasPrefix("### ") || line.hasPrefix("## ") || line.hasPrefix("# ") { return true }
        if line.count >= 8 && line.count <= 90 && line == line.uppercased()
            && line.rangeOfCharacter(from: .letters) != nil { return true }
        return false
    }

    private func headingText(_ line: String) -> String {
        var text = line
        while text.hasPrefix("#") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return text
    }

    private func splitLongPassage(_ text: String) -> [String] {
        guard text.count > maxCharsPerPassage else { return [text] }
        var pieces: [String] = []
        var rest = text
        while rest.count > maxCharsPerPassage {
            let idx = rest.index(rest.startIndex, offsetBy: maxCharsPerPassage)
            let window = rest[..<idx]
            if let sentenceEnd = window.lastIndex(where: { ".!?".contains($0) }) {
                let cut = rest.index(after: sentenceEnd)
                pieces.append(String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
                rest = String(rest[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let space = window.lastIndex(of: " ") {
                pieces.append(String(rest[..<space]))
                rest = String(rest[rest.index(after: space)...])
            } else {
                pieces.append(String(window))
                rest = String(rest[idx...])
            }
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    // MARK: - Coverage scoring

    private func termCoverage(passage: String, query: String) -> Double {
        let terms = distinctiveTerms(query)
        guard !terms.isEmpty else { return 0.5 }
        let folded = passage.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var hits = 0
        for term in terms where folded.contains(term) { hits += 1 }
        return Double(hits) / Double(terms.count)
    }

    private func distinctiveTerms(_ query: String) -> [String] {
        let folded = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let raw = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        var seen = Set<String>()
        return raw.filter { term in
            guard !Self.stopwords.contains(term), seen.insert(term).inserted else { return false }
            return true
        }
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with",
        "is", "are", "was", "were", "be", "by", "as", "at", "from", "that",
        "this", "what", "whats", "how", "why", "when", "where", "which", "who",
        "do", "does", "did", "can", "could", "should", "would", "it", "its",
        "vs", "new", "best", "top", "get", "using", "use", "app", "ios",
    ]
}
