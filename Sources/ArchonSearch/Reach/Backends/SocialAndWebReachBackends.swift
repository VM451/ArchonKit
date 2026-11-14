import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Twitter/X backend using public syndication/oEmbed endpoints before falling back to Jina/public-web.
internal struct TwitterReachBackend: ReachBackend, Sendable {
    let name = "twitter-public"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .read, .thread:
            return try await readTweet(target: request.target)
        default:
            throw ReachError(
                code: .needLogin,
                message: "Twitter/X action '\(request.action.rawValue)' requires browser session or public-web fallback."
            )
        }
    }

    private func readTweet(target: String) async throws -> [ReachItem] {
        guard let tweetURL = Self.normalizeTweetURL(target),
              let tweetID = Self.extractTweetID(from: tweetURL.absoluteString) else {
            throw ReachError(code: .badInput, message: "Target must be an x.com or twitter.com status URL.")
        }

        // 1. Try syndication tweet-result JSON (zero-key, returns full text + author + metrics).
        if let syndicationURL = URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(tweetID)&lang=en&token=archon"),
           let json = try? await ReachHTTPHelper.fetchJSON(url: syndicationURL, timeout: timeout, session: session, provider: "Twitter Syndication") as? [String: Any],
           let text = json["text"] as? String, !text.isEmpty {
            let user = json["user"] as? [String: Any]
            let screenName = user?["screen_name"] as? String
            let displayName = user?["name"] as? String
            let author = [displayName, screenName.map { "@\($0)" }].compactMap { $0 }.joined(separator: " ")
            let createdAt = ReachHTTPHelper.parseISO8601Date(json["created_at"] as? String)
            let favCount = (json["favorite_count"] as? Int).map(String.init) ?? ""
            let replyCount = (json["conversation_count"] as? Int).map(String.init) ?? ""

            return [
                ReachItem(
                    id: tweetID,
                    title: author.isEmpty ? "Tweet \(tweetID)" : "Post by \(author)",
                    url: tweetURL,
                    author: author.isEmpty ? nil : author,
                    publishedAt: createdAt,
                    text: text,
                    channel: .twitter,
                    backend: name,
                    metadata: [
                        "tweet_id": tweetID,
                        "like_count": favCount,
                        "reply_count": replyCount
                    ]
                )
            ]
        }

        // 2. Fallback to public oEmbed endpoint.
        var oembedComponents = URLComponents(string: "https://publish.twitter.com/oembed")
        oembedComponents?.queryItems = [URLQueryItem(name: "url", value: tweetURL.absoluteString)]
        if let oembedURL = oembedComponents?.url,
           let oembed = try? await ReachHTTPHelper.fetchJSON(url: oembedURL, timeout: timeout, session: session, provider: "Twitter oEmbed") as? [String: Any],
           let html = oembed["html"] as? String {
            let cleanText = HTMLContentExtractor.extractText(from: html)
            let author = oembed["author_name"] as? String
            return [
                ReachItem(
                    id: tweetID,
                    title: author.map { "Post by \($0)" } ?? "Tweet \(tweetID)",
                    url: tweetURL,
                    author: author,
                    text: cleanText,
                    channel: .twitter,
                    backend: "twitter-oembed",
                    metadata: ["tweet_id": tweetID]
                )
            ]
        }

        throw ReachError(code: .upstreamBroken, message: "Could not read tweet \(tweetID) via public endpoints.")
    }

    internal static func normalizeTweetURL(_ target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              let host = url.host?.lowercased(),
              host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com") else {
            return nil
        }
        return url
    }

    internal static func extractTweetID(from urlString: String) -> String? {
        let pattern = #"/status/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let range = Range(match.range(at: 1), in: urlString) else {
            return nil
        }
        return String(urlString[range])
    }
}

