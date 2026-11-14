import Foundation

/// Maturity/availability tier of an Agent Reach channel.
public enum ReachChannelLevel: String, Codable, Hashable, Sendable {
    case `default`
    case optional
    case experimental
}

/// Unified action supported across Agent Reach channels.
public enum ReachAction: String, CaseIterable, Codable, Hashable, Sendable {
    case search
    case read
    case profile
    case comments
    case subtitle
    case transcribe
    case thread
    case tweets
    case subreddit
    case hot
    case node
    case user
    case quote
    case hotPosts = "hot_posts"
    case hotStocks = "hot_stocks"
    case jobs
    case posts

    public init?(identifier: String) {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "search": self = .search
        case "read": self = .read
        case "profile": self = .profile
        case "comments": self = .comments
        case "subtitle", "subtitles", "transcript": self = .subtitle
        case "transcribe": self = .transcribe
        case "thread": self = .thread
        case "tweets": self = .tweets
        case "subreddit": self = .subreddit
        case "hot": self = .hot
        case "node": self = .node
        case "user": self = .user
        case "quote", "stock": self = .quote
        case "hot_posts", "hotposts": self = .hotPosts
        case "hot_stocks", "hotstocks": self = .hotStocks
        case "jobs": self = .jobs
        case "posts": self = .posts
        default: return nil
        }
    }
}

