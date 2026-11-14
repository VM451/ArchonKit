import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Zero-key markdown extraction via Jina Reader (`https://r.jina.ai/<url>`) and Exa free MCP.
internal struct JinaReaderBackend: ReachBackend, Sendable {
    let name = "jina-reader"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        guard let targetURL = URL(string: request.target), SearchURLPolicy.validate(targetURL) else {
            throw ReachError(code: .badInput, message: "Target must be a valid public HTTP(S) URL.")
        }
        guard let jinaURL = URL(string: "https://r.jina.ai/" + targetURL.absoluteString) else {
            throw ReachError(code: .badInput, message: "Could not construct Jina Reader URL.")
        }

        let body = try await ReachHTTPHelper.fetchString(
            url: jinaURL,
            headers: [
                "Accept": "text/markdown, text/plain;q=0.9",
                "X-Return-Format": "markdown"
            ],
            timeout: timeout,
            session: session,
            provider: "Jina Reader"
        )

        if let blocked = ReachHTTPHelper.detectChallengeOrLoginWall(in: body, channel: request.channel) {
            throw blocked
        }

        let parsed = Self.parseJinaMarkdown(body, fallbackURL: targetURL)
        guard !parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReachError(code: .upstreamBroken, message: "Jina Reader returned empty content.")
        }

        return [
            ReachItem(
                id: targetURL.absoluteString,
                title: parsed.title,
                url: targetURL,
                author: parsed.author,
                publishedAt: parsed.publishedAt,
                text: parsed.text,
                channel: request.channel,
                backend: name,
                metadata: ["source_url": targetURL.absoluteString]
            )
        ]
    }

    static func parseJinaMarkdown(_ raw: String, fallbackURL: URL) -> (title: String, author: String?, publishedAt: Date?, text: String) {
        var title = fallbackURL.host ?? fallbackURL.absoluteString
        var author: String?
        var publishedAt: Date?
        var bodyLines: [String] = []
        var inHeader = true

        for line in raw.components(separatedBy: .newlines) {
            if inHeader {
                if line.hasPrefix("Title:") {
                    let value = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { title = value }
                    continue
                } else if line.hasPrefix("URL Source:") || line.hasPrefix("URL:") {
                    continue
                } else if line.hasPrefix("Author:") {
                    let value = line.dropFirst("Author:".count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { author = value }
                    continue
                } else if line.hasPrefix("Published Time:") || line.hasPrefix("Published:") {
                    let value = line.split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) }
                    publishedAt = ReachHTTPHelper.parseISO8601Date(value)
                    continue
                } else if line.hasPrefix("Markdown Content:") {
                    inHeader = false
                    continue
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                } else {
                    inHeader = false
                }
            }
            bodyLines.append(line)
        }

        let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, author, publishedAt, text)
    }
}

/// Zero-key web search and page extraction via Exa's hosted MCP endpoint (`https://mcp.exa.ai/mcp`).
internal struct ExaMCPBackend: ReachBackend, Sendable {
    let name = "exa-mcp"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        guard let endpoint = URL(string: "https://mcp.exa.ai/mcp") else {
            throw ReachError(code: .upstreamBroken, message: "Invalid Exa MCP endpoint.")
        }

        let toolName: String
        let arguments: [String: Any]
        if request.action == .read, let url = URL(string: request.target), SearchURLPolicy.validate(url) {
            toolName = "crawling_exa"
            arguments = ["url": url.absoluteString, "maxCharacters": 8000]
        } else {
            toolName = "web_search_exa"
            arguments = ["query": request.target, "numResults": request.limit]
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": arguments
            ]
        ]

        let data = try await ReachHTTPHelper.postJSON(
            url: endpoint,
            payload: payload,
            headers: ["Accept": "application/json, text/event-stream"],
            timeout: timeout,
            session: session,
            provider: "Exa MCP"
        )

        let rawText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let extractedText = Self.extractMCPContentText(from: rawText)

        if extractedText.localizedCaseInsensitiveContains("rate limit") || extractedText.localizedCaseInsensitiveContains("429") {
            throw ReachError(code: .rateLimited, message: "Exa hosted MCP rate limit reached.", hint: "Wait before retrying or use DuckDuckGo/NativeReader.")
        }

        let items = Self.parseExaText(extractedText, channel: request.channel, backend: name, fallbackTarget: request.target, limit: request.limit)
        if items.isEmpty {
            throw ReachError(code: .notFound, message: "Exa MCP returned no results for '\(request.target)'.")
        }
        return items
    }

    static func extractMCPContentText(from raw: String) -> String {
        // Handle SSE `data: {...}` or direct JSON-RPC response.
        let candidates = raw.components(separatedBy: .newlines).compactMap { line -> Data? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data:") {
                let jsonPart = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                return jsonPart.data(using: .utf8)
            }
            if trimmed.hasPrefix("{") {
                return trimmed.data(using: .utf8)
            }
            return nil
        }

        for candidate in candidates.reversed() {
            if let obj = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
               let result = obj["result"] as? [String: Any],
               let content = result["content"] as? [[String: Any]] {
                let texts = content.compactMap { $0["text"] as? String }
                if !texts.isEmpty {
                    return texts.joined(separator: "\n")
                }
            }
        }
        return raw
    }

    static func parseExaText(
        _ text: String,
        channel: ReachChannel,
        backend: String,
        fallbackTarget: String,
        limit: Int
    ) -> [ReachItem] {
        var items: [ReachItem] = []
        var currentTitle: String?
        var currentURL: URL?
        var currentAuthor: String?
        var currentPublished: Date?
        var currentBody: [String] = []

        func flush() {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = currentURL {
                items.append(
                    ReachItem(
                        id: url.absoluteString,
                        title: currentTitle ?? url.host ?? url.absoluteString,
                        url: url,
                        author: currentAuthor,
                        publishedAt: currentPublished,
                        text: body,
                        channel: channel,
                        backend: backend
                    )
                )
            }
            currentTitle = nil
            currentURL = nil
            currentAuthor = nil
            currentPublished = nil
            currentBody = []
        }

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Title:") {
                if currentURL != nil { flush() }
                currentTitle = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("URL:") {
                let urlStr = line.dropFirst("URL:".count).trimmingCharacters(in: .whitespaces)
                currentURL = URL(string: urlStr)
            } else if line.hasPrefix("Author:") {
                currentAuthor = line.dropFirst("Author:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Published:") {
                let dateStr = line.dropFirst("Published:".count).trimmingCharacters(in: .whitespaces)
                currentPublished = ReachHTTPHelper.parseISO8601Date(dateStr)
            } else {
                currentBody.append(line)
            }
        }
        if currentURL != nil {
            flush()
        }

        if items.isEmpty, let url = URL(string: fallbackTarget), SearchURLPolicy.validate(url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(
                ReachItem(
                    id: url.absoluteString,
                    title: url.host ?? url.absoluteString,
                    url: url,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    channel: channel,
                    backend: backend
                )
            )
        }

        return Array(items.prefix(limit))
    }
}