/// Native Xueqiu (雪球) backend for stock quotes and public community lookup.
internal struct XueqiuReachBackend: ReachBackend, Sendable {
    let name = "xueqiu-public"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .quote:
            return try await fetchQuote(symbol: request.target)
        default:
            throw ReachError(
                code: .needLogin,
                message: "Xueqiu action '\(request.action.rawValue)' requires a logged-in session or public-web fallback."
            )
        }
    }

    private func fetchQuote(symbol rawSymbol: String) async throws -> [ReachItem] {
        let symbol = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty, symbol.range(of: #"^[A-Z0-9.]{1,16}$"#, options: .regularExpression) != nil else {
            throw ReachError(code: .badInput, message: "Invalid stock symbol '\(rawSymbol)'.")
        }

        // Warm up session cookie from xueqiu.com when using an ephemeral/shared session.
        let activeSession = session ?? URLSession(configuration: .ephemeral)
        if let homeURL = URL(string: "https://xueqiu.com/") {
            _ = try? await ReachHTTPHelper.fetchData(url: homeURL, timeout: timeout, session: activeSession, provider: "Xueqiu Warmup")
        }

        guard let quoteURL = URL(string: "https://stock.xueqiu.com/v5/stock/quote.json?symbol=\(symbol)&extend=detail") else {
            throw ReachError(code: .badInput, message: "Invalid Xueqiu quote URL.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(
            url: quoteURL,
            headers: ["Referer": "https://xueqiu.com/"],
            timeout: timeout,
            session: activeSession,
            provider: "Xueqiu Quote API"
        )
        guard let root = json as? [String: Any],
              let data = root["data"] as? [String: Any],
              let quote = data["quote"] as? [String: Any] else {
            throw ReachError(code: .notFound, message: "No Xueqiu quote found for \(symbol).")
        }

        let nameStr = (quote["name"] as? String) ?? symbol
        let current = quote["current"].map { "\($0)" } ?? "N/A"
        let percent = quote["percent"].map { "\($0)%" } ?? "N/A"
        let chg = quote["chg"].map { "\($0)" } ?? "N/A"
        let marketCap = quote["market_capital"].map { "\($0)" } ?? ""
        let pageURL = URL(string: "https://xueqiu.com/S/\(symbol)") ?? quoteURL

        return [
            ReachItem(
                id: symbol,
                title: "\(nameStr) (\(symbol))",
                url: pageURL,
                text: "Price: \(current) | Change: \(chg) (\(percent))" + (marketCap.isEmpty ? "" : " | Market Cap: \(marketCap)"),
                channel: .xueqiu,
                backend: name,
                metadata: [
                    "symbol": symbol,
                    "current": current,
                    "percent": percent
                ]
            )
        ]
    }
}

/// Native Xiaoyuzhou (小宇宙) podcast backend: extracts episode metadata/audio URL and optionally transcribes via Groq Whisper.
internal struct XiaoyuzhouReachBackend: ReachBackend, Sendable {
    let name = "xiaoyuzhou-native"
    private let session: URLSession?
    private let timeout: TimeInterval
    private let groqAPIKey: String?

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0, groqAPIKey: String? = nil) {
        self.session = session
        self.timeout = timeout
        self.groqAPIKey = groqAPIKey
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        guard request.action == .read || request.action == .transcribe else {
            throw ReachError(code: .badInput, message: "Xiaoyuzhou native backend supports 'read' and 'transcribe'.")
        }
        guard let episodeURL = URL(string: request.target.trimmingCharacters(in: .whitespacesAndNewlines)),
              SearchURLPolicy.validate(episodeURL),
              ReachChannel.channel(for: episodeURL) == .xiaoyuzhou else {
            throw ReachError(code: .badInput, message: "Target must be a xiaoyuzhoufm.com episode URL.")
        }

        let html = try await ReachHTTPHelper.fetchString(
            url: episodeURL,
            timeout: timeout,
            session: session,
            provider: "Xiaoyuzhou Episode"
        )

        let title = Self.extractMetaContent(property: "og:title", in: html) ?? HTMLContentExtractor.extractTitle(from: html)
        let description = Self.extractMetaContent(property: "og:description", in: html) ?? ""
        let audioURLString = Self.extractMetaContent(property: "og:audio", in: html)
            ?? Self.extractAudioURLFromNextData(in: html)

        if request.action == .transcribe {
            guard let groqAPIKey, !groqAPIKey.isEmpty else {
                throw ReachError(
                    code: .needSetup,
                    message: "Xiaoyuzhou transcription requires a Groq API key.",
                    hint: "Set ReachConfiguration.groqAPIKey (free at https://console.groq.com)."
                )
            }
            guard let audioStr = audioURLString, let audioURL = URL(string: audioStr), SearchURLPolicy.validate(audioURL) else {
                throw ReachError(code: .notFound, message: "Could not locate podcast audio stream URL on episode page.")
            }
            let transcript = try await transcribeAudioViaGroq(audioURL: audioURL, apiKey: groqAPIKey)
            let combined = [description.isEmpty ? nil : description, "## Transcript\n\(transcript)"].compactMap { $0 }.joined(separator: "\n\n")
            return [
                ReachItem(
                    id: episodeURL.absoluteString,
                    title: title.isEmpty ? "Xiaoyuzhou Episode" : title,
                    url: episodeURL,
                    text: combined,
                    channel: .xiaoyuzhou,
                    backend: "groq-whisper",
                    metadata: ["audio_url": audioStr]
                )
            ]
        }

        var metadata: [String: String] = [:]
        if let audioURLString { metadata["audio_url"] = audioURLString }
        let body = description.isEmpty ? HTMLContentExtractor.extractText(from: html) : description

        return [
            ReachItem(
                id: episodeURL.absoluteString,
                title: title.isEmpty ? "Xiaoyuzhou Episode" : title,
                url: episodeURL,
                text: body,
                channel: .xiaoyuzhou,
                backend: name,
                metadata: metadata
            )
        ]
    }

    private func transcribeAudioViaGroq(audioURL: URL, apiKey: String) async throws -> String {
        let (audioData, _) = try await ReachHTTPHelper.fetchData(
            url: audioURL,
            timeout: max(timeout, 60.0),
            session: session,
            provider: "Xiaoyuzhou Audio"
        )
        guard let groqURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else {
            throw ReachError(code: .upstreamBroken, message: "Invalid Groq transcription URL.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        appendField("model", "whisper-large-v3-turbo")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"episode.m4a\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: groqURL)
        req.httpMethod = "POST"
        req.timeoutInterval = max(timeout, 120.0)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let activeSession = session ?? SearchURLPolicy.makeSession()
        let (data, response) = try await activeSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ReachError(code: .upstreamBroken, message: "Invalid Groq response.")
        }
        try ReachHTTPHelper.validateStatusCode(http.statusCode, url: groqURL, response: http)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw ReachError(code: .upstreamBroken, message: "Could not parse Groq Whisper response.")
        }
        return text
    }

    internal static func extractMetaContent(property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return HTMLContentExtractor.decodeBasicHTMLEntities(String(html[range]))
    }

    private static func extractAudioURLFromNextData(in html: String) -> String? {
        let pattern = #"https?://[^\s"'<>]+\.(?:m4a|mp3)(?:\?[^\s"'<>]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else {
            return nil
        }
        return String(html[range])
    }
}

