import Foundation
import ArchonAgent
import ArchonCore
import Testing
@testable import ArchonInference

@Suite("LlamaLocalProvider, Streaming, Tooling & Runtime Integration Tests")
struct LlamaLocalProviderTests {
    #if canImport(llama)
    @Test("Links LlamaFramework XCFramework and reports live llama.cpp capabilities")
    func linksLlamaFramework() {
        let info = LlamaNativeRuntime.info()
        #expect(info.isAvailable)
        #expect(info.llamaVersion != nil)
        #expect(!(info.llamaVersion ?? "").isEmpty)
        #expect(info.maxDevices >= 1)
        #expect(!info.builtinChatTemplates.isEmpty)
    }
    #endif

    @Test("Validates prompt, options, and configuration before loading any GGUF file")
    func validatesInputsFailClosed() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).gguf")
        let provider = LlamaLocalProvider(modelURL: missingURL)

        await #expect(throws: LlamaProviderError.emptyPrompt) {
            _ = try await provider.generate(prompt: [.user("   ")], tools: [], options: GenerationOptions())
        }

        await #expect(throws: LlamaProviderError.invalidOptions("temperature must be finite within 0...2.")) {
            _ = try await provider.generate(
                prompt: [.user("hi")],
                tools: [],
                options: GenerationOptions(temperature: -1)
            )
        }

        let smallCtx = LlamaLocalProvider(
            modelURL: missingURL,
            configuration: LlamaConfiguration(contextLength: 128, batchSize: 64)
        )
        let hugePrompt = String(repeating: "word ", count: 400)
        await #expect(throws: LlamaProviderError.contextWindowExceeded(502, 128)) {
            _ = try await smallCtx.generate(prompt: [.user(hugePrompt)])
        }

        let badConfigProvider = LlamaLocalProvider(
            modelURL: missingURL,
            configuration: LlamaConfiguration(contextLength: 64, batchSize: 32)
        )
        await #expect(throws: LlamaProviderError.invalidConfiguration("contextLength must be within 128...1048576.")) {
            try await badConfigProvider.prepare()
        }
    }

    @Test("Memory budget gate rejects oversized GGUF models before opening native runtime")
    func rejectsModelExceedingMemoryBudget() async throws {
        let fileURL = try writeMinimalGGUFFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let backend = StubLlamaBackend()
        let provider = LlamaLocalProvider(
            source: .localFile(fileURL),
            configuration: .standard,
            predictedPeakMemoryBytes: 2_000_000_000,
            backend: backend,
            memoryBudgetProvider: { 1_000_000_000 }
        )

        await #expect(throws: LlamaProviderError.insufficientMemory(
            predictedPeakBytes: 2_000_000_000,
            availableBudgetBytes: 1_000_000_000
        )) {
            try await provider.prepare()
        }
        #expect(backend.loadCount == 0)
    }

    @Test("Executes locally under ZeroCloudMode, streams deltas, trims split stop sequences, and decodes JSON")
    func streamsGeneratesAndRespectsZeroCloud() async throws {
        let fileURL = try writeMinimalGGUFFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let backend = StubLlamaBackend(chunksToEmit: ["{\"answer\":", "\"42\"}\nST", "OP ignored"])
        let provider = LlamaLocalProvider(
            source: .localFile(fileURL),
            configuration: .standard,
            predictedPeakMemoryBytes: 100_000,
            backend: backend,
            memoryBudgetProvider: { 10_000_000 }
        )

        struct AnswerPayload: Decodable, Equatable, Sendable {
            let answer: String
        }

        try await ZeroCloudMode.withEnabled {
            let options = GenerationOptions(stopSequences: ["STOP"])
            var streamed = ""
            var sawFinish = false
            for try await chunk in provider.stream(prompt: [.user("Answer")], tools: [], options: options) {
                if let delta = chunk.deltaText {
                    streamed += delta
                }
                if chunk.isFinished {
                    sawFinish = true
                }
            }
            #expect(sawFinish)
            #expect(streamed == "{\"answer\":\"42\"}\n")

            let decoded = try await provider.generateStructuredOutput(
                prompt: "Return JSON",
                responseSchema: AnswerPayload.self
            )
            #expect(decoded == AnswerPayload(answer: "42"))
            #expect(backend.lastOptions?.responseFormatJSON == true)
        }
        #expect(backend.loadCount == 1) // cached across requests until unload()
        await provider.unload()
    }

    @Test("Parses <tool_call> responses and integrates inside an ArchonAgent Graph")
    func parsesToolCallsAndRunsInAgentGraph() async throws {
        let fileURL = try writeMinimalGGUFFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let tool = ToolDefinition(
            name: "lookup_weather",
            description: "Gets weather",
            parametersJSONSchema: ["city": AnySendable("string")]
        )
        let backend = StubLlamaBackend(
            chunksToEmit: ["Checking... <tool_call>{\"name\":\"lookup_weather\",\"arguments\":{\"city\":\"Tokyo\"}}</tool_call>"]
        )
        let provider = LlamaLocalProvider(
            source: .localFile(fileURL),
            configuration: .standard,
            predictedPeakMemoryBytes: 100_000,
            backend: backend,
            memoryBudgetProvider: { 10_000_000 }
        )

        let response = try await provider.generate(
            prompt: [.user("What is the weather in Tokyo?")],
            tools: [tool],
            options: GenerationOptions()
        )
        #expect(response.finishReason == "tool_calls")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.name == "lookup_weather")
        #expect(response.text == "Checking...")

        // Verify direct ArchonAgent Graph execution with LlamaLocalProvider.
        let plainBackend = StubLlamaBackend(chunksToEmit: ["Graph output"])
        let graphProvider = LlamaLocalProvider(
            source: .localFile(fileURL),
            configuration: .standard,
            predictedPeakMemoryBytes: 100_000,
            backend: plainBackend,
            memoryBudgetProvider: { 10_000_000 }
        )

        struct SimpleState: AgentState {
            var reply: String = ""
        }

        let builder = GraphBuilder<SimpleState>()
        builder.addNode("respond") { state in
            let res = try await graphProvider.generate(prompt: [.user("Hello")])
            var next = state
            next.reply = res.text
            return next
        }
        builder.setEntryPoint("respond")
        builder.addEdge(from: "respond", to: EndNode.id)
        let graph = try builder.compile()
        let final = try await graph.invoke(initialState: SimpleState())
        #expect(final.reply == "Graph output")
    }

    @Test("UTF-8 piece decoder handles split multi-byte emoji and Thai characters cleanly")
    func decodesSplitUTF8Sequences() {
        var decoder = LlamaUTF8PieceDecoder()
        let rocket = Array("🚀สวัสดี".utf8)
        var assembled = ""
        for byte in rocket {
            assembled += decoder.append([byte])
        }
        assembled += decoder.flush()
        #expect(assembled == "🚀สวัสดี")
    }

    @Test("Stream cancellation stops generation cleanly")
    func cancelsStreamingCleanly() async throws {
        let fileURL = try writeMinimalGGUFFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let backend = StubLlamaBackend(
            chunksToEmit: Array(repeating: "token ", count: 50),
            delayPerChunk: .milliseconds(50)
        )
        let provider = LlamaLocalProvider(
            source: .localFile(fileURL),
            configuration: .standard,
            predictedPeakMemoryBytes: 100_000,
            backend: backend,
            memoryBudgetProvider: { 10_000_000 }
        )

        let streamTask = Task {
            for try await _ in provider.stream(prompt: [.user("Stream")], tools: [], options: GenerationOptions()) {
                try Task.checkCancellation()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        streamTask.cancel()
        do {
            try await streamTask.value
        } catch is CancellationError {
            // Expected cancellation path.
        }
    }

    private func writeMinimalGGUFFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-llama-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("fixture.gguf")
        var data = makeGGUFHeader(version: 3, tensorCount: 1, kvCount: 1)
        appendKVString("general.architecture", "llama", to: &data)
        try data.write(to: fileURL)
        return fileURL
    }
}
