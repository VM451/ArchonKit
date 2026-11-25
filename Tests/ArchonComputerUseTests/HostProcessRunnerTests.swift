#if os(macOS)
import Foundation
import Testing
import ArchonComputerUse

@Suite("Host CLI process runner")
struct HostProcessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test("Output larger than the pipe buffer does not deadlock")
    func largeOutputDoesNotDeadlock() async throws {
        let provider = CUADriverProvider(executableURL: shell)
        let (data, code) = try await provider.run(arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a"])
        #expect(code == 0)
        #expect(data.count == 300_000)
    }

    @Test("Browser CLI failures include the CLI output")
    func browserFailureIncludesOutput() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-agent-browser-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho \"no element $2\" >&2\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let provider = AgentBrowserCLIProvider(executableURL: script)
        do {
            try await provider.activate(ref: "@e9")
            Issue.record("Expected activate to throw")
        } catch let ComputerUseError.verificationFailed(message) {
            #expect(message.contains("no element @e9"))
        }
    }
}
#endif
