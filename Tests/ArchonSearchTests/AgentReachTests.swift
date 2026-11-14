import Foundation
import Testing
@testable import ArchonSearch

@Suite("Agent Reach Capabilities Tests")
struct AgentReachTests {

    @Test("ReachChannel covers all 14 Agent Reach channels and bridges SocialPlatform")
    func channelInventoryAndBridging() {
        let expected: Set<ReachChannel> = [
            .github, .youtube, .twitter, .reddit, .facebook, .instagram,
            .bilibili, .xiaohongshu, .linkedin, .boss, .v2ex, .xueqiu, .xiaoyuzhou, .web
        ]
        #expect(Set(ReachChannel.allCases) == expected)
        #expect(ReachChannel.allCases.count == 14)

        for platform in SocialPlatform.allCases {
            let channel = ReachChannel(socialPlatform: platform)
            #expect(channel.socialPlatform == platform)
        }
        #expect(ReachChannel.boss.socialPlatform == nil)
        #expect(ReachChannel.xueqiu.socialPlatform == nil)
        #expect(ReachChannel.xiaoyuzhou.socialPlatform == nil)
        #expect(ReachChannel.web.socialPlatform == nil)
    }

    @Test("ReachChannel resolves aliases and URLs accurately")
    func channelIdentifierAndURLResolution() {
        #expect(ReachChannel(identifier: "gh") == .github)
        #expect(ReachChannel(identifier: "yt") == .youtube)
        #expect(ReachChannel(identifier: "x") == .twitter)
        #expect(ReachChannel(identifier: "xhs") == .xiaohongshu)
        #expect(ReachChannel(identifier: "bosszhipin") == .boss)
        #expect(ReachChannel(identifier: "雪球") == .xueqiu)
        #expect(ReachChannel(identifier: "小宇宙") == .xiaoyuzhou)
        #expect(ReachChannel(identifier: "unknown") == nil)

        #expect(ReachChannel.channel(for: URL(string: "https://github.com/apple/swift")!) == .github)
        #expect(ReachChannel.channel(for: URL(string: "https://youtu.be/dQw4w9WgXcQ")!) == .youtube)
        #expect(ReachChannel.channel(for: URL(string: "https://x.com/user/status/123")!) == .twitter)
        #expect(ReachChannel.channel(for: URL(string: "https://old.reddit.com/r/swift")!) == .reddit)
        #expect(ReachChannel.channel(for: URL(string: "https://b23.tv/abc123")!) == .bilibili)
        #expect(ReachChannel.channel(for: URL(string: "https://www.v2ex.com/t/100000")!) == .v2ex)
        #expect(ReachChannel.channel(for: URL(string: "https://xueqiu.com/S/AAPL")!) == .xueqiu)
        #expect(ReachChannel.channel(for: URL(string: "https://www.xiaoyuzhoufm.com/episode/123")!) == .xiaoyuzhou)
        #expect(ReachChannel.channel(for: URL(string: "https://www.zhipin.com/job_detail/123.html")!) == .boss)
        #expect(ReachChannel.channel(for: URL(string: "https://example.com/article")!) == .web)
    }

    @Test("Platform target parsers extract IDs and coordinates")
    func targetParsers() {
        let ghRepo = GitHubReachBackend.parseTarget("apple/swift")
        #expect(ghRepo?.owner == "apple")
        #expect(ghRepo?.repo == "swift")
        #expect(ghRepo?.issueNumber == nil)

        let ghIssue = GitHubReachBackend.parseTarget("https://github.com/swiftlang/swift/issues/42")
        #expect(ghIssue?.owner == "swiftlang")
        #expect(ghIssue?.repo == "swift")
        #expect(ghIssue?.issueNumber == 42)

        let ghPR = GitHubReachBackend.parseTarget("https://github.com/swiftlang/swift/pull/99")
        #expect(ghPR?.issueNumber == 99)

        let redditJSON = RedditReachBackend.postJSONURL(from: "https://www.reddit.com/r/swift/comments/abc123/title/")
        #expect(redditJSON?.absoluteString == "https://www.reddit.com/r/swift/comments/abc123/title.json?raw_json=1")

        #expect(V2EXReachBackend.extractTopicID(from: "https://www.v2ex.com/t/1050000#reply12") == "1050000")
        #expect(V2EXReachBackend.extractTopicID(from: "1050000") == "1050000")

        #expect(YouTubeReachBackend.extractVideoID(from: "dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeReachBackend.extractVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10") == "dQw4w9WgXcQ")
        #expect(YouTubeReachBackend.extractVideoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeReachBackend.extractVideoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")

        #expect(BilibiliReachBackend.extractBVID(from: "https://www.bilibili.com/video/BV1xx411c7mD") == "BV1xx411c7mD")
        #expect(TwitterReachBackend.extractTweetID(from: "https://x.com/swiftlang/status/1800000000000000000") == "1800000000000000000")
    }

