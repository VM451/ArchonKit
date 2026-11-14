import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Metadata describing an Agent Reach channel and its declared actions.
public struct ReachChannelDescriptor: Codable, Hashable, Sendable {
    public let channel: ReachChannel
    public let displayName: String
    public let level: ReachChannelLevel
    public let actions: [ReachAction]
    public let domains: [String]
    public let mayRequireLogin: Bool

    public init(channel: ReachChannel) {
        self.channel = channel
        self.displayName = channel.displayName
        self.level = channel.level
        self.actions = channel.supportedActions
        self.domains = channel.domains
        self.mayRequireLogin = channel.mayRequireLogin
    }
}

/// Unified Agent Reach coordinator with ordered per-channel backends and graceful fallbacks.
public actor AgentReachClient: Sendable {
    public let configuration: ReachConfiguration
    private let session: URLSession?
    private let customBackends: [String: any ReachBackend]

    public init(
        configuration: ReachConfiguration = ReachConfiguration(),
        session: URLSession? = nil,
        customBackends: [any ReachBackend] = []
    ) {
        self.configuration = configuration
        self.session = session
        var map: [String: any ReachBackend] = [:]
        for backend in customBackends {
            map[backend.name] = backend
        }
        self.customBackends = map
    }

    /// Returns descriptors for all 14 supported Agent Reach channels.
    public nonisolated func channels() -> [ReachChannelDescriptor] {
        ReachChannel.allCases.map(ReachChannelDescriptor.init(channel:))
    }

    /// Reads any supported URL by automatically selecting the owning `ReachChannel`.
    public func read(url: URL, preferredBackend: String? = nil) async -> ReachResult {
        let channel = ReachChannel.channel(for: url)
        let request = ReachRequest(
            channel: channel,
            action: .read,
            target: url.absoluteString,
            limit: 1,
            preferredBackend: preferredBackend
        )
        return await execute(request)
    }

    /// Searches a specific Agent Reach channel.
    public func search(
        channel: ReachChannel,
        query: String,
        limit: Int = 5,
        preferredBackend: String? = nil
    ) async -> ReachResult {
        let request = ReachRequest(
            channel: channel,
            action: .search,
            target: query,
            limit: limit,
            preferredBackend: preferredBackend
        )
        return await execute(request)
    }

    /// Searches across multiple `SocialPlatform`s concurrently using Agent Reach channel backends.
    public func search(
        platforms: [SocialPlatform],
        query: String,
        limit: Int = 5
    ) async -> [ReachResult] {
        let channels = platforms.isEmpty
            ? SocialPlatform.allCases.map(ReachChannel.init(socialPlatform:))
            : platforms.map(ReachChannel.init(socialPlatform:))

        return await withTaskGroup(of: (Int, ReachResult).self) { group in
            for (index, channel) in channels.enumerated() {
                group.addTask {
                    let result = await self.search(channel: channel, query: query, limit: limit)
                    return (index, result)
                }
            }
            var ordered: [(Int, ReachResult)] = []
            for await pair in group {
                ordered.append(pair)
            }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Executes any `ReachRequest` across the channel's ordered fallback backends.
    public func execute(_ request: ReachRequest) async -> ReachResult {
        guard request.channel.supportedActions.contains(request.action) else {
            return .failure(
                channel: request.channel,
                action: request.action,
                error: ReachError(
                    code: .badInput,
                    message: "Channel '\(request.channel.rawValue)' does not support action '\(request.action.rawValue)'.",
                    hint: "Supported actions: \(request.channel.supportedActions.map(\.rawValue).joined(separator: ", "))."
                )
            )
        }

        let pipeline = backendPipeline(for: request)
        guard !pipeline.isEmpty else {
            return .failure(
                channel: request.channel,
                action: request.action,
                error: ReachError(code: .needSetup, message: "No backends available for \(request.channel.displayName).")
            )
        }

        var attempted: [String] = []
        var lastError: ReachError?

        for backend in pipeline {
            if Task.isCancelled {
                return .failure(
                    channel: request.channel,
                    action: request.action,
                    error: ReachError(code: .timeout, message: "Request was cancelled."),
                    attemptedBackends: attempted
                )
            }

            attempted.append(backend.name)
            do {
                let items = try await backend.execute(request: request)
                if !items.isEmpty {
                    return .success(
                        channel: request.channel,
                        action: request.action,
                        backend: backend.name,
                        items: items,
                        attemptedBackends: attempted
                    )
                }
                lastError = ReachError(
                    code: .notFound,
                    message: "No items returned by \(backend.name) for \(request.channel.displayName)."
                )
            } catch let reachError as ReachError {
                lastError = reachError
                switch reachError.code {
                case .badInput, .rateLimited, .platformBlocked, .busy:
                    return .failure(
                        channel: request.channel,
                        action: request.action,
                        error: reachError,
                        attemptedBackends: attempted
                    )
                case .needLogin, .needSetup, .upstreamBroken, .timeout, .notFound:
                    continue
                }
            } catch is CancellationError {
                return .failure(
                    channel: request.channel,
                    action: request.action,
                    error: ReachError(code: .timeout, message: "Request was cancelled."),
                    attemptedBackends: attempted
                )
            } catch {
                lastError = ReachError(code: .upstreamBroken, message: error.localizedDescription)
            }
        }

        return .failure(
            channel: request.channel,
            action: request.action,
            error: lastError ?? ReachError(code: .upstreamBroken, message: "All backends failed for \(request.channel.displayName)."),
            attemptedBackends: attempted
        )
    }

    internal func backendPipeline(for request: ReachRequest) -> [any ReachBackend] {
        if let preferred = request.preferredBackend?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            if let custom = customBackends[preferred] {
                return [custom]
            }
            if let builtIn = builtInBackend(named: preferred) {
                return [builtIn]
            }
        }

        var names: [String] = []
        switch request.channel {
        case .github:
            names = ["github-api"]
            if request.action == .read, URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            names.append("public-web")

        case .reddit:
            names = ["reddit-json"]
            if request.action == .read, URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            names.append("public-web")

        case .v2ex:
            names = ["v2ex-api", "public-web"]

        case .youtube:
            names = ["youtube-native"]
            if request.action == .read, URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            names.append("public-web")

        case .bilibili:
            names = ["bilibili-api"]
            if request.action == .read, URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            names.append("public-web")

        case .twitter:
            if request.action == .read || request.action == .thread {
                names.append("twitter-public")
            }
            if URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            names.append("public-web")

        case .xueqiu:
            if request.action == .quote {
                names.append("xueqiu-public")
            }
            if URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            names.append("public-web")

        case .xiaoyuzhou:
            if request.action == .read || request.action == .transcribe {
                names.append("xiaoyuzhou-native")
            }
            if request.action == .read, URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            if request.action != .transcribe {
                names.append("public-web")
            }

        case .xiaohongshu, .facebook, .instagram, .linkedin, .boss:
            if URL(string: request.target) != nil {
                names.append("jina-reader")
            }
            names.append("public-web")

        case .web:
            if request.action == .read {
                names = ["public-web", "jina-reader", "exa-mcp"]
            } else {
                names = ["public-web", "exa-mcp"]
            }
        }

        if configuration.enableLocalCLIFallback {
            names.append("agent-reach-cli")
        }

        // Filter optional backends by configuration.
        let filtered = names.filter { name in
            if name == "jina-reader" && !configuration.enableJinaReaderFallback { return false }
            if name == "exa-mcp" && !configuration.enableExaMCPFallback { return false }
            return true
        }

        return filtered.compactMap { name in
            customBackends[name] ?? builtInBackend(named: name)
        }
    }

    private func builtInBackend(named name: String) -> (any ReachBackend)? {
        switch name {
        case "github-api":
            return GitHubReachBackend(session: session, timeout: configuration.timeout, token: configuration.githubToken)
        case "reddit-json":
            return RedditReachBackend(session: session, timeout: configuration.timeout)
        case "v2ex-api":
            return V2EXReachBackend(session: session, timeout: configuration.timeout)
        case "youtube-native":
            return YouTubeReachBackend(session: session, timeout: configuration.timeout)
        case "bilibili-api":
            return BilibiliReachBackend(session: session, timeout: configuration.timeout)
        case "twitter-public":
            return TwitterReachBackend(session: session, timeout: configuration.timeout)
        case "xueqiu-public":
            return XueqiuReachBackend(session: session, timeout: configuration.timeout)
        case "xiaoyuzhou-native":
            return XiaoyuzhouReachBackend(session: session, timeout: configuration.timeout, groqAPIKey: configuration.groqAPIKey)
        case "jina-reader":
            return JinaReaderBackend(session: session, timeout: configuration.timeout)
        case "exa-mcp":
            return ExaMCPBackend(session: session, timeout: configuration.timeout)
        case "public-web":
            let discovery = DiscoveryEngine(session: session)
            let reader = NativeReader(session: session ?? .shared, timeout: configuration.timeout)
            return PublicWebReachBackend(discoveryEngine: discovery, nativeReader: reader)
        case "agent-reach-cli":
            return LocalCLIBridge(timeout: max(configuration.timeout, 30.0))
        default:
            return nil
        }
    }
}
