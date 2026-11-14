import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Reddit public JSON API backend supporting search, subreddit feeds, and post + comment threads.
internal struct RedditReachBackend: ReachBackend, Sendable {
    let name = "reddit-json"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    private var headers: [String: String] {
        [
            "User-Agent": "ArchonSearch/2.0 (by /u/archon_sdk)",
            "Accept": "application/json"
        ]
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .search:
            return try await search(query: request.target, limit: request.limit)
        case .subreddit:
            return try await subreddit(name: request.target, limit: request.limit)
        case .read:
            return try await readPost(target: request.target)
        default:
            throw ReachError(code: .badInput, message: "Reddit channel does not support action '\(request.action.rawValue)'.")
        }
    }

    private func search(query: String, limit: Int) async throws -> [ReachItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReachError(code: .badInput, message: "Reddit search requires a non-empty query.")
        }
        var components = URLComponents(string: "https://www.reddit.com/search.json")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 25))),
            URLQueryItem(name: "raw_json", value: "1")
        ]
        guard let url = components?.url else {
            throw ReachError(code: .badInput, message: "Invalid Reddit search query.")
        }
        return try await fetchListing(url: url, limit: limit)
    }

    private func subreddit(name subName: String, limit: Int) async throws -> [ReachItem] {
        let clean = subName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "r/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty, clean.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else {
            throw ReachError(code: .badInput, message: "Invalid subreddit name: '\(subName)'.")
        }
        var components = URLComponents(string: "https://www.reddit.com/r/\(clean)/hot.json")
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 25))),
            URLQueryItem(name: "raw_json", value: "1")
        ]
        guard let url = components?.url else {
            throw ReachError(code: .badInput, message: "Invalid subreddit URL.")
        }
        return try await fetchListing(url: url, limit: limit)
    }

    private func fetchListing(url: URL, limit: Int) async throws -> [ReachItem] {
        let json = try await ReachHTTPHelper.fetchJSON(
            url: url,
            headers: headers,
            timeout: timeout,
            session: session,
            provider: "Reddit JSON API"
        )
        guard let root = json as? [String: Any],
              let data = root["data"] as? [String: Any],
              let children = data["children"] as? [[String: Any]] else {
            return []
        }

        return children.prefix(limit).compactMap { child in
            guard let post = child["data"] as? [String: Any] else { return nil }
            return Self.itemFromPost(post, backend: name)
        }
    }

    private func readPost(target: String) async throws -> [ReachItem] {
        guard let jsonURL = Self.postJSONURL(from: target) else {
            throw ReachError(code: .badInput, message: "Target must be a valid reddit.com post URL.")
        }

        let json = try await ReachHTTPHelper.fetchJSON(
            url: jsonURL,
            headers: headers,
            timeout: timeout,
            session: session,
            provider: "Reddit JSON API"
        )

        guard let listings = json as? [[String: Any]], !listings.isEmpty else {
            throw ReachError(code: .upstreamBroken, message: "Unexpected Reddit post JSON structure.")
        }

        guard let postListing = listings.first?["data"] as? [String: Any],
              let postChildren = postListing["children"] as? [[String: Any]],
              let postData = postChildren.first?["data"] as? [String: Any],
              let baseItem = Self.itemFromPost(postData, backend: name) else {
            throw ReachError(code: .notFound, message: "Reddit post not found.")
        }

        var comments: [ReachComment] = []
        if listings.count > 1,
           let commentListing = listings[1]["data"] as? [String: Any],
           let commentChildren = commentListing["children"] as? [[String: Any]] {
            Self.collectComments(from: commentChildren, into: &comments, limit: 40)
        }

        return [
            ReachItem(
                id: baseItem.id,
                title: baseItem.title,
                url: baseItem.url,
                author: baseItem.author,
                publishedAt: baseItem.publishedAt,
                text: baseItem.text,
                channel: .reddit,
                backend: name,
                metadata: baseItem.metadata,
                comments: comments
            )
        ]
    }

    internal static func postJSONURL(from target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              host == "reddit.com" || host.hasSuffix(".reddit.com") else {
            return nil
        }
        components.scheme = "https"
        if !components.path.hasSuffix(".json") {
            let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            components.path = path + ".json"
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "raw_json" }) {
            items.append(URLQueryItem(name: "raw_json", value: "1"))
        }
        components.queryItems = items
        return components.url
    }

    private static func itemFromPost(_ post: [String: Any], backend: String) -> ReachItem? {
        let title = (post["title"] as? String) ?? "Reddit Post"
        let permalink = (post["permalink"] as? String) ?? ""
        let rawURL = permalink.isEmpty ? (post["url"] as? String ?? "") : "https://www.reddit.com\(permalink)"
        guard let url = URL(string: rawURL) else { return nil }

        let author = post["author"] as? String
        let selftext = (post["selftext"] as? String) ?? ""
        let externalURL = (post["url"] as? String) ?? ""
        let subreddit = (post["subreddit_name_prefixed"] as? String) ?? (post["subreddit"] as? String ?? "")
        let score = post["score"] as? Int ?? 0
        let numComments = post["num_comments"] as? Int ?? 0
        let createdUTC = post["created_utc"] as? Double
        let publishedAt = createdUTC.map { Date(timeIntervalSince1970: $0) }
        let id = (post["id"] as? String) ?? url.absoluteString

        let body: String
        if !selftext.isEmpty {
            body = selftext
        } else if !externalURL.isEmpty && externalURL != url.absoluteString {
            body = "Link: \(externalURL)"
        } else {
            body = title
        }

        return ReachItem(
            id: id,
            title: title,
            url: url,
            author: author,
            publishedAt: publishedAt,
            text: body,
            channel: .reddit,
            backend: backend,
            metadata: [
                "subreddit": subreddit,
                "score": String(score),
                "num_comments": String(numComments)
            ]
        )
    }

    private static func collectComments(from children: [[String: Any]], into output: inout [ReachComment], limit: Int) {
        for child in children {
            guard output.count < limit else { return }
            guard (child["kind"] as? String) == "t1",
                  let data = child["data"] as? [String: Any],
                  let body = data["body"] as? String,
                  !body.isEmpty else {
                continue
            }
            let id = (data["id"] as? String) ?? UUID().uuidString
            let author = data["author"] as? String
            let score = data["score"] as? Int
            let parentID = data["parent_id"] as? String
            let createdUTC = (data["created_utc"] as? Double).map { Date(timeIntervalSince1970: $0) }

            output.append(ReachComment(
                id: id,
                author: author,
                text: body,
                publishedAt: createdUTC,
                score: score,
                parentID: parentID
            ))

            if let replies = data["replies"] as? [String: Any],
               let repliesData = replies["data"] as? [String: Any],
               let nestedChildren = repliesData["children"] as? [[String: Any]] {
                collectComments(from: nestedChildren, into: &output, limit: limit)
            }
        }
    }
}
