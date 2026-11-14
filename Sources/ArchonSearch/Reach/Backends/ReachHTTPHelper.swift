import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArchonCore

/// Shared, bounded HTTP and anti-bot detection helpers for Agent Reach backends.
internal enum ReachHTTPHelper {

    static func fetchData(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15.0,
        session: URLSession? = nil,
        provider: String = "AgentReach"
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard SearchURLPolicy.validate(url) else {
            throw ReachError(code: .badInput, message: "URL must be a public HTTP(S) URL: \(url.absoluteString)")
        }
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: provider)
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (key, value) in StealthHeaders.standardHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let activeSession = session ?? SearchURLPolicy.makeSession()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await activeSession.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ReachError(code: .timeout, message: "Request timed out for \(url.absoluteString)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReachError(code: .upstreamBroken, message: error.localizedDescription)
        }

        guard data.count <= SearchURLPolicy.maxResponseBytes else {
            throw ReachError(code: .upstreamBroken, message: "Response exceeded 8 MiB safety limit.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReachError(code: .upstreamBroken, message: "Invalid non-HTTP response.")
        }
        if let finalURL = http.url, !SearchURLPolicy.validate(finalURL) {
            throw ReachError(code: .badInput, message: "Redirected URL is not a permitted public HTTP(S) target.")
        }

        try validateStatusCode(http.statusCode, url: url, response: http)
        return (data, http)
    }

    static func fetchString(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15.0,
        session: URLSession? = nil,
        provider: String = "AgentReach"
    ) async throws -> String {
        let (data, _) = try await fetchData(
            url: url,
            headers: headers,
            timeout: timeout,
            session: session,
            provider: provider
        )
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func fetchJSON(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15.0,
        session: URLSession? = nil,
        provider: String = "AgentReach"
    ) async throws -> Any {
        var jsonHeaders = headers
        if jsonHeaders["Accept"] == nil {
            jsonHeaders["Accept"] = "application/json"
        }
        let (data, _) = try await fetchData(
            url: url,
            headers: jsonHeaders,
            timeout: timeout,
            session: session,
            provider: provider
        )
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ReachError(code: .upstreamBroken, message: "Invalid JSON payload from \(url.host ?? "upstream").")
        }
    }

    static func postJSON(
        url: URL,
        payload: [String: Any],
        headers: [String: String] = [:],
        timeout: TimeInterval = 15.0,
        session: URLSession? = nil,
        provider: String = "AgentReach"
    ) async throws -> Data {
        guard SearchURLPolicy.validate(url) else {
            throw ReachError(code: .badInput, message: "URL must be a public HTTP(S) URL: \(url.absoluteString)")
        }
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: provider)
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let activeSession = session ?? SearchURLPolicy.makeSession()
        let (data, response) = try await activeSession.data(for: request)
        guard data.count <= SearchURLPolicy.maxResponseBytes else {
            throw ReachError(code: .upstreamBroken, message: "Response exceeded 8 MiB safety limit.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReachError(code: .upstreamBroken, message: "Invalid non-HTTP response.")
        }
        try validateStatusCode(http.statusCode, url: url, response: http)
        return data
    }

    static func validateStatusCode(_ statusCode: Int, url: URL, response: HTTPURLResponse) throws {
        switch statusCode {
        case 200...299:
            return
        case 404, 410:
            throw ReachError(code: .notFound, message: "Content not found at \(url.absoluteString) (HTTP \(statusCode)).")
        case 401:
            throw ReachError(
                code: .needLogin,
                message: "Authentication required for \(url.host ?? url.absoluteString) (HTTP 401).",
                hint: "Sign in to \(url.host ?? "this platform") in your browser or provide credentials."
            )
        case 403:
            throw ReachError(
                code: .platformBlocked,
                message: "Access denied by \(url.host ?? url.absoluteString) (HTTP 403).",
                hint: "The platform blocked anonymous access or requires verification/login."
            )
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ReachError(
                code: .rateLimited,
                message: "Rate limited by \(url.host ?? url.absoluteString) (HTTP 429).",
                hint: "Wait before retrying.",
                retryAfterSeconds: retryAfter
            )
        case 412:
            throw ReachError(
                code: .platformBlocked,
                message: "Platform risk control triggered for \(url.host ?? url.absoluteString) (HTTP 412).",
                hint: "Retry later or use an authenticated session."
            )
        default:
            throw ReachError(code: .upstreamBroken, message: "Upstream returned HTTP \(statusCode) for \(url.absoluteString).")
        }
    }

    /// Detects high-confidence anti-bot challenge pages or login walls.
    static func detectChallengeOrLoginWall(in text: String, channel: ReachChannel) -> ReachError? {
        let sample = String(text.prefix(4096)).lowercased()

        let jinaCaptcha = sample.contains("warning:") && sample.contains("requiring captcha")
        let cfChallenge = sample.contains("title: just a moment...")
            || sample.contains("## performing security verification")
            || (sample.contains("attention required! | cloudflare") && (sample.contains("ray id") || sample.contains("/cdn-cgi/challenge-platform/")))

        if jinaCaptcha || cfChallenge {
            return ReachError(
                code: .platformBlocked,
                message: "\(channel.displayName) returned a security verification / CAPTCHA challenge.",
                hint: "Resolve the verification on the official page or retry later."
            )
        }

        if channel == .linkedin && (sample.contains("/authwall") || sample.contains("sign in to view") || sample.contains("join linkedin")) && text.count < 1500 {
            return ReachError(
                code: .needLogin,
                message: "LinkedIn redirected to an authentication wall.",
                hint: "Ask the user to sign in to linkedin.com or try a public-web search."
            )
        }

        if channel == .instagram && (sample.contains("login • instagram") || sample.contains("log in to see photos and videos")) && text.count < 1200 {
            return ReachError(
                code: .needLogin,
                message: "Instagram requires login to view this page.",
                hint: "Ask the user to log in to instagram.com in their browser."
            )
        }

        if channel == .facebook && (sample.contains("you must log in to continue") || sample.contains("log into facebook")) && text.count < 1200 {
            return ReachError(
                code: .needLogin,
                message: "Facebook requires login to view this page.",
                hint: "Ask the user to log in to facebook.com in their browser."
            )
        }

        return nil
    }

    static func parseISO8601Date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
