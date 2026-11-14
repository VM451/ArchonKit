import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native GitHub REST API backend supporting repository search, repo/README read, and issue/PR + comments.
internal struct GitHubReachBackend: ReachBackend, Sendable {
    let name = "github-api"
    private let session: URLSession?
    private let timeout: TimeInterval
    private let token: String?

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0, token: String? = nil) {
        self.session = session
        self.timeout = timeout
        self.token = token
    }

    private var defaultHeaders: [String: String] {
        var headers = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ArchonSearch/2.0"
        ]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .search:
            return try await searchRepositories(query: request.target, limit: request.limit)
        case .read:
            return try await readTarget(request.target)
        default:
            throw ReachError(code: .badInput, message: "GitHub channel does not support action '\(request.action.rawValue)'.")
        }
    }

    private func searchRepositories(query: String, limit: Int) async throws -> [ReachItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReachError(code: .badInput, message: "GitHub search requires a non-empty query.")
        }
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 30)))
        ]
        guard let url = components?.url else {
            throw ReachError(code: .badInput, message: "Invalid GitHub search query.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(
            url: url,
            headers: defaultHeaders,
            timeout: timeout,
            session: session,
            provider: "GitHub API"
        )
        guard let dict = json as? [String: Any],
              let rawItems = dict["items"] as? [[String: Any]] else {
            return []
        }

        return rawItems.prefix(limit).compactMap { repo -> ReachItem? in
            guard let fullName = repo["full_name"] as? String,
                  let htmlURLStr = repo["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLStr) else {
                return nil
            }
            let description = (repo["description"] as? String) ?? ""
            let stars = repo["stargazers_count"] as? Int ?? 0
            let language = repo["language"] as? String ?? ""
            let owner = (repo["owner"] as? [String: Any])?["login"] as? String
            let updatedAt = ReachHTTPHelper.parseISO8601Date(repo["updated_at"] as? String)
            let summary = [
                description.isEmpty ? nil : description,
                "Stars: \(stars)" + (language.isEmpty ? "" : " | Language: \(language)")
            ].compactMap { $0 }.joined(separator: "\n")

            return ReachItem(
                id: fullName,
                title: fullName,
                url: htmlURL,
                author: owner,
                publishedAt: updatedAt,
                text: summary,
                channel: .github,
                backend: name,
                metadata: [
                    "stars": String(stars),
                    "language": language
                ]
            )
        }
    }

    private func readTarget(_ target: String) async throws -> [ReachItem] {
        guard let parsed = Self.parseTarget(target) else {
            throw ReachError(
                code: .badInput,
                message: "GitHub target must be 'owner/repo' or a github.com repository, issue, or PR URL."
            )
        }

        if let issueNumber = parsed.issueNumber {
            return try await readIssueOrPR(owner: parsed.owner, repo: parsed.repo, number: issueNumber)
        }
        return try await readRepository(owner: parsed.owner, repo: parsed.repo)
    }

    private func readRepository(owner: String, repo: String) async throws -> [ReachItem] {
        guard let repoURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else {
            throw ReachError(code: .badInput, message: "Invalid repository coordinates.")
        }
        let repoJSON = try await ReachHTTPHelper.fetchJSON(
            url: repoURL,
            headers: defaultHeaders,
            timeout: timeout,
            session: session,
            provider: "GitHub API"
        )
        guard let dict = repoJSON as? [String: Any],
              let fullName = dict["full_name"] as? String,
              let htmlURLStr = dict["html_url"] as? String,
              let htmlURL = URL(string: htmlURLStr) else {
            throw ReachError(code: .upstreamBroken, message: "Unexpected GitHub repository response.")
        }

        let description = (dict["description"] as? String) ?? ""
        let stars = dict["stargazers_count"] as? Int ?? 0
        let forks = dict["forks_count"] as? Int ?? 0
        let language = dict["language"] as? String ?? ""
        let defaultBranch = dict["default_branch"] as? String ?? "main"
        let updatedAt = ReachHTTPHelper.parseISO8601Date(dict["updated_at"] as? String)

        var readmeText = ""
        if let readmeURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/readme"),
           let readmeJSON = try? await ReachHTTPHelper.fetchJSON(
                url: readmeURL,
                headers: defaultHeaders,
                timeout: timeout,
                session: session,
                provider: "GitHub API"
           ) as? [String: Any],
           let encoded = readmeJSON["content"] as? String {
            let cleanBase64 = encoded.replacingOccurrences(of: "\n", with: "")
            if let data = Data(base64Encoded: cleanBase64),
               let decoded = String(data: data, encoding: .utf8) {
                readmeText = String(decoded.prefix(50_000))
            }
        }

        var parts: [String] = []
        if !description.isEmpty { parts.append(description) }
        parts.append("Stars: \(stars) | Forks: \(forks) | Default branch: \(defaultBranch)" + (language.isEmpty ? "" : " | Language: \(language)"))
        if !readmeText.isEmpty {
            parts.append("## README\n\(readmeText)")
        }

        return [
            ReachItem(
                id: fullName,
                title: fullName,
                url: htmlURL,
                author: owner,
                publishedAt: updatedAt,
                text: parts.joined(separator: "\n\n"),
                channel: .github,
                backend: name,
                metadata: [
                    "stars": String(stars),
                    "forks": String(forks),
                    "language": language,
                    "default_branch": defaultBranch
                ]
            )
        ]
    }

    private func readIssueOrPR(owner: String, repo: String, number: Int) async throws -> [ReachItem] {
        guard let issueURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)") else {
            throw ReachError(code: .badInput, message: "Invalid issue/PR coordinates.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(
            url: issueURL,
            headers: defaultHeaders,
            timeout: timeout,
            session: session,
            provider: "GitHub API"
        )
        guard let dict = json as? [String: Any],
              let title = dict["title"] as? String,
              let htmlURLStr = dict["html_url"] as? String,
              let htmlURL = URL(string: htmlURLStr) else {
            throw ReachError(code: .upstreamBroken, message: "Unexpected GitHub issue response.")
        }

        let body = (dict["body"] as? String) ?? ""
        let state = (dict["state"] as? String) ?? "unknown"
        let author = (dict["user"] as? [String: Any])?["login"] as? String
        let createdAt = ReachHTTPHelper.parseISO8601Date(dict["created_at"] as? String)

        var comments: [ReachComment] = []
        if let commentsURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)/comments?per_page=30"),
           let rawComments = try? await ReachHTTPHelper.fetchJSON(
                url: commentsURL,
                headers: defaultHeaders,
                timeout: timeout,
                session: session,
                provider: "GitHub API"
           ) as? [[String: Any]] {
            comments = rawComments.compactMap { entry in
                guard let commentBody = entry["body"] as? String else { return nil }
                let commentAuthor = (entry["user"] as? [String: Any])?["login"] as? String
                let commentID = (entry["id"] as? Int).map(String.init) ?? UUID().uuidString
                let commentDate = ReachHTTPHelper.parseISO8601Date(entry["created_at"] as? String)
                return ReachComment(id: commentID, author: commentAuthor, text: commentBody, publishedAt: commentDate)
            }
        }

        return [
            ReachItem(
                id: "\(owner)/\(repo)#\(number)",
                title: title,
                url: htmlURL,
                author: author,
                publishedAt: createdAt,
                text: body,
                channel: .github,
                backend: name,
                metadata: [
                    "state": state,
                    "number": String(number),
                    "comments_count": String(comments.count)
                ],
                comments: comments
            )
        ]
    }

    internal static func parseTarget(_ target: String) -> (owner: String, repo: String, issueNumber: Int?)? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:https?://(?:www\.)?github\.com/)?([\w.-]+)/([\w.-]+?)(?:\.git)?(?:/(?:issues|pull)/(\d+))?/?(?:[?#].*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let ownerRange = Range(match.range(at: 1), in: trimmed),
              let repoRange = Range(match.range(at: 2), in: trimmed) else {
            return nil
        }
        let owner = String(trimmed[ownerRange])
        let repo = String(trimmed[repoRange])
        var issueNumber: Int?
        if match.range(at: 3).location != NSNotFound,
           let numRange = Range(match.range(at: 3), in: trimmed) {
            issueNumber = Int(trimmed[numRange])
        }
        return (owner, repo, issueNumber)
    }
}