/// All 14 Agent Reach channels supported natively by ArchonSearch.
///
/// Mirrors the Agent Reach channel model (`github`, `youtube`, `twitter`, `reddit`,
/// `facebook`, `instagram`, `bilibili`, `xiaohongshu`, `linkedin`, `boss`, `v2ex`,
/// `xueqiu`, `xiaoyuzhou`, `web`) with ordered native + public-web fallbacks and
/// optional macOS CLI delegation.
public enum ReachChannel: String, CaseIterable, Codable, Hashable, Sendable {
    case github
    case youtube
    case twitter
    case reddit
    case facebook
    case instagram
    case bilibili
    case xiaohongshu
    case linkedin
    case boss
    case v2ex
    case xueqiu
    case xiaoyuzhou
    case web

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .youtube: return "YouTube"
        case .twitter: return "Twitter/X"
        case .reddit: return "Reddit"
        case .facebook: return "Facebook"
        case .instagram: return "Instagram"
        case .bilibili: return "Bilibili"
        case .xiaohongshu: return "Xiaohongshu"
        case .linkedin: return "LinkedIn"
        case .boss: return "Boss Zhipin"
        case .v2ex: return "V2EX"
        case .xueqiu: return "Xueqiu"
        case .xiaoyuzhou: return "Xiaoyuzhou"
        case .web: return "Web"
        }
    }

    /// Agent Reach channel tier.
    public var level: ReachChannelLevel {
        switch self {
        case .github, .youtube, .bilibili, .v2ex, .web:
            return .default
        case .reddit, .xiaohongshu, .linkedin, .boss, .xueqiu, .xiaoyuzhou:
            return .optional
        case .twitter, .facebook, .instagram:
            return .experimental
        }
    }

    /// Actions declared by this channel.
    public var supportedActions: [ReachAction] {
        switch self {
        case .github: return [.search, .read]
        case .youtube: return [.read, .search, .subtitle, .transcribe]
        case .twitter: return [.search, .profile, .tweets, .thread, .read]
        case .reddit: return [.search, .read, .subreddit]
        case .facebook: return [.search, .profile, .read]
        case .instagram: return [.search, .profile, .posts, .read]
        case .bilibili: return [.search, .read, .hot, .subtitle]
        case .xiaohongshu: return [.search, .read, .comments]
        case .linkedin: return [.jobs, .read, .search]
        case .boss: return [.search, .read]
        case .v2ex: return [.hot, .node, .read, .user, .search]
        case .xueqiu: return [.quote, .search, .hotPosts, .hotStocks, .read]
        case .xiaoyuzhou: return [.transcribe, .read, .search]
        case .web: return [.search, .read]
        }
    }

    /// Public domains owned by this channel.
    public var domains: [String] {
        switch self {
        case .github: return ["github.com"]
        case .youtube: return ["youtube.com", "youtu.be"]
        case .twitter: return ["x.com", "twitter.com"]
        case .reddit: return ["reddit.com", "old.reddit.com", "redd.it"]
        case .facebook: return ["facebook.com", "fb.com", "m.facebook.com"]
        case .instagram: return ["instagram.com", "instagr.am"]
        case .bilibili: return ["bilibili.com", "b23.tv"]
        case .xiaohongshu: return ["xiaohongshu.com", "xhslink.com"]
        case .linkedin: return ["linkedin.com"]
        case .boss: return ["zhipin.com"]
        case .v2ex: return ["v2ex.com"]
        case .xueqiu: return ["xueqiu.com"]
        case .xiaoyuzhou: return ["xiaoyuzhoufm.com"]
        case .web: return []
        }
    }

    /// Whether authenticated/browser-backed actions may require user login when public access is gated.
    public var mayRequireLogin: Bool {
        switch self {
        case .twitter, .facebook, .instagram, .bilibili, .xiaohongshu, .linkedin, .boss, .xueqiu, .reddit:
            return true
        case .github, .youtube, .v2ex, .xiaoyuzhou, .web:
            return false
        }
    }

    /// Bridges to `SocialPlatform` when a 1:1 mapping exists.
    public var socialPlatform: SocialPlatform? {
        switch self {
        case .github: return .github
        case .youtube: return .youtube
        case .twitter: return .twitter
        case .reddit: return .reddit
        case .facebook: return .facebook
        case .instagram: return .instagram
        case .bilibili: return .bilibili
        case .xiaohongshu: return .xiaohongshu
        case .linkedin: return .linkedin
        case .v2ex: return .v2ex
        case .boss, .xueqiu, .xiaoyuzhou, .web: return nil
        }
    }

    /// Bridges from `SocialPlatform`.
    public init(socialPlatform: SocialPlatform) {
        switch socialPlatform {
        case .twitter: self = .twitter
        case .reddit: self = .reddit
        case .youtube: self = .youtube
        case .github: self = .github
        case .bilibili: self = .bilibili
        case .facebook: self = .facebook
        case .instagram: self = .instagram
        case .linkedin: self = .linkedin
        case .xiaohongshu: self = .xiaohongshu
        case .v2ex: self = .v2ex
        }
    }

    /// Resolves a channel from a user- or agent-facing identifier.
    public init?(identifier: String) {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "/", with: "")

        switch normalized {
        case "github", "gh": self = .github
        case "youtube", "yt": self = .youtube
        case "twitter", "x", "twitterx", "xtwitter": self = .twitter
        case "reddit": self = .reddit
        case "facebook", "fb": self = .facebook
        case "instagram", "ig": self = .instagram
        case "bilibili", "bili", "b站": self = .bilibili
        case "xiaohongshu", "xhs", "littleredbook": self = .xiaohongshu
        case "linkedin": self = .linkedin
        case "boss", "bosszhipin", "zhipin": self = .boss
        case "v2ex": self = .v2ex
        case "xueqiu", "雪球": self = .xueqiu
        case "xiaoyuzhou", "xiaoyuzhoufm", "小宇宙": self = .xiaoyuzhou
        case "web", "http", "https": self = .web
        default: return nil
        }
    }

    /// Selects the most specific channel for a URL, defaulting to `.web` for public HTTP(S) URLs.
    public static func channel(for url: URL) -> ReachChannel {
        guard let host = url.host?.lowercased() else { return .web }
        for channel in allCases where channel != .web {
            if channel.domains.contains(where: { domain in
                host == domain || host.hasSuffix("." + domain)
            }) {
                return channel
            }
        }
        return .web
    }
}