    @Test("Transcript and reader parsers decode JSON3, XML, Jina, and Exa payloads")
    func payloadParsers() throws {
        let json3 = """
        {"events":[{"segs":[{"utf8":"Hello "},{"utf8":"Swift"}]},{"segs":[{"utf8":"world!"}]}]}
        """
        let parsedJSON3 = YouTubeReachBackend.parseJSON3Transcript(Data(json3.utf8))
        #expect(parsedJSON3 == "Hello Swift world!")

        let xml = "<transcript><text start=\"0\">First &amp; second</text><text start=\"2\">line</text></transcript>"
        #expect(YouTubeReachBackend.parseXMLTranscript(xml) == "First & second line")

        let jinaRaw = """
        Title: Swift Evolution
        URL Source: https://swift.org/blog
        Published Time: 2026-01-15T10:00:00Z
        Markdown Content:
        # Heading
        Body paragraph here.
        """
        let jinaParsed = JinaReaderBackend.parseJinaMarkdown(jinaRaw, fallbackURL: URL(string: "https://swift.org")!)
        #expect(jinaParsed.title == "Swift Evolution")
        #expect(jinaParsed.text.contains("Body paragraph here."))
        #expect(jinaParsed.publishedAt != nil)

        let exaRaw = """
        Title: Example Result
        URL: https://example.com/post
        Author: Alice
        This is the snippet body.
        """
        let exaItems = ExaMCPBackend.parseExaText(
            exaRaw,
            channel: .web,
            backend: "exa-mcp",
            fallbackTarget: "example",
            limit: 5
        )
        #expect(exaItems.count == 1)
        #expect(exaItems[0].title == "Example Result")
        #expect(exaItems[0].author == "Alice")
        #expect(exaItems[0].text == "This is the snippet body.")
    }

    @Test("Anti-bot and login wall detection classifies blocked pages accurately")
    func antiBotAndLoginWallDetection() {
        let cfPage = "Title: Just a moment...\n## Performing security verification"
        let cfErr = ReachHTTPHelper.detectChallengeOrLoginWall(in: cfPage, channel: .web)
        #expect(cfErr?.code == .platformBlocked)

        let liPage = "Sign in to view full profile /authwall"
        let liErr = ReachHTTPHelper.detectChallengeOrLoginWall(in: liPage, channel: .linkedin)
        #expect(liErr?.code == .needLogin)

        let normalPage = String(repeating: "Swift concurrency actors and structured tasks. ", count: 40)
        #expect(ReachHTTPHelper.detectChallengeOrLoginWall(in: normalPage, channel: .linkedin) == nil)
    }

    @Test("AgentReachClient falls back on retryable errors and stops on terminal errors")
    func orderedFallbackAndTerminalErrors() async {
        struct FailingBackend: ReachBackend {
            let name: String
            let error: ReachError
            func execute(request: ReachRequest) async throws -> [ReachItem] {
                throw error
            }
        }
        struct SucceedingBackend: ReachBackend {
            let name: String
            func execute(request: ReachRequest) async throws -> [ReachItem] {
                [
                    ReachItem(
                        id: "1",
                        title: "Recovered Title",
                        url: URL(string: "https://github.com/apple/swift")!,
                        text: "Recovered body",
                        channel: request.channel,
                        backend: name
                    )
                ]
            }
        }

        // 1. Retryable upstreamBroken on github-api falls back to public-web.
        let fallbackClient = AgentReachClient(
            configuration: ReachConfiguration(enableJinaReaderFallback: false, enableExaMCPFallback: false),
            customBackends: [
                FailingBackend(name: "github-api", error: ReachError(code: .upstreamBroken, message: "503")),
                SucceedingBackend(name: "public-web")
            ]
        )
        let okResult = await fallbackClient.execute(ReachRequest(channel: .github, action: .search, target: "swift"))
        #expect(okResult.ok == true)
        #expect(okResult.backend == "public-web")
        #expect(okResult.attemptedBackends == ["github-api", "public-web"])
        #expect(okResult.items.first?.title == "Recovered Title")

        // 2. Terminal rateLimited stops immediately without hitting public-web.
        let rateLimitedClient = AgentReachClient(
            configuration: ReachConfiguration(enableJinaReaderFallback: false, enableExaMCPFallback: false),
            customBackends: [
                FailingBackend(name: "github-api", error: ReachError(code: .rateLimited, message: "429", retryAfterSeconds: 60)),
                SucceedingBackend(name: "public-web")
            ]
        )
        let stoppedResult = await rateLimitedClient.execute(ReachRequest(channel: .github, action: .search, target: "swift"))
        #expect(stoppedResult.ok == false)
        #expect(stoppedResult.error?.code == .rateLimited)
        #expect(stoppedResult.attemptedBackends == ["github-api"])

        // 3. Unsupported action returns BAD_INPUT before calling any backend.
        let badAction = await fallbackClient.execute(ReachRequest(channel: .v2ex, action: .transcribe, target: "123"))
        #expect(badAction.ok == false)
        #expect(badAction.error?.code == .badInput)
    }

    @Test("AgentReachTool and ArchonSearchAgentTools expose agent_reach and reach_channels")
    func agentToolsSchemaAndExecution() async throws {
        let schema = ArchonSearchAgentTools.toolsJSONSchemaString()
        #expect(schema.contains("\"agent_reach\""))
        #expect(schema.contains("\"reach_channels\""))
        #expect(schema.contains("\"xiaoyuzhou\""))
        #expect(schema.contains("\"xueqiu\""))

        let search = ArchonSearch()
        let channelsOutput = try await ArchonSearchAgentTools.handleToolCall(
            search: search,
            toolName: "reach_channels",
            argumentsJSON: "{}"
        )
        #expect(channelsOutput.contains("github"))
        #expect(channelsOutput.contains("youtube"))
        #expect(channelsOutput.contains("twitter"))
        #expect(channelsOutput.contains("xiaoyuzhou"))

        let badChannelOutput = try await ArchonSearchAgentTools.handleToolCall(
            search: search,
            toolName: "agent_reach",
            argumentsJSON: #"{"channel":"v2ex","action":"transcribe","target":"123"}"#
        )
        #expect(badChannelOutput.contains("BAD_INPUT"))
    }
}
