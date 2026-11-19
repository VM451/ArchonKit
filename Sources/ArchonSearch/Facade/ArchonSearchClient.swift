import Foundation
import NaturalLanguage
import ArchonCore

/// High-level public facade for ArchonSearch 2.0.
/// Coordinates web meta-search, content extraction, grounding, and autonomous research.
public actor ArchonSearchClient: Sendable {
    public let configuration: ArchonSearchConfiguration
    private let searchEngine: any SearchEngine
    private let router: RetrievalRouter
    private let coordinator: ResearchCoordinator
    private let database: SearchDatabase?

    public init(
        configuration: ArchonSearchConfiguration = .onDevice(),
        database: SearchDatabase? = nil
    ) {
        self.configuration = configuration
        let searchURL = configuration.searchEngine.searxngURL
        let crawlerURL = configuration.crawler.crawl4aiURL

        if let searchURL {
            let primary = SearXNGClient(endpoint: searchURL)
            let fallback = DuckDuckGoSearchEngine()
            self.searchEngine = CompositeSearchEngine(primary: primary, fallback: fallback)
        } else {
            self.searchEngine = DuckDuckGoSearchEngine()
        }

        let cClient = crawlerURL.map { Crawl4AIClient(endpoint: $0) }
        let nReader = NativeReader(timeout: configuration.timeouts.fetchTimeout)
        let rRouter = RetrievalRouter(crawlClient: cClient, nativeReader: nReader)

        self.router = rRouter
        self.coordinator = ResearchCoordinator(searchEngine: self.searchEngine, retrievalRouter: rRouter)
        self.database = database
    }

    /// Searches the web via the configured on-device or companion search engine.
    public func search(_ query: String, categories: [String]? = nil, page: Int = 1) async throws -> [SearchResult] {
        try await searchEngine.search(query, categories: categories, page: page)
    }

    /// Ranked search: local rerank with freshness and host scoping.
    ///
    /// When `embedding` (or `options.embedding`) is enabled, the Apple-API
    /// embedding path blends a bounded semantic boost; otherwise behavior is
    /// keyword-identical to previous releases.
    public func rankedSearch(
        _ query: String,
        categories: [String]? = nil,
        page: Int = 1,
        options: SearchRankingOptions = SearchRankingOptions(),
        similarity: (any SemanticSimilarity)? = nil,
        semanticWeight: Double = 0.4,
        embedding: EmbeddingRerankOptions? = nil
    ) async throws -> [SearchResult] {
        let (results, _) = try await rankedSearchWithDiagnostics(
            query, categories: categories, page: page,
            options: options, similarity: similarity,
            semanticWeight: semanticWeight, embedding: embedding
        )
        return results
    }

    /// Ranked search with diagnostics, reporting `usedSemanticRerank`.
    public func rankedSearchWithDiagnostics(
        _ query: String,
        categories: [String]? = nil,
        page: Int = 1,
        options: SearchRankingOptions = SearchRankingOptions(),
        similarity: (any SemanticSimilarity)? = nil,
        semanticWeight: Double = 0.4,
        embedding: EmbeddingRerankOptions? = nil
    ) async throws -> (results: [SearchResult], diagnostics: SearchDiagnostics) {
        let start = Date()
        let results = try await searchEngine.search(query, categories: categories, page: page)
        let ranker = ResultReranker()
        let ranked: [SearchResult]
        let usedSemantic: Bool
        if embedding ?? options.embedding != nil {
            let out = ranker.rankWithEmbedding(
                results, for: query, options: options,
                embedding: embedding, similarity: similarity
            )
            ranked = out.results
            usedSemantic = out.usedSemanticRerank
        } else if let similarity {
            let out = ranker.rankWithSimilarity(
                results, for: query, options: options,
                similarity: similarity, semanticWeight: semanticWeight
            )
            ranked = out.results
            usedSemantic = out.usedSemanticRerank
        } else {
            ranked = ranker.rank(results, for: query, options: options)
            usedSemantic = false
        }
        var diagnostics = SearchDiagnostics(searchDuration: Date().timeIntervalSince(start))
        diagnostics.usedSemanticRerank = usedSemantic
        return (ranked, diagnostics)
    }

    /// Reads and extracts structured text and markdown from a webpage URL.
    public func read(url: URL, options: ReaderOptions = ReaderOptions()) async throws -> WebDocument {
        try await router.read(url: url, options: options)
    }

    /// Performs autonomous multi-round research on a given topic.
    public func research(topic: String, options: ResearchOptions = ResearchOptions()) async throws -> ResearchReport {
        try await coordinator.research(topic: topic, options: options)
    }

    /// Performs grounded web search and assembles prompt-injection-safe context with verified citations.
    ///
    /// AI-grade pipeline: pages are fetched in parallel, stripped to clean
    /// Markdown upstream, split into query-scored passages (below-threshold
    /// filler is dropped), packed into a token budget, and returned with
    /// authority/date metadata plus an extractive direct answer.
    public func ask(query: String) async throws -> (context: String, sources: [Source], citations: [Citation]) {
        let answer = try await ask(query: query, options: ContextQualityOptions())
        return (context: answer.context, sources: answer.sources, citations: answer.citations)
    }

    /// Performs grounded web search returning an answer with text, context, sources, and verified citations.
    @discardableResult
    public func ask(_ query: String) async throws -> SearchAnswer {
        try await ask(query: query, options: ContextQualityOptions())
    }

    /// Grounded web search with explicit context-quality controls.
    ///
    /// - `options.relevanceThreshold` drops passages below the bar (default
    ///   `0.7`); the single best passage survives as a fail-safe.
    /// - `options.maxCharacters` caps the packed context for compact models.
    /// - `options.useSemanticRerank` blends on-device embedding similarity
    ///   into passage scores; off by default for determinism.
    public func ask(query: String, options: ContextQualityOptions) async throws -> SearchAnswer {
        let results = try await search(query, page: 1)
        let candidates = Array(results.prefix(configuration.limits.maxResults))
        let fetched = await fetchDocuments(for: candidates, query: query)

        let chunker = PassageChunker(relevanceThreshold: options.relevanceThreshold)
        let similarity: (any SemanticSimilarity)? =
            options.useSemanticRerank ? NaturalLanguageSimilarity() : nil
        var sources: [Source] = []
        var rawCharacters = 0
        for (result, doc) in fetched {
            let body = doc.markdown.isEmpty ? doc.text : doc.markdown
            rawCharacters += body.count
            let scored = chunker.chunk(body, query: query, similarity: similarity)
            guard !scored.isEmpty else { continue }
            let passages = scored.prefix(options.maxPassagesPerSource).map { item in
                SourcePassage(
                    sourceID: doc.id,
                    passageID: UUID(),
                    text: item.heading.map { "## \($0)\n\(item.text)" } ?? item.text,
                    score: item.score
                )
            }
            sources.append(Source(
                id: doc.id,
                url: result.effectiveURL,
                title: doc.title.isEmpty ? result.title : doc.title,
                passages: Array(passages),
                publishedAt: doc.publishedAt ?? result.publishedAt,
                lastModified: result.lastModified
            ))
        }

        let packer = AIContextPacker(options: options)
        let (packed, stats) = packer.pack(sources: sources)
        var statsWithRaw = stats
        statsWithRaw.rawCharacters = rawCharacters
        statsWithRaw.signalToTokenRatio = rawCharacters > 0
            ? Double(stats.packedCharacters) / Double(rawCharacters) : 0

        let builder = ContextBuilder(
            maxTokens: max(1, options.maxCharacters / max(1, Int(options.charsPerToken))),
            charsPerToken: options.charsPerToken
        )
        let context = builder.buildContext(from: packed)
        let graph = CitationGraph(sources: packed)
        let parsed = graph.parseCitations(from: context)
        let verified = graph.verify(citations: parsed).valid
        let citations = graph.resolve(citations: verified)
        let directAnswer = options.includeDirectAnswer
            ? packer.directAnswer(from: packed) : nil

        return SearchAnswer(
            text: directAnswer ?? context,
            context: context,
            sources: packed,
            citations: citations,
            directAnswer: directAnswer,
            qualityStats: statsWithRaw
        )
    }

    /// Fetches candidate pages concurrently, preserving search-result order.
    private func fetchDocuments(
        for results: [SearchResult],
        query _: String
    ) async -> [(SearchResult, WebDocument)] {
        let indexed = await withTaskGroup(
            of: (Int, SearchResult, WebDocument)?.self,
            returning: [(Int, SearchResult, WebDocument)].self
        ) { group in
            for (index, result) in results.enumerated() {
                group.addTask {
                    do {
                        let doc = try await self.read(url: result.url)
                        return (index, result, doc)
                    } catch {
                        return nil
                    }
                }
            }
            var collected: [(Int, SearchResult, WebDocument)] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected
        }
        return indexed
            .sorted { $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }

    /// Returns health check status across the search engine and Crawl4AI instances.
    public func checkHealth() async -> (searxngHealthy: Bool, crawlerHealthy: Bool) {
        let engineOk = await searchEngine.checkHealth()
        let routerHealth = await router.healthReport()
        return (searxngHealthy: engineOk, crawlerHealthy: routerHealth.isCrawlerAvailable)
    }
}

/// An answer containing grounded text and verified citations.
public struct SearchAnswer: Sendable {
    public let text: String
    public let context: String
    public let sources: [Source]
    public let citations: [Citation]
    /// Extractive one-glance synthesis (top passages + citation tags, no
    /// model involved), or `nil` when nothing was retrieved or the caller
    /// opted out via `ContextQualityOptions.includeDirectAnswer`.
    public let directAnswer: String?
    /// Observed packing numbers (token estimate, signal-to-token ratio).
    public let qualityStats: ContextQualityStats?

    public init(
        text: String,
        context: String,
        sources: [Source],
        citations: [Citation],
        directAnswer: String? = nil,
        qualityStats: ContextQualityStats? = nil
    ) {
        self.text = text
        self.context = context
        self.sources = sources
        self.citations = citations
        self.directAnswer = directAnswer
        self.qualityStats = qualityStats
    }
}
