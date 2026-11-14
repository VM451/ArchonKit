import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Bilibili public API backend (`read`, `search`, `hot`, `subtitle` metadata).
internal struct BilibiliReachBackend: ReachBackend, Sendable {
    let name = "bilibili-api"
    private let session: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15.0) {
        self.session = session
        self.timeout = timeout
    }

    private var headers: [String: String] {
        [
            "Referer": "https://www.bilibili.com/",
            "Origin": "https://www.bilibili.com",
            "Accept": "application/json"
        ]
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        switch request.action {
        case .read, .subtitle:
            let bvid = try await resolveBVID(from: request.target)
            return try await readVideo(bvid: bvid)
        case .hot:
            return try await fetchPopular(limit: request.limit)
        case .search:
            return try await searchVideos(query: request.target, limit: request.limit)
        default:
            throw ReachError(code: .badInput, message: "Bilibili channel does not support action '\(request.action.rawValue)'.")
        }
    }

    private func resolveBVID(from target: String) async throws -> String {
        if let direct = Self.extractBVID(from: target) {
            return direct
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("b23.tv/"),
           let shortURL = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
           SearchURLPolicy.validate(shortURL) {
            let (_, response) = try await ReachHTTPHelper.fetchData(url: shortURL, timeout: timeout, session: session, provider: "Bilibili Shortlink")
            if let finalURL = response.url?.absoluteString, let resolved = Self.extractBVID(from: finalURL) {
                return resolved
            }
        }
        throw ReachError(code: .badInput, message: "Target must be a BV ID or bilibili.com / b23.tv video URL.")
    }

    private func readVideo(bvid: String) async throws -> [ReachItem] {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)") else {
            throw ReachError(code: .badInput, message: "Invalid Bilibili BV ID.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(url: url, headers: headers, timeout: timeout, session: session, provider: "Bilibili API")
        guard let root = json as? [String: Any] else {
            throw ReachError(code: .upstreamBroken, message: "Unexpected Bilibili response.")
        }
        let code = root["code"] as? Int ?? -1
        if code != 0 {
            let msg = (root["message"] as? String) ?? "Bilibili API error \(code)"
            throw ReachError(code: code == -404 ? .notFound : .upstreamBroken, message: msg)
        }
        guard let data = root["data"] as? [String: Any],
              let videoURL = URL(string: "https://www.bilibili.com/video/\(bvid)") else {
            throw ReachError(code: .notFound, message: "Bilibili video \(bvid) not found.")
        }

        let title = (data["title"] as? String) ?? bvid
        let desc = (data["desc"] as? String) ?? ""
        let owner = (data["owner"] as? [String: Any])?["name"] as? String
        let pubdate = (data["pubdate"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let stat = data["stat"] as? [String: Any]
        let views = (stat?["view"] as? Int).map(String.init) ?? ""
        let likes = (stat?["like"] as? Int).map(String.init) ?? ""
        let duration = (data["duration"] as? Int).map(String.init) ?? ""

        return [
            ReachItem(
                id: bvid,
                title: title,
                url: videoURL,
                author: owner,
                publishedAt: pubdate,
                text: desc.isEmpty ? title : desc,
                channel: .bilibili,
                backend: name,
                metadata: [
                    "bvid": bvid,
                    "view_count": views,
                    "like_count": likes,
                    "duration_seconds": duration
                ]
            )
        ]
    }

    private func fetchPopular(limit: Int) async throws -> [ReachItem] {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/popular?ps=\(min(max(limit, 1), 20))&pn=1") else {
            throw ReachError(code: .upstreamBroken, message: "Invalid Bilibili popular URL.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(url: url, headers: headers, timeout: timeout, session: session, provider: "Bilibili Popular API")
        guard let root = json as? [String: Any],
              let data = root["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]] else {
            throw ReachError(code: .upstreamBroken, message: "Unexpected Bilibili popular response.")
        }
        return list.prefix(limit).compactMap { entry in
            guard let bvid = entry["bvid"] as? String,
                  let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else {
                return nil
            }
            let title = (entry["title"] as? String) ?? bvid
            let desc = (entry["desc"] as? String) ?? ""
            let owner = (entry["owner"] as? [String: Any])?["name"] as? String
            let pubdate = (entry["pubdate"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return ReachItem(
                id: bvid,
                title: title,
                url: url,
                author: owner,
                publishedAt: pubdate,
                text: desc.isEmpty ? title : desc,
                channel: .bilibili,
                backend: name,
                metadata: ["bvid": bvid]
            )
        }
    }

    private func searchVideos(query: String, limit: Int) async throws -> [ReachItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReachError(code: .badInput, message: "Bilibili search requires a non-empty query.")
        }
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")
        components?.queryItems = [
            URLQueryItem(name: "search_type", value: "video"),
            URLQueryItem(name: "keyword", value: trimmed),
            URLQueryItem(name: "page_size", value: String(min(max(limit, 1), 20)))
        ]
        guard let url = components?.url else {
            throw ReachError(code: .badInput, message: "Invalid Bilibili search query.")
        }
        let json = try await ReachHTTPHelper.fetchJSON(url: url, headers: headers, timeout: timeout, session: session, provider: "Bilibili Search API")
        guard let root = json as? [String: Any],
              let data = root["data"] as? [String: Any],
              let results = data["result"] as? [[String: Any]] else {
            throw ReachError(code: .upstreamBroken, message: "Bilibili search returned an unexpected payload.")
        }
        return results.prefix(limit).compactMap { entry in
            guard let bvid = entry["bvid"] as? String,
                  let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else {
                return nil
            }
            let rawTitle = (entry["title"] as? String) ?? bvid
            let title = rawTitle.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let desc = (entry["description"] as? String) ?? ""
            let author = entry["author"] as? String
            let pubdate = (entry["pubdate"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return ReachItem(
                id: bvid,
                title: title,
                url: url,
                author: author,
                publishedAt: pubdate,
                text: desc.isEmpty ? title : desc,
                channel: .bilibili,
                backend: name,
                metadata: ["bvid": bvid]
            )
        }
    }

    internal static func extractBVID(from target: String) -> String? {
        let pattern = #"BV[0-9A-Za-z]{10}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)),
              let range = Range(match.range, in: target) else {
            return nil
        }
        return String(target[range])
    }
}
