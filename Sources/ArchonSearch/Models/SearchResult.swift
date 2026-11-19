import Foundation

/// A structured search result from search engine or local corpus discovery.
public struct SearchResult: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let title: String
    public let url: URL
    public let snippet: String
    public let publishedAt: Date?
    /// Last-modified date when the engine reports one; falls back to
    /// `publishedAt` via `effectiveDate`. Lets agents prefer fresh docs.
    public let lastModified: Date?
    /// Canonical URL when the engine reports one; otherwise `url`.
    public let canonicalURL: URL?
    public let score: Double?
    public let engine: String?
    public let highlights: [String]

    /// Newest known date for this result, or `nil` when undated.
    public var effectiveDate: Date? { lastModified ?? publishedAt }
    /// Host the claim comes from (`url.host`).
    public var domain: String? { url.host }
    /// Deterministic authority weight `0...1` for the result host.
    /// See `SearchHostAuthority`.
    public var hostAuthority: Double { SearchHostAuthority.score(url: effectiveURL) }
    /// URL to cite: canonical when known, otherwise the fetched URL.
    public var effectiveURL: URL { canonicalURL ?? url }

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        snippet: String,
        publishedAt: Date? = nil,
        lastModified: Date? = nil,
        canonicalURL: URL? = nil,
        score: Double? = nil,
        engine: String? = nil,
        highlights: [String] = []
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.lastModified = lastModified
        self.canonicalURL = canonicalURL
        self.score = score
        self.engine = engine
        self.highlights = highlights
    }

    /// Convenience initializer maintaining backwards compatibility with earlier API.
    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        snippet: String,
        highlights: [String] = [],
        publishedAt: Date? = nil,
        lastModified: Date? = nil,
        canonicalURL: URL? = nil,
        score: Double? = nil,
        engine: String? = nil
    ) {
        self.init(
            id: id,
            title: title,
            url: url,
            snippet: snippet,
            publishedAt: publishedAt,
            lastModified: lastModified,
            canonicalURL: canonicalURL,
            score: score,
            engine: engine,
            highlights: highlights
        )
    }
}
