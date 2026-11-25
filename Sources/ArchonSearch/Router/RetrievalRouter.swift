import Foundation
import ArchonCore

/// Actor that decides the extraction strategy for a webpage between Crawl4AI and NativeReader.
public actor RetrievalRouter: Sendable {
    private let crawlClient: Crawl4AIClient?
    private let nativeReader: NativeReader

    public init(
        crawlClient: Crawl4AIClient? = nil,
        nativeReader: NativeReader = NativeReader()
    ) {
        self.crawlClient = crawlClient
        self.nativeReader = nativeReader
    }

    public init(configuration: ArchonSearchConfiguration) {
        if let crawlerURL = configuration.crawler.crawl4aiURL {
            self.crawlClient = Crawl4AIClient(endpoint: crawlerURL)
        } else {
            self.crawlClient = nil
        }
        self.nativeReader = NativeReader(timeout: configuration.timeouts.fetchTimeout)
    }

    /// Reads a webpage using the configured routing mode and options.
    public func read(url: URL, options: ReaderOptions = ReaderOptions()) async throws -> WebDocument {
        guard SearchURLPolicy.validate(url) else {
            throw SearchError.invalidURL(urlString: url.absoluteString)
        }
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "RetrievalRouter")
        try Task.checkCancellation()

        if let timeout = options.timeout, timeout > 0 {
            return try await withThrowingTaskGroup(of: WebDocument.self) { group in
                group.addTask { [self] in
                    try await self.dispatchRead(url: url, options: options)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw SearchError.timeout(reason: "RetrievalRouter timed out after \(timeout)s for \(url.absoluteString)")
                }
                guard let document = try await group.next() else {
                    throw SearchError.timeout(reason: "RetrievalRouter timed out for \(url.absoluteString)")
                }
                group.cancelAll()
                return document
            }
        } else {
            return try await dispatchRead(url: url, options: options)
        }
    }

    /// Returns a health status report for Crawl4AI and NativeReader backends.
    public func healthReport() async -> RetrievalHealthReport {
        let isCrawlerAvailable: Bool
        if let crawlClient {
            isCrawlerAvailable = await crawlClient.checkHealth()
        } else {
            isCrawlerAvailable = false
        }
        let crawlerEndpoint = crawlClient?.endpoint
        return RetrievalHealthReport(
            isCrawlerAvailable: isCrawlerAvailable,
            isNativeAvailable: true,
            crawlerEndpoint: crawlerEndpoint,
            lastCheckedAt: Date()
        )
    }

    private func dispatchRead(url: URL, options: ReaderOptions) async throws -> WebDocument {
        if options.useChannelReach && options.mode != .crawlerOnly {
            let channel = ReachChannel.channel(for: url)
            if channel != .web {
                let reachClient = AgentReachClient(
                    configuration: ReachConfiguration(
                        timeout: options.timeout ?? 15.0,
                        enableJinaReaderFallback: true,
                        enableExaMCPFallback: false,
                        enableLocalCLIFallback: false
                    )
                )
                let result = await reachClient.read(url: url)
                if result.ok, let first = result.items.first, !first.text.isEmpty {
                    var text = first.text
                    if !first.comments.isEmpty {
                        let commentsText = first.comments.prefix(15).map { comment in
                            let author = comment.author ?? "anonymous"
                            return "- \(author): \(comment.text)"
                        }.joined(separator: "\n")
                        text += "\n\n## Comments\n\(commentsText)"
                    }
                    var metadata = first.metadata
                    metadata["reach_channel"] = result.channel.rawValue
                    if let backend = result.backend {
                        metadata["reach_backend"] = backend
                    }
                    return WebDocument(
                        url: first.url,
                        title: first.title,
                        text: text,
                        markdown: text,
                        publishedAt: first.publishedAt,
                        metadata: metadata
                    )
                }
            }
        }
        return try await dispatchRead(url: url, mode: options.mode)
    }

    private func dispatchRead(url: URL, mode: ArchonSearchConfiguration.RoutingMode) async throws -> WebDocument {
        switch mode {
        case .automatic:
            if let crawlClient, await crawlClient.checkHealth() {
                do {
                    return try await crawlClient.crawl(url: url)
                } catch {
                    return try await nativeReader.read(url: url)
                }
            } else {
                return try await nativeReader.read(url: url)
            }

        case .preferCrawler:
            if let crawlClient {
                do {
                    return try await crawlClient.crawl(url: url)
                } catch {
                    return try await nativeReader.read(url: url)
                }
            } else {
                return try await nativeReader.read(url: url)
            }

        case .preferNative:
            do {
                return try await nativeReader.read(url: url)
            } catch {
                if let crawlClient {
                    return try await crawlClient.crawl(url: url)
                }
                throw error
            }

        case .nativeOnly:
            return try await nativeReader.read(url: url)

        case .crawlerOnly:
            guard let crawlClient else {
                throw SearchError.crawl4ai(reason: "Crawl4AI client is not configured for crawlerOnly mode.")
            }
            return try await crawlClient.crawl(url: url)
        }
    }
}
