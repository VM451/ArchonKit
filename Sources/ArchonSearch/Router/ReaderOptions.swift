import Foundation

/// Options configuring page reading and routing behavior.
public struct ReaderOptions: Sendable, Codable, Hashable {
    public var mode: ArchonSearchConfiguration.RoutingMode
    public var timeout: TimeInterval?
    public var minBodyCharacters: Int
    /// When true, URLs belonging to specialized Agent Reach channels (GitHub, YouTube, Reddit, V2EX, Bilibili, etc.)
    /// try channel-aware extraction before falling back to generic HTML/crawler extraction.
    public var useChannelReach: Bool

    public init(
        mode: ArchonSearchConfiguration.RoutingMode = .automatic,
        timeout: TimeInterval? = nil,
        minBodyCharacters: Int = 400,
        useChannelReach: Bool = true
    ) {
        self.mode = mode
        self.timeout = timeout
        self.minBodyCharacters = minBodyCharacters
        self.useChannelReach = useChannelReach
    }
}
