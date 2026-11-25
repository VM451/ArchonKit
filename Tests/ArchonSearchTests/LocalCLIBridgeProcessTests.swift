#if os(macOS)
import Foundation
import Testing
@testable import ArchonSearch

@Suite("Local CLI bridge process handling")
struct LocalCLIBridgeProcessTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test("Large stdout and stderr are drained without deadlock")
    func largeOutputDoesNotDeadlock() async throws {
        let bridge = LocalCLIBridge(timeout: 30)
        let data = try await bridge.runProcess(
            executable: shell,
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' e >&2; head -c 300000 /dev/zero | tr '\\0' o"],
            timeout: 30
        )
        #expect(data.count == 300_000)
    }

    @Test("A hung CLI is terminated with a timeout error")
    func hungProcessTimesOut() async throws {
        let bridge = LocalCLIBridge(timeout: 0.5)
        do {
            _ = try await bridge.runProcess(executable: shell, arguments: ["-c", "sleep 30"], timeout: 0.5)
            Issue.record("Expected a timeout")
        } catch let error as ReachError {
            #expect(error.code == .timeout)
        }
    }

    @Test("A timeout is not blocked by a grandchild holding the pipes")
    func timeoutIgnoresInheritedPipes() async throws {
        let bridge = LocalCLIBridge(timeout: 0.5)
        let start = ContinuousClock.now
        do {
            _ = try await bridge.runProcess(executable: shell, arguments: ["-c", "sleep 30 & wait"], timeout: 0.5)
            Issue.record("Expected a timeout")
        } catch let error as ReachError {
            #expect(error.code == .timeout)
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("Output is returned after exit even if a background child keeps the pipes open")
    func exitedProcessWithBackgroundChildReturns() async throws {
        let bridge = LocalCLIBridge(timeout: 30)
        let start = ContinuousClock.now
        let data = try await bridge.runProcess(executable: shell, arguments: ["-c", "echo ready; sleep 30 &"], timeout: 30)
        #expect(String(decoding: data, as: UTF8.self) == "ready\n")
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("Empty stdout surfaces stderr as upstream failure")
    func emptyStdoutUsesStderr() async throws {
        let bridge = LocalCLIBridge()
        do {
            _ = try await bridge.runProcess(executable: shell, arguments: ["-c", "echo boom >&2; exit 1"], timeout: 30)
            Issue.record("Expected a failure")
        } catch let error as ReachError {
            #expect(error.code == .upstreamBroken)
            #expect(error.message.contains("boom"))
        }
    }
}
#endif
