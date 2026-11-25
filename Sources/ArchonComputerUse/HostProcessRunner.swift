#if os(macOS)
import Foundation

/// Runs a host CLI and returns its combined stdout/stderr and exit status.
///
/// Output is drained before waiting for exit so a child that writes more
/// than the pipe buffer (64 KiB) cannot block forever on a full pipe.
enum HostProcessRunner {
    static func run(executableURL: URL, arguments: [String]) async throws -> (Data, Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (data, process.terminationStatus))
            }
        }
    }
}
#endif
