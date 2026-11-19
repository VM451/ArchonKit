import Testing
import Foundation
@testable import ArchonSearch

private struct FixedSimilarity: SemanticSimilarity, Sendable {
    let value: Double?
    func similarity(between query: String, and text: String) -> Double? { value }
}

@Suite("AI Context Quality Tests")
struct AIContextQualityTests {
    // MARK: - Passage chunking & relevance filtering

    @Test("Chunker scores the answering paragraph above boilerplate")
    func chunkerRanksAnswerAboveBoilerplate() {
        let chunker = PassageChunker(relevanceThreshold: 0.0)
        let body = """
        Subscribe to our newsletter for weekly deals and cookie preferences.

        ## Strict Concurrency
        Swift 6 introduces strict concurrency checking to prevent data races at compile time.

        Follow us on social media for more updates and promotions.
        """
        let scored = chunker.chunk(body, query: "Swift 6 strict concurrency data races")
        #expect(scored.count >= 2)
        let best = scored.max(by: { $0.score < $1.score })
        #expect(best?.text.contains("data races") == true)
        #expect(best?.heading == "Strict Concurrency")
        let worst = scored.min(by: { $0.score < $1.score })
        #expect((best?.score ?? 0) > (worst?.score ?? 1))
    }

    @Test("Chunker drops below-threshold filler and keeps the best as fail-safe")
    func chunkerFiltersAndFailsSafe() {
        let strict = PassageChunker(relevanceThreshold: 0.7)
        let body = """
        Swift 6 strict concurrency prevents data races at compile time.

        Unrelated weather report for the weekend across the region.
        """
        let kept = strict.chunk(body, query: "Swift 6 strict concurrency data races")
        #expect(kept.count == 1)
        #expect(kept[0].text.contains("data races") == true)

        let impossible = strict.chunk(
            "Cloudy skies over the valley with light rain expected.",
            query: "Swift 6 strict concurrency data races"
        )
        #expect(impossible.count == 1)
    }

    @Test("Chunker blends the semantic scorer at equal weight")
    func chunkerBlendsSemanticScore() {
        let chunker = PassageChunker(relevanceThreshold: 0.0)
        let keywordOnly = chunker.chunk("unrelated filler words here", query: "swift concurrency")
        let blended = chunker.chunk(
            "unrelated filler words here", query: "swift concurrency",
            similarity: FixedSimilarity(value: 0.9)
        )
        #expect((blended.first?.score ?? 0) > (keywordOnly.first?.score ?? 1))
    }

    // MARK: - Host authority