/// Public-web fallback backend using `DiscoveryEngine` (DuckDuckGo scoped search) and `NativeReader`.
internal struct PublicWebReachBackend: ReachBackend, Sendable {
    let name = "public-web"
    private let discoveryEngine: DiscoveryEngine
    private let nativeReader: NativeReader

    init(discoveryEngine: DiscoveryEngine = DiscoveryEngine(), nativeReader: NativeReader = NativeReader()) {
        self.discoveryEngine = discoveryEngine
        self.nativeReader = nativeReader
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .read, .comments, .thread, .profile:
            if let url = URL(string: request.target), SearchURLPolicy.validate(url) {
                let doc = try await nativeReader.read(url: url)
                if let blocked = ReachHTTPHelper.detectChallengeOrLoginWall(in: doc.text, channel: request.channel) {
                    throw blocked
                }
                let text = doc.markdown.isEmpty ? doc.text : doc.markdown
                return [
                    ReachItem(
                        id: doc.url.absoluteString,
                        title: doc.title.isEmpty ? (doc.url.host ?? doc.url.absoluteString) : doc.title,
                        url: doc.url,
                        publishedAt: doc.publishedAt,
                        text: text,
                        channel: request.channel,
                        backend: name,
                        metadata: doc.metadata
                    )
                ]
            }
            return try await searchPublicWeb(request: request)

        default:
            return try await searchPublicWeb(request: request)
        }
    }

    private func searchPublicWeb(request: ReachRequest) async throws -> [ReachItem] {
        let scopedQuery = Self.scopedQuery(for: request.channel, action: request.action, target: request.target)
        let urls = try await discoveryEngine.search(query: scopedQuery, source: .duckDuckGo)
        let targetURLs = Array(urls.prefix(request.limit))
        guard !targetURLs.isEmpty else {
            throw ReachError(code: .notFound, message: "No public web results found for '\(request.target)' on \(request.channel.displayName).")
        }

        var items: [ReachItem] = []
        await withTaskGroup(of: ReachItem?.self) { group in
            for url in targetURLs {
                group.addTask {
                    if let (title, text, _) = try? await HTMLContentExtractor.fetchStaticPage(url: url, timeout: 6.0) {
                        if ReachHTTPHelper.detectChallengeOrLoginWall(in: text, channel: request.channel) == nil {
                            return ReachItem(
                                id: url.absoluteString,
                                title: title.isEmpty ? url.absoluteString : title,
                                url: url,
                                text: String(text.prefix(1200)),
                                channel: request.channel,
                                backend: self.name
                            )
                        }
                    }
                    return ReachItem(
                        id: url.absoluteString,
                        title: url.host ?? url.absoluteString,
                        url: url,
                        text: url.absoluteString,
                        channel: request.channel,
                        backend: self.name
                    )
                }
            }
            for await item in group {
                if let item { items.append(item) }
            }
        }
        return items
    }

    internal static func scopedQuery(for channel: ReachChannel, action: ReachAction, target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard channel != .web, !channel.domains.isEmpty else {
            return trimmed
        }
        let siteScope = channel.domains.map { "site:\($0)" }.joined(separator: " OR ")
        let prefix = action == .jobs ? "jobs " : ""
        return trimmed.isEmpty ? siteScope : "(\(siteScope)) \(prefix)\(trimmed)"
    }
}
