import Foundation

/// An attribution citation mapping claims back to a specific source and passage.
public struct Citation: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let label: String
    public let sourceID: UUID
    public let passageID: UUID?
    public let url: URL
    public let title: String?
    public let snippet: String?
    /// Newest known date of the cited source, when reported.
    public let publishedAt: Date?
    /// Authority weight `0...1` of the cited host. See `SearchHostAuthority`.
    public let authority: Double?

    public init(
        id: UUID = UUID(),
        label: String,
        sourceID: UUID = UUID(),
        passageID: UUID? = nil,
        url: URL,
        title: String? = nil,
        snippet: String? = nil,
        publishedAt: Date? = nil,
        authority: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.sourceID = sourceID
        self.passageID = passageID
        self.url = url
        self.title = title
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.authority = authority
    }

    /// Convenience initializer maintaining backwards compatibility with earlier API.
    public init(index: Int, sourceURLString: String, snippet: String? = nil) {
        self.id = UUID()
        self.label = "[\(index)]"
        self.sourceID = UUID()
        self.passageID = nil
        self.url = URL(string: sourceURLString) ?? URL(fileURLWithPath: "/")
        self.title = nil
        self.snippet = snippet
        self.publishedAt = nil
        self.authority = nil
    }
    
    /// Numeric index derived from citation label if formatted as [1], [2], etc.
    public var index: Int {
        let trimmed = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return Int(trimmed) ?? 0
    }
    
    /// String representation of the source URL.
    public var sourceURLString: String {
        url.absoluteString
    }
}
