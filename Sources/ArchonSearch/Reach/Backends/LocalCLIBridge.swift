import Foundation

/// Optional macOS-only bridge to a locally installed `agent-reach` CLI for authenticated browser channels.
internal struct LocalCLIBridge: ReachBackend, Sendable {
    let name = "agent-reach-cli"
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30.0) {
        self.timeout = timeout
    }

    func execute(request: ReachRequest) async throws -> [ReachItem] {
        #if os(macOS)
        guard let executableURL = Self.resolveAgentReachExecutable() else {
            throw ReachError(
                code: .needSetup,
                message: "The `agent-reach` CLI is not installed on this Mac.",
                hint: "Install agent-reach or rely on ArchonSearch's built-in native backends."
            )
        }

        let args = Self.buildArguments(for: request)
        let outputData = try await runProcess(executable: executableURL, arguments: args, timeout: timeout)
        return try Self.parseCLIOutput(outputData, channel: request.channel, action: request.action, backend: name)
        #else
        throw ReachError(
            code: .needSetup,
            message: "Local CLI delegation is only available on macOS.",
            hint: "Use ArchonSearch's native on-device backends on iOS/visionOS."
        )
        #endif
    }

    internal static func buildArguments(for request: ReachRequest) -> [String] {
        if request.action == .read, URL(string: request.target) != nil {
            return ["read", request.target]
        }
        var args = [request.channel.rawValue, request.action.rawValue, request.target]
        if [.search, .tweets, .subreddit, .hot, .node, .hotPosts, .hotStocks, .jobs, .posts].contains(request.action) {
            args.append(contentsOf: ["--limit", String(request.limit)])
        }
        return args
    }

    internal static func parseCLIOutput(
        _ data: Data,
        channel: ReachChannel,
        action: ReachAction,
        backend: String
    ) throws -> [ReachItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReachError(code: .upstreamBroken, message: "agent-reach CLI returned non-JSON output.")
        }
        if let ok = json["ok"] as? Bool, !ok {
            let errDict = json["error"] as? [String: Any]
            let codeStr = (errDict?["code"] as? String) ?? "UPSTREAM_BROKEN"
            let code = ReachErrorCode(rawValue: codeStr) ?? .upstreamBroken
            let msg = (errDict?["message"] as? String) ?? "agent-reach CLI failed."
            let hint = errDict?["hint"] as? String
            throw ReachError(code: code, message: msg, hint: hint)
        }

        guard let rawItems = json["items"] as? [[String: Any]] else {
            return []
        }

        return rawItems.compactMap { entry in
            let urlStr = (entry["url"] as? String) ?? "https://example.com"
            guard let url = URL(string: urlStr) else { return nil }
            let title = (entry["title"] as? String) ?? urlStr
            let author = entry["author"] as? String
            let text = (entry["text"] as? String) ?? title
            let publishedAt = ReachHTTPHelper.parseISO8601Date(entry["published_at"] as? String)
            return ReachItem(
                id: urlStr,
                title: title,
                url: url,
                author: author,
                publishedAt: publishedAt,
                text: text,
                channel: channel,
                backend: backend
            )
        }
    }

    #if os(macOS)
    private static func resolveAgentReachExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/agent-reach",
            "/usr/local/bin/agent-reach",
            "\(NSHomeDirectory())/.local/bin/agent-reach"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    let errStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Process failed."
                    continuation.resume(throwing: ReachError(code: .upstreamBroken, message: errStr))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ReachError(code: .upstreamBroken, message: error.localizedDescription))
            }
        }
    }
    #endif
}
