import Foundation
import Testing

@testable import ArchonAgent

private final class LMStudioStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func takeRequests() -> [URLRequest] {
        lock.withLock {
            let captured = requests
            requests = []
            return captured
        }
    }

    /// Takes only requests to `port`, leaving parallel tests' captures alone.
    static func takeRequests(port: Int) -> [URLRequest] {
        lock.withLock {
            let captured = requests.filter { $0.url?.port == port }
            requests.removeAll { $0.url?.port == port }
            return captured
        }
    }

    /// URLSession transmits `httpBody` as a stream, so captured requests
    /// usually carry `httpBodyStream` instead of `httpBody`.
    static func bodyBytes(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let body = """
        {"choices":[{"message":{"content":"local ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func lmStudioStubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LMStudioStub.self]
    return URLSession(configuration: configuration)
}

@Suite("LM Studio Provider Tests")
struct LMStudioProviderTests {
    @Test("Defaults target the local server root with on-device capabilities")
    func defaults() {
        let provider = LMStudioProvider()
        #expect(provider.id == "lmstudio.local-model")
        #expect(provider.endpoint.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(provider.capabilities.isOnDevice)
        #expect(provider.capabilities.supportsStreaming)
    }

    @Test("Custom base URL and model are honored")
    func customBaseURL() {
        let provider = LMStudioProvider(
            model: "qwen3-8b",
            baseURL: URL(string: "http://localhost:1235/v1")!
        )
        #expect(provider.id == "lmstudio.qwen3-8b")
        #expect(provider.endpoint.absoluteString == "http://localhost:1235/v1/chat/completions")
    }

    @Test("Unified enum and shortcut resolve to the LM Studio provider")
    func factoryCoverage() {
        #expect(ArchonAI.model(.lmStudio()) is LMStudioProvider)
        #expect(ArchonAI.model(.lmStudio(model: "qwen3-8b")).id == "lmstudio.qwen3-8b")
        #expect(ArchonAI.lmStudio().id == "lmstudio.local-model")
        #expect(ArchonAI.lmStudio(model: "qwen3-8b").id == "lmstudio.qwen3-8b")
    }

    @Test("Generate posts the OpenAI-compatible body to chat completions")
    func generatePostsChatCompletions() async throws {
        _ = LMStudioStub.takeRequests(port: 1234)
        let provider = LMStudioProvider(model: "qwen3-8b", urlSession: lmStudioStubbedSession())
        let response = try await provider.generate(
            prompt: [.user("hi")],
            tools: [],
            options: GenerationOptions()
        )
        #expect(response.text == "local ok")
        let requests = LMStudioStub.takeRequests(port: 1234)
        let captured = try #require(requests.first)
        #expect(captured.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(captured.value(forHTTPHeaderField: "Authorization") != nil)
        let body = try #require(LMStudioStub.bodyBytes(of: captured))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen3-8b")
    }

    @Test("Non-loopback endpoints fail closed under ZeroCloud")
    func zeroCloudRejectsNonLoopback() async {
        let provider = LMStudioProvider(
            baseURL: URL(string: "http://192.168.1.5:1234/v1")!,
            urlSession: lmStudioStubbedSession()
        )
        await ZeroCloudMode.withEnabled {
            do {
                _ = try await provider.generate(
                    prompt: [.user("hi")],
                    tools: [],
                    options: GenerationOptions()
                )
                Issue.record("Expected a ZeroCloud violation for a LAN endpoint")
            } catch GraphError.zeroCloudViolation {
            } catch {
                Issue.record("Wrong error for a LAN endpoint under ZeroCloud: \(error)")
            }
            _ = LMStudioStub.takeRequests()
        }
    }

    @Test("Loopback endpoints stay available under ZeroCloud")
    func zeroCloudAllowsLoopback() async throws {
        let provider = LMStudioProvider(
            baseURL: URL(string: "http://localhost:1235/v1")!,
            urlSession: lmStudioStubbedSession()
        )
        let response = try await ZeroCloudMode.withEnabled {
            try await provider.generate(
                prompt: [.user("hi")],
                tools: [],
                options: GenerationOptions()
            )
        }
        #expect(response.text == "local ok")
        let requests = LMStudioStub.takeRequests(port: 1235)
        #expect(requests.first?.url?.absoluteString == "http://localhost:1235/v1/chat/completions")
    }
}
