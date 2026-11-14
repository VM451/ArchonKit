import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native YouTube backend: extracts video metadata, descriptions, and caption transcripts without external binaries.
internal struct YouTubeReachBackend: ReachBackend, Sendable {
    let name = "youtube-native"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .read, .subtitle:
            return try await readVideo(target: request.target, preferredLanguage: request.language, includeTranscript: true)
        case .search:
            return try await searchVideos(query: request.target, limit: request.limit)
        case .transcribe:
            // Try native captions first; if none exist, caller can fall back to Groq/CLI.
            let items = try await readVideo(target: request.target, preferredLanguage: request.language, includeTranscript: true)
            if let first = items.first, first.metadata["has_transcript"] == "true" {
                return items
            }
            throw ReachError(
                code: .needSetup,
                message: "No native YouTube captions available for transcription.",
                hint: "Configure a Groq API key or install yt-dlp on macOS for audio transcription."
            )
        default:
            throw ReachError(code: .badInput, message: "YouTube channel does not support action '\(request.action.rawValue)'.")
        }
    }

    private func readVideo(target: String, preferredLanguage: String?, includeTranscript: Bool) async throws -> [ReachItem] {
        guard let videoID = Self.extractVideoID(from: target) else {
            throw ReachError(code: .badInput, message: "Target must be a YouTube video URL or 11-character video ID.")
        }
        guard let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            throw ReachError(code: .badInput, message: "Invalid YouTube URL.")
        }

        let html = try await ReachHTTPHelper.fetchString(
            url: watchURL,
            headers: ["Accept-Language": "en-US,en;q=0.9"],
            timeout: timeout,
            session: session,
            provider: "YouTube Watch Page"
        )

        if let playerResponse = Self.extractPlayerResponse(from: html),
           let videoDetails = playerResponse["videoDetails"] as? [String: Any] {
            let title = (videoDetails["title"] as? String) ?? "YouTube Video \(videoID)"
            let author = videoDetails["author"] as? String
            let description = (videoDetails["shortDescription"] as? String) ?? ""
            let duration = videoDetails["lengthSeconds"] as? String ?? ""
            let views = videoDetails["viewCount"] as? String ?? ""

            var transcript = ""
            if includeTranscript,
               let captions = playerResponse["captions"] as? [String: Any],
               let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
               let tracks = renderer["captionTracks"] as? [[String: Any]],
               let trackURL = Self.selectCaptionTrackURL(from: tracks, preferredLanguage: preferredLanguage) {
                transcript = (try? await fetchTranscript(from: trackURL)) ?? ""
            }

            var sections: [String] = []
            if !description.isEmpty {
                sections.append(description)
            }
            if !transcript.isEmpty {
                sections.append("## Transcript\n\(transcript)")
            }
            let body = sections.isEmpty ? title : sections.joined(separator: "\n\n")

            return [
                ReachItem(
                    id: videoID,
                    title: title,
                    url: watchURL,
                    author: author,
                    publishedAt: nil,
                    text: body,
                    channel: .youtube,
                    backend: name,
                    metadata: [
                        "video_id": videoID,
                        "duration_seconds": duration,
                        "view_count": views,
                        "has_transcript": transcript.isEmpty ? "false" : "true"
                    ]
                )
            ]
        }

        // oEmbed fallback when watch page player JSON is unavailable.
        if let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(watchURL.absoluteString)&format=json"),
           let oembed = try? await ReachHTTPHelper.fetchJSON(url: oembedURL, timeout: timeout, session: session, provider: "YouTube oEmbed") as? [String: Any],
           let title = oembed["title"] as? String {
            return [
                ReachItem(
                    id: videoID,
                    title: title,
                    url: watchURL,
                    author: oembed["author_name"] as? String,
                    text: title,
                    channel: .youtube,
                    backend: "youtube-oembed",
                    metadata: ["video_id": videoID, "has_transcript": "false"]
                )
            ]
        }

        throw ReachError(code: .upstreamBroken, message: "Could not extract YouTube video details for \(videoID).")
    }

    private func fetchTranscript(from baseURLString: String) async throws -> String {
        guard var components = URLComponents(string: baseURLString) else { return "" }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "fmt" }
        queryItems.append(URLQueryItem(name: "fmt", value: "json3"))
        components.queryItems = queryItems
        guard let url = components.url else { return "" }

        let (data, _) = try await ReachHTTPHelper.fetchData(
            url: url,
            timeout: timeout,
            session: session,
            provider: "YouTube Transcript"
        )
        if let jsonText = Self.parseJSON3Transcript(data), !jsonText.isEmpty {
            return jsonText
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return Self.parseXMLTranscript(raw)
    }

    private func searchVideos(query: String, limit: Int) async throws -> [ReachItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReachError(code: .badInput, message: "YouTube search requires a non-empty query.")
        }
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: trimmed)]
        guard let url = components?.url else {
            throw ReachError(code: .badInput, message: "Invalid YouTube search query.")
        }

        let html = try await ReachHTTPHelper.fetchString(
            url: url,
            headers: ["Accept-Language": "en-US,en;q=0.9"],
            timeout: timeout,
            session: session,
            provider: "YouTube Search"
        )
        let items = Self.parseSearchResultsHTML(html, limit: limit, backend: name)
        if items.isEmpty {
            throw ReachError(code: .notFound, message: "No YouTube results parsed for '\(trimmed)'.")
        }
        return items
    }

    internal static func extractVideoID(from target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              let host = url.host?.lowercased() else {
            return nil
        }
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let candidate = url.pathComponents.dropFirst().first ?? ""
            return candidate.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? candidate : nil
        }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
               v.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
                return v
            }
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
                let candidate = parts[1]
                return candidate.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? candidate : nil
            }
        }
        return nil
    }

    internal static func extractPlayerResponse(from html: String) -> [String: Any]? {
        let markers = ["ytInitialPlayerResponse = ", "var ytInitialPlayerResponse = "]
        for marker in markers {
            if let json = extractBalancedJSON(after: marker, in: html) {
                return json
            }
        }
        return nil
    }

    internal static func selectCaptionTrackURL(from tracks: [[String: Any]], preferredLanguage: String?) -> String? {
        if let preferredLanguage = preferredLanguage?.lowercased(), !preferredLanguage.isEmpty {
            if let match = tracks.first(where: { ($0["languageCode"] as? String)?.lowercased() == preferredLanguage }),
               let baseUrl = match["baseUrl"] as? String {
                return baseUrl
            }
        }
        if let en = tracks.first(where: { ($0["languageCode"] as? String)?.lowercased().hasPrefix("en") == true }),
           let baseUrl = en["baseUrl"] as? String {
            return baseUrl
        }
        return tracks.first?["baseUrl"] as? String
    }

    internal static func parseJSON3Transcript(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            return nil
        }
        var lines: [String] = []
        for event in events {
            guard let segs = event["segs"] as? [[String: Any]] else { continue }
            let text = segs.compactMap { $0["utf8"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != "\n" {
                lines.append(text)
            }
        }
        return lines.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    internal static func parseXMLTranscript(_ xml: String) -> String {
        let stripped = xml
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return HTMLContentExtractor.decodeBasicHTMLEntities(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSearchResultsHTML(_ html: String, limit: Int, backend: String) -> [ReachItem] {
        guard let initialData = extractBalancedJSON(after: "var ytInitialData = ", in: html)
                ?? extractBalancedJSON(after: "ytInitialData = ", in: html) else {
            return []
        }
        var items: [ReachItem] = []
        collectVideoRenderers(in: initialData, into: &items, limit: limit, backend: backend)
        return items
    }

    private static func collectVideoRenderers(in node: Any, into items: inout [ReachItem], limit: Int, backend: String) {
        guard items.count < limit else { return }
        if let dict = node as? [String: Any] {
            if let renderer = dict["videoRenderer"] as? [String: Any],
               let videoID = renderer["videoId"] as? String,
               let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") {
                let titleRuns = ((renderer["title"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
                let title = titleRuns.compactMap { $0["text"] as? String }.joined()
                let ownerRuns = ((renderer["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
                let author = ownerRuns.compactMap { $0["text"] as? String }.first
                let snippetRuns = ((renderer["detailedMetadataSnippets"] as? [[String: Any]])?.first?["snippetText"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                let snippet = snippetRuns.compactMap { $0["text"] as? String }.joined()
                let lengthText = ((renderer["lengthText"] as? [String: Any])?["simpleText"] as? String) ?? ""

                items.append(
                    ReachItem(
                        id: videoID,
                        title: title.isEmpty ? "YouTube \(videoID)" : title,
                        url: url,
                        author: author,
                        text: snippet.isEmpty ? title : snippet,
                        channel: .youtube,
                        backend: backend,
                        metadata: [
                            "video_id": videoID,
                            "duration": lengthText
                        ]
                    )
                )
                return
            }
            for value in dict.values {
                collectVideoRenderers(in: value, into: &items, limit: limit, backend: backend)
                if items.count >= limit { return }
            }
        } else if let array = node as? [Any] {
            for element in array {
                collectVideoRenderers(in: element, into: &items, limit: limit, backend: backend)
                if items.count >= limit { return }
            }
        }
    }

    private static func extractBalancedJSON(after marker: String, in text: String) -> [String: Any]? {
        guard let markerRange = text.range(of: marker) else { return nil }
        var index = markerRange.upperBound
        while index < text.endIndex && text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "{" else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var cursor = index
        while cursor < text.endIndex {
            let ch = text[cursor]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let jsonSlice = String(text[index...cursor])
                        if let data = jsonSlice.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            return obj
                        }
                        return nil
                    }
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}