    @Test("Official docs outrank blogs, spam sinks to unverified")
    func hostAuthorityTiers() {
        #expect(SearchHostAuthority.tier(forHost: "developer.apple.com") == .official)
        #expect(SearchHostAuthority.tier(forHost: "swift.org") == .official)
        #expect(SearchHostAuthority.tier(forHost: "en.wikipedia.org") == .trusted)
        #expect(SearchHostAuthority.tier(forHost: "random-seo-blog.example") == .standard)
        #expect(SearchHostAuthority.tier(forHost: nil) == .unverified)
        #expect(
            SearchHostAuthority.score(host: "developer.apple.com")
                > SearchHostAuthority.score(host: "random-seo-blog.example")
        )
        let result = SearchResult(
            title: "t", url: URL(string: "https://developer.apple.com/x")!,
            snippet: "s"
        )
        #expect(result.hostAuthority == 1.0)
        #expect(result.domain == "developer.apple.com")
        #expect(result.effectiveURL.absoluteString == "https://developer.apple.com/x")
    }

    @Test("Result dates prefer lastModified over publishedAt")
    func resultEffectiveDate() {
        let pub = Date(timeIntervalSince1970: 1_000_000)
        let mod = Date(timeIntervalSince1970: 2_000_000)
        let result = SearchResult(
            title: "t", url: URL(string: "https://example.com/a")!,
            snippet: "s", publishedAt: pub, lastModified: mod
        )
        #expect(result.effectiveDate == mod)
    }

    // MARK: - Packing & budgets

    @Test("Packer respects the global budget and reports stats")
    func packerBudgetsAndStats() {
        let mkPassage = { (text: String, score: Double) in
            SourcePassage(sourceID: UUID(), text: text, score: score)
        }
        let sources = [
            Source(
                url: URL(string: "https://developer.apple.com/a")!,
                title: "A",
                passages: [mkPassage(String(repeating: "a", count: 3000), 0.9)]
            ),
            Source(
                url: URL(string: "https://example.com/b")!,
                title: "B",
                passages: [mkPassage(String(repeating: "b", count: 3000), 0.8)]
            ),
        ]
        let options = ContextQualityOptions(
            maxCharacters: 2000, maxCharsPerSource: 1500,
            relevanceThreshold: 0.0, maxPassagesPerSource: 3
        )
        let (packed, stats) = AIContextPacker(options: options).pack(sources: sources)
        let total = packed.flatMap(\.passages).reduce(0) { $0 + $1.text.count }
        #expect(total <= 2000)
        #expect(stats.sourcesUsed >= 1)
        #expect(stats.packedCharacters == total)
        #expect(stats.estimatedTokens > 0)
        #expect(stats.signalToTokenRatio > 0 && stats.signalToTokenRatio <= 1)
    }

    @Test("Packer drops below-threshold passages and counts them")
    func packerDropsLowRelevance() {
        let source = Source(
            url: URL(string: "https://example.com/a")!,
            title: "A",
            passages: [
                SourcePassage(sourceID: UUID(), text: "Swift 6 strict concurrency data races", score: 0.95),
                SourcePassage(sourceID: UUID(), text: "weekend weather outlook", score: 0.1),
            ]
        )
        let (packed, stats) = AIContextPacker().pack(sources: [source])
        #expect(packed.first?.passages.count == 1)
        #expect(stats.passagesDropped == 1)
        #expect(stats.passagesKept == 1)
    }

    @Test("Direct answer stitches top passages with citation tags")
    func directAnswerExtractive() {
        let id = UUID()
        let source = Source(
            id: id,
            url: URL(string: "https://developer.apple.com/a")!,
            title: "A",
            passages: [
                SourcePassage(sourceID: id, text: "Swift 6 enables strict concurrency. It catches data races.", score: 0.9),
                SourcePassage(sourceID: id, text: "Older notes about manual threads.", score: 0.2),
            ]
        )
        let answer = AIContextPacker().directAnswer(from: [source], maxSentences: 1)
        #expect(answer == "Swift 6 enables strict concurrency. [S1]")
        #expect(AIContextPacker().directAnswer(from: []) == nil)
    }

    // MARK: - Metadata propagation

    @Test("Resolved citations carry dates and authority")
    func citationsCarryGroundingSignals() {
        let pub = Date(timeIntervalSince1970: 1_500_000)
        let source = Source(
            url: URL(string: "https://developer.apple.com/doc")!,
            title: "Doc",
            passages: [SourcePassage(sourceID: UUID(), text: "Swift is fast.")],
            retrievedAt: Date(),
            publishedAt: pub
        )
        #expect(source.authority == 1.0)
        #expect(source.domain == "developer.apple.com")
        var graph = CitationGraph()
        graph.register(source: source, index: 1)
        let resolved = graph.resolve(citations: graph.parseCitations(from: "See [S1]."))
        #expect(resolved.count == 1)
        #expect(resolved[0].publishedAt == pub)
        #expect(resolved[0].authority == 1.0)
    }

    @Test("Packed sources survive a context round trip with citations intact")
    func packedContextRoundTrip() {
        let id = UUID()
        let source = Source(
            id: id,
            url: URL(string: "https://swift.org/a")!,
            title: "Swift",
            passages: [SourcePassage(sourceID: id, text: "Swift 6 strict concurrency prevents data races.", score: 0.95)]
        )
        let (packed, _) = AIContextPacker().pack(sources: [source])
        let context = ContextBuilder(maxTokens: 4000).buildContext(from: packed)
        #expect(context.contains("<reference_data>"))
        #expect(context.contains("data races"))
        let graph = CitationGraph(sources: packed)
        let parsed = graph.parseCitations(from: context)
        let (valid, hallucinations) = graph.verify(citations: parsed)
        #expect(!valid.isEmpty)
        #expect(hallucinations.isEmpty)
    }

    @Test("Old source snapshots without new keys still decode")
    func sourceDecodingIsMigrationSafe() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","url":"https://example.com/a","title":"A",\
        "passages":[],"retrievedAt":731000000.0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Source.self, from: legacy)
        #expect(decoded.authority == SearchHostAuthority.score(host: "example.com"))
        #expect(decoded.domain == "example.com")
    }
}
