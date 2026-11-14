import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native V2EX public JSON API backend (`hot`, `node`, `read`, `user`).
internal struct V2EXReachBackend: ReachBackend, Sendable {
    let name = "v2ex-api"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .hot:
            return try await fetchTopics(urlString: "https://www.v2ex.com/api/topics/hot.json", limit: request.limit)
        case .node:
            let node = request.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !node.isEmpty, let encoded = node.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw ReachError(code: .badInput, message: "V2EX node action requires a node name.")
            }
            return try await fetchTopics(urlString: "https://www.v2ex.com/api/topics/show.json?node_name=\(encoded)", limit: request.limit)
        case .user:
            let username = request.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty, let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw ReachError(code: .badInput, message: "V2EX user action requires a username.")
            }
            return try await fetchTopics(urlString: "https://www.v2ex.com/api/topics/show.json?username=\(encoded)", limit: request.limit)
        case .read:
            guard let topicID = Self.extractTopicID(from: request.target) else {
                throw ReachError(code: .badInput, message: "Target must be a V2EX topic ID or v2ex.com/t/<id> URL.")
            }
            return try await readTopic(id: topicID)
        default:
            throw ReachError(code: .badInput, message: "V2EX API backend does not support action '\(request.action.rawValue)'.")
        }
    }

    private func fetchTopics(urlString: String, limit: Int) async throws -> [ReachItem] {
        guard let url = URL(string: urlString) else {
            throw ReachError(code: .badInput, message: "Invalid V2EX API URL.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(url: url, timeout: timeout, session: session, provider: "V2EX API")
        guard let topics = json as? [[String: Any]] else {
            throw ReachError(code: .upstreamBroken, message: "Unexpected V2EX API response.")
        }
        return topics.prefix(limit).compactMap(Self.itemFromTopic)
    }

    private func readTopic(id: String) async throws -> [ReachItem] {
        guard let topicURL = URL(string: "https://www.v2ex.com/api/topics/show.json?id=\(id)") else {
            throw ReachError(code: .badInput, message: "Invalid V2EX topic ID.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(url: topicURL, timeout: timeout, session: session, provider: "V2EX API")
        guard let topics = json as? [[String: Any]], let first = topics.first, let item = Self.itemFromTopic(first) else {
            throw ReachError(code: .notFound, message: "V2EX topic \(id) not found.")
        }

        var comments: [ReachComment] = []
        if let repliesURL = URL(string: "https://www.v2ex.com/api/replies/show.json?topic_id=\(id)"),
           let replies = try? await ReachHTTPHelper.fetchJSON(url: repliesURL, timeout: timeout, session: session, provider: "V2EX API") as? [[String: Any]] {
            comments = replies.prefix(50).compactMap { reply in
                guard let content = reply["content"] as? String else { return nil }
                let replyID = (reply["id"] as? Int).map(String.init) ?? UUID().uuidString
                let member = (reply["member"] as? [String: Any])?["username"] as? String
                let created = (reply["created"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return ReachComment(id: replyID, author: member, text: content, publishedAt: created)
            }
        }

        return [
            ReachItem(
                id: item.id,
                title: item.title,
                url: item.url,
                author: item.author,
                publishedAt: item.publishedAt,
                text: item.text,
                channel: .v2ex,
                backend: name,
                metadata: item.metadata,
                comments: comments
            )
        ]
    }

    internal static func extractTopicID(from target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty {
            return trimmed
        }
        let pattern = #"v2ex\.com/t/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[range])
    }

    private static func itemFromTopic(_ topic: [String: Any]) -> ReachItem? {
        guard let id = topic["id"] as? Int,
              let title = topic["title"] as? String else {
            return nil
        }
        let urlStr = (topic["url"] as? String) ?? "https://www.v2ex.com/t/\(id)"
        guard let url = URL(string: urlStr) else { return nil }
        let content = (topic["content"] as? String) ?? ""
        let author = (topic["member"] as? [String: Any])?["username"] as? String
        let node = (topic["node"] as? [String: Any])?["name"] as? String ?? ""
        let replies = topic["replies"] as? Int ?? 0
        let created = (topic["created"] as? Double).map { Date(timeIntervalSince1970: $0) }

        return ReachItem(
            id: String(id),
            title: title,
            url: url,
            author: author,
            publishedAt: created,
            text: content.isEmpty ? title : content,
            channel: .v2ex,
            backend: "v2ex-api",
            metadata: [
                "node": node,
                "replies": String(replies)
            ]
        )
    }
}
