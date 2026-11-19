import Foundation

/// Curated host-authority tiers for AI grounding.
///
/// Lets a model weigh `developer.apple.com` over a random SEO blog without a
/// network call: fully deterministic, derived from the URL host alone.
/// Unknown hosts land in `.standard`, never zero, so long-tail sources are
/// down-weighted rather than excluded.
public enum SearchHostAuthority: Sendable {
    /// Authority tier, highest first.
    public enum Tier: String, Sendable, Codable, Hashable {
        case official
        case trusted
        case standard
        case unverified
    }

    /// Numeric weight in `0...1` for a tier.
    public static func weight(for tier: Tier) -> Double {
        switch tier {
        case .official: return 1.0
        case .trusted: return 0.8
        case .standard: return 0.5
        case .unverified: return 0.25
        }
    }

    /// Classifies a host into an authority tier.
    public static func tier(forHost host: String?) -> Tier {
        guard let host else { return .unverified }
        let lower = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return .unverified }
        let bare = lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        if officialHosts.contains(bare) || officialSuffixes.contains(where: { bare == $0 || bare.hasSuffix("." + $0) }) {
            return .official
        }
        if trustedHosts.contains(bare) {
            return .trusted
        }
        if bare.hasSuffix(".gov") || bare.hasSuffix(".edu") || bare.hasSuffix(".gov.uk") {
            return .trusted
        }
        if spammyTokens.contains(where: { bare.contains($0) }) {
            return .unverified
        }
        return .standard
    }

    /// Numeric authority `0...1` for a host.
    public static func score(host: String?) -> Double {
        weight(for: tier(forHost: host))
    }

    /// Numeric authority `0...1` for a URL.
    public static func score(url: URL) -> Double {
        score(host: url.host)
    }

    // MARK: - Curated lists

    /// First-party documentation, standards bodies, and language owners.
    private static let officialHosts: Set<String> = [
        "developer.apple.com",
        "swift.org",
        "docs.swift.org",
        "forums.swift.org",
        "developer.android.com",
        "developer.mozilla.org",
        "docs.python.org",
        "docs.rs",
        "pkg.go.dev",
        "go.dev",
        "learn.microsoft.com",
        "docs.microsoft.com",
        "cloud.google.com",
        "docs.aws.amazon.com",
        "kubernetes.io",
        "ietf.org",
        "datatracker.ietf.org",
        "rsc-editorial.org",
        "w3.org",
        "whatwg.org",
        "tc39.es",
        "openai.com",
        "platform.openai.com",
        "anthropic.com",
        "docs.anthropic.com",
        "huggingface.co",
        "pytorch.org",
        "tensorflow.org",
    ]

    /// Suffixes whose every subdomain is official (per-language docs, WWDC).
    private static let officialSuffixes: Set<String> = [
        "developer.apple.com",
        "swift.org",
        "python.org",
        "rust-lang.org",
        "golang.org",
    ]

    /// High-signal publishers: encyclopedias, code hosts, Q&A, papers.
    private static let trustedHosts: Set<String> = [
        "wikipedia.org",
        "en.wikipedia.org",
        "github.com",
        "gist.github.com",
        "stackoverflow.com",
        "stackexchange.com",
        "serverfault.com",
        "arxiv.org",
        "paperswithcode.com",
        "medium.com",
        "dev.to",
        "hackingwithswift.com",
        "swiftbysundell.com",
        "nshipster.com",
        "useyourloaf.com",
        "swiftsenpai.com",
        "avanderlee.com",
        "createwithswift.com",
        "tuto.io",
        "raywenderlich.com",
        "kodeco.com",
        "bbc.com",
        "reuters.com",
        "nature.com",
        "science.org",
    ]

    /// Host-token signals for SEO-spam / scraper farms.
    private static let spammyTokens: Set<String> = [
        "content-farm",
        "article-spinner",
        "essaymill",
    ]
}
