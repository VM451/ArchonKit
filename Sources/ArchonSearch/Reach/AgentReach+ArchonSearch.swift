import Foundation

extension ArchonSearchClient {
    /// Executes an Agent Reach request across any of the 14 supported platforms.
    public func reach(_ request: ReachRequest, configuration: ReachConfiguration = ReachConfiguration()) async -> ReachResult {
        let client = AgentReachClient(configuration: configuration)
        return await client.execute(request)
    }

    /// Reads any platform or web URL using channel-aware Agent Reach extraction.
    public func reach(url: URL, preferredBackend: String? = nil, configuration: ReachConfiguration = ReachConfiguration()) async -> ReachResult {
        let client = AgentReachClient(configuration: configuration)
        return await client.read(url: url, preferredBackend: preferredBackend)
    }

    /// Searches a specific Agent Reach channel (GitHub, YouTube, Reddit, Twitter/X, Bilibili, V2EX, etc.).
    public func reachSearch(
        channel: ReachChannel,
        query: String,
        limit: Int = 5,
        preferredBackend: String? = nil,
        configuration: ReachConfiguration = ReachConfiguration()
    ) async -> ReachResult {
        let client = AgentReachClient(configuration: configuration)
        return await client.search(channel: channel, query: query, limit: limit, preferredBackend: preferredBackend)
    }

    /// Lists all 14 supported Agent Reach channels and their declared actions.
    public nonisolated func reachChannels() -> [ReachChannelDescriptor] {
        ReachChannel.allCases.map(ReachChannelDescriptor.init(channel:))
    }
}

extension ArchonSearch {
    /// Executes an Agent Reach request across any of the 14 supported platforms.
    public func reach(_ request: ReachRequest, configuration: ReachConfiguration = ReachConfiguration()) async -> ReachResult {
        let client = AgentReachClient(configuration: configuration)
        return await client.execute(request)
    }

    /// Reads any platform or web URL using channel-aware Agent Reach extraction.
    public func reach(url: URL, preferredBackend: String? = nil, configuration: ReachConfiguration = ReachConfiguration()) async -> ReachResult {
        let client = AgentReachClient(configuration: configuration)
        return await client.read(url: url, preferredBackend: preferredBackend)
    }

    /// Searches a specific Agent Reach channel.
    public func reachSearch(
        channel: ReachChannel,
        query: String,
        limit: Int = 5,
        preferredBackend: String? = nil,
        configuration: ReachConfiguration = ReachConfiguration()
    ) async -> ReachResult {
        let client = AgentReachClient(configuration: configuration)
        return await client.search(channel: channel, query: query, limit: limit, preferredBackend: preferredBackend)
    }
}
