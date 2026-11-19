import Foundation

/// An evidence source containing extracted passages.
public struct Source: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let passages: [SourcePassage]
    public let retrievedAt: Date
    /// Publication date when the page reports one.
    public let publishedAt: Date?
    /// Last-modified date when the page reports one.
    public let lastModified: Date?
    /// Authority weight `0...1` for the source host. See `SearchHostAuthority`.
    public let authority: Double
    /// Host the claim comes from, for citations and display.
    public let domain: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        passages: [SourcePassage] = [],
        retrievedAt: Date = Date(),
        publishedAt: Date? = nil,
        lastModified: Date? = nil,
        authority: Double? = nil,
        domain: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.passages = passages
        self.retrievedAt = retrievedAt
        self.publishedAt = publishedAt
        self.lastModified = lastModified
        self.authority = authority ?? SearchHostAuthority.score(url: url)
        self.domain = domain ?? url.host
    }

    /// Newest known date for this source, or `nil` when undated.
    public var effectiveDate: Date? { lastModified ?? publishedAt ?? retrievedAt }

    private enum CodingKeys: String, CodingKey {
        case id, url, title, passages, retrievedAt
        case publishedAt, lastModified, authority, domain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        passages = try container.decode([SourcePassage].self, forKey: .passages)
        retrievedAt = try container.decode(Date.self, forKey: .retrievedAt)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified)
        authority = try container.decodeIfPresent(Double.self, forKey: .authority)
            ?? SearchHostAuthority.score(url: url)
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? url.host
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(passages, forKey: .passages)
        try container.encode(retrievedAt, forKey: .retrievedAt)
        try container.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try container.encodeIfPresent(lastModified, forKey: .lastModified)
        try container.encode(authority, forKey: .authority)
        try container.encodeIfPresent(domain, forKey: .domain)
    }
}
