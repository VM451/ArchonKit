import Foundation

/// Structured error codes aligned with Agent Reach semantics.
public enum ReachErrorCode: String, Codable, Hashable, Sendable {
    case needSetup = "NEED_SETUP"
    case needLogin = "NEED_LOGIN"
    case upstreamBroken = "UPSTREAM_BROKEN"
    case timeout = "TIMEOUT"
    case rateLimited = "RATE_LIMITED"
    case platformBlocked = "PLATFORM_BLOCKED"
    case busy = "BUSY"
    case notFound = "NOT_FOUND"
    case badInput = "BAD_INPUT"
}

/// Structured error returned by Agent Reach operations.
public struct ReachError: Error, LocalizedError, Codable, Hashable, Sendable {
    public let code: ReachErrorCode
    public let message: String
    public let hint: String?
    public let retryAfterSeconds: TimeInterval?

    public init(
        code: ReachErrorCode,
        message: String,
        hint: String? = nil,
        retryAfterSeconds: TimeInterval? = nil
    ) {
        self.code = code
        self.message = message
        self.hint = hint
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var errorDescription: String? {
        if let hint, !hint.isEmpty {
            return "[\(code.rawValue)] \(message) (\(hint))"
        }
        return "[\(code.rawValue)] \(message)"
    }
}

/// A comment or reply attached to a `ReachItem`.
public struct ReachComment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let author: String?
    public let text: String
    public let publishedAt: Date?
    public let score: Int?
    public let parentID: String?

    public init(
        id: String = UUID().uuidString,
        author: String? = nil,
        text: String,
        publishedAt: Date? = nil,
        score: Int? = nil,
        parentID: String? = nil
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.publishedAt = publishedAt
        self.score = score
        self.parentID = parentID
    }
}

/// A unified read-only content item returned by any Agent Reach channel.
public struct ReachItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let author: String?
    public let publishedAt: Date?
    public let text: String
    public let channel: ReachChannel
    public let backend: String
    public let metadata: [String: String]
    public let comments: [ReachComment]

    public init(
        id: String = UUID().uuidString,
        title: String,
        url: URL,
        author: String? = nil,
        publishedAt: Date? = nil,
        text: String,
        channel: ReachChannel,
        backend: String,
        metadata: [String: String] = [:],
        comments: [ReachComment] = []
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.author = author
        self.publishedAt = publishedAt
        self.text = text
        self.channel = channel
        self.backend = backend
        self.metadata = metadata
        self.comments = comments
    }
}

/// Unified response envelope matching Agent Reach's `{ ok, channel, action, items, error }` contract.
public struct ReachResult: Codable, Hashable, Sendable {
    public let ok: Bool
    public let channel: ReachChannel
    public let action: ReachAction
    public let backend: String?
    public let items: [ReachItem]
    public let error: ReachError?
    public let attemptedBackends: [String]

    public init(
        ok: Bool,
        channel: ReachChannel,
        action: ReachAction,
        backend: String? = nil,
        items: [ReachItem] = [],
        error: ReachError? = nil,
        attemptedBackends: [String] = []
    ) {
        self.ok = ok
        self.channel = channel
        self.action = action
        self.backend = backend
        self.items = items
        self.error = error
        self.attemptedBackends = attemptedBackends
    }

    public static func success(
        channel: ReachChannel,
        action: ReachAction,
        backend: String,
        items: [ReachItem],
        attemptedBackends: [String] = []
    ) -> ReachResult {
        ReachResult(
            ok: true,
            channel: channel,
            action: action,
            backend: backend,
            items: items,
            error: nil,
            attemptedBackends: attemptedBackends.isEmpty ? [backend] : attemptedBackends
        )
    }

    public static func failure(
        channel: ReachChannel,
        action: ReachAction,
        error: ReachError,
        attemptedBackends: [String] = []
    ) -> ReachResult {
        ReachResult(
            ok: false,
            channel: channel,
            action: action,
            backend: nil,
            items: [],
            error: error,
            attemptedBackends: attemptedBackends
        )
    }
}

/// A request targeting a specific channel and action.
public struct ReachRequest: Codable, Hashable, Sendable {
    public var channel: ReachChannel
    public var action: ReachAction
    public var target: String
    public var limit: Int
    public var preferredBackend: String?
    public var language: String?
    public var extra: [String: String]

    public init(
        channel: ReachChannel,
        action: ReachAction,
        target: String,
        limit: Int = 5,
        preferredBackend: String? = nil,
        language: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.channel = channel
        self.action = action
        self.target = target
        self.limit = max(1, min(limit, 50))
        self.preferredBackend = preferredBackend
        self.language = language
        self.extra = extra
    }
}

/// Configuration for `AgentReachClient`.
public struct ReachConfiguration: Sendable, Codable, Hashable {
    /// Request timeout for individual network/backend calls.
    public var timeout: TimeInterval
    /// Optional GitHub personal access token for higher REST API rate limits.
    public var githubToken: String?
    /// Optional Groq API key for Whisper audio transcription (YouTube/Xiaoyuzhou).
    public var groqAPIKey: String?
    /// Enables Jina Reader (`https://r.jina.ai/...`) as a zero-key public-web markdown fallback.
    public var enableJinaReaderFallback: Bool
    /// Enables Exa's free hosted MCP (`https://mcp.exa.ai/mcp`) as a zero-key web search/read fallback.
    public var enableExaMCPFallback: Bool
    /// On macOS, allows delegating to a locally installed `agent-reach` / `yt-dlp` / `gh` CLI when native backends fail.
    public var enableLocalCLIFallback: Bool

    public init(
        timeout: TimeInterval = 15.0,
        githubToken: String? = nil,
        groqAPIKey: String? = nil,
        enableJinaReaderFallback: Bool = true,
        enableExaMCPFallback: Bool = true,
        enableLocalCLIFallback: Bool = false
    ) {
        self.timeout = timeout
        self.githubToken = githubToken
        self.groqAPIKey = groqAPIKey
        self.enableJinaReaderFallback = enableJinaReaderFallback
        self.enableExaMCPFallback = enableExaMCPFallback
        self.enableLocalCLIFallback = enableLocalCLIFallback
    }
}

/// Protocol for pluggable or mockable channel backends.
public protocol ReachBackend: Sendable {
    var name: String { get }
    func execute(request: ReachRequest) async throws -> [ReachItem]
}
