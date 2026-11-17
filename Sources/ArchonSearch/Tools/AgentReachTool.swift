import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModelsMacros)
@FoundationModels.Generable
public struct AgentReachArguments: Sendable, Codable {
    public var channel: String?
    public var action: String
    public var target: String
    public var limit: Int?
    public var language: String?

    public init(
        channel: String? = nil,
        action: String = "read",
        target: String,
        limit: Int? = nil,
        language: String? = nil
    ) {
        self.channel = channel
        self.action = action
        self.target = target
        self.limit = limit
        self.language = language
    }
}
#else
public struct AgentReachArguments: Sendable, Codable {
    public var channel: String?
    public var action: String
    public var target: String
    public var limit: Int?
    public var language: String?

    public init(
        channel: String? = nil,
        action: String = "read",
        target: String,
        limit: Int? = nil,
        language: String? = nil
    ) {
        self.channel = channel
        self.action = action
        self.target = target
        self.limit = limit
        self.language = language
    }
}
#endif

/// High-level read-only Agent Reach tool supporting 14 social, developer, video, podcast, finance, and web channels.
public struct AgentReachTool: Tool, Sendable {
    public let name = "agent_reach"
    public let description = "Read-only multi-platform content reach across GitHub, YouTube, Twitter/X, Reddit, Facebook, Instagram, Bilibili, Xiaohongshu, LinkedIn, Boss Zhipin, V2EX, Xueqiu, Xiaoyuzhou, and Web."
    public let client: AgentReachClient

    public init(configuration: ReachConfiguration = ReachConfiguration()) {
        self.client = AgentReachClient(configuration: configuration)
    }

    public init(client: AgentReachClient) {
        self.client = client
    }

    /// Primary structured execution entry point.
    public func execute(
        channel channelIdentifier: String? = nil,
        action actionIdentifier: String = "read",
        target: String,
        limit: Int? = nil,
        language: String? = nil
    ) async throws -> String {
        let resolvedChannel: ReachChannel
        if let channelIdentifier, !channelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = ReachChannel(identifier: channelIdentifier) else {
                throw SearchError.extraction(reason: "Unknown channel '\(channelIdentifier)'.")
            }
            resolvedChannel = parsed
        } else if let url = URL(string: target.trimmingCharacters(in: .whitespacesAndNewlines)) {
            resolvedChannel = ReachChannel.channel(for: url)
        } else {
            resolvedChannel = .web
        }

        guard let action = ReachAction(identifier: actionIdentifier) else {
            throw SearchError.extraction(reason: "Unknown action '\(actionIdentifier)'.")
        }

        let request = ReachRequest(
            channel: resolvedChannel,
            action: action,
            target: target,
            limit: limit ?? 5,
            language: language
        )
        let result = await client.execute(request)
        return Self.formatResult(result)
    }

    /// Invokes the tool using a JSON string.
    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let target = (json["target"] as? String) ?? (json["url"] as? String) ?? (json["query"] as? String) else {
            throw SearchError.extraction(reason: "agent_reach requires a 'target' (URL, query, or ID) parameter.")
        }

        let channel = json["channel"] as? String
        let action = (json["action"] as? String) ?? (URL(string: target)?.scheme != nil ? "read" : "search")
        let limit = json["limit"] as? Int
        let language = json["language"] as? String
        return try await execute(channel: channel, action: action, target: target, limit: limit, language: language)
    }

    internal static func formatResult(_ result: ReachResult) -> String {
        if !result.ok, let error = result.error {
            var lines = [
                "Channel: \(result.channel.displayName) (\(result.action.rawValue))",
                "Status: ERROR [\(error.code.rawValue)]",
                "Message: \(error.message)"
            ]
            if let hint = error.hint {
                lines.append("Hint: \(hint)")
            }
            return lines.joined(separator: "\n")
        }

        var blocks: [String] = [
            "# \(result.channel.displayName) (\(result.action.rawValue)) via \(result.backend ?? "unknown")"
        ]

        for (index, item) in result.items.enumerated() {
            var lines: [String] = [
                "[\(index + 1)] \(item.title)",
                "URL: \(item.url.absoluteString)"
            ]
            if let author = item.author, !author.isEmpty {
                lines.append("Author: \(author)")
            }
            if !item.text.isEmpty {
                lines.append(item.text)
            }
            if !item.comments.isEmpty {
                let topComments = item.comments.prefix(10).map { comment in
                    let who = comment.author ?? "anonymous"
                    return "- \(who): \(comment.text)"
                }.joined(separator: "\n")
                lines.append("Comments (\(item.comments.count)):\n\(topComments)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
    }
}

#if canImport(FoundationModelsMacros)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
extension AgentReachTool: FoundationModels.Tool {
    public typealias Arguments = AgentReachArguments
    public typealias Output = String

    public func call(arguments: AgentReachArguments) async throws -> String {
        try await execute(
            channel: arguments.channel,
            action: arguments.action,
            target: arguments.target,
            limit: arguments.limit,
            language: arguments.language
        )
    }
}
#endif
