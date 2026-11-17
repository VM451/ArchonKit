import Foundation
import ArchonCore

// MARK: - Decision
// vercel-labs/agent-browser (Rust CLI, CDP + accessibility snapshots with @eN refs)
// is audited as PARTIAL / ADAPT: ArchonKit adopts the snapshot/ref model and
// session discipline but implements it as a host-owned Swift adapter with
// ArchonKit permission, verification, and audit controls. No Rust code or
// Playwright/Puppeteer is vendored; the host runs the CLI and the package
// only translates the wire shape via `BrowserSemanticBridge`.

/// Browser page kind reported by a host CDP adapter.
public enum BrowserPageKind: String, Codable, Sendable {
    case web
    case pdf
}

/// A browser snapshot element mirroring agent-browser's accessibility
/// snapshot entry (role, label, @eN ref). The ref is the host's stable
/// identifier; coordinate taps are never issued by ArchonKit.
public struct BrowserElementSnapshot: Codable, Sendable, Equatable {
    public let ref: String
    public let role: String
    public let label: String
    public let value: String?
    public let url: String?

    public init(ref: String, role: String, label: String, value: String? = nil, url: String? = nil) {
        self.ref = ref
        self.role = role
        self.label = label
        self.value = value
        self.url = url
    }
}

/// Browser snapshot from a host CDP adapter (agent-browser compatible).
public struct BrowserSnapshot: Sendable {
    public let title: String
    public let url: URL
    public let kind: BrowserPageKind
    public let elements: [BrowserElementSnapshot]

    public init(title: String, url: URL, kind: BrowserPageKind = .web, elements: [BrowserElementSnapshot] = []) {
        self.title = title
        self.url = url
        self.kind = kind
        self.elements = elements
    }
}

/// Host-owned browser adapter. The host drives Chrome via CDP
/// (agent-browser CLI is one such host) and exposes a semantic snapshot.
/// ArchonKit never owns the browser process.
public protocol BrowserPageProvider: Sendable {
    func currentSnapshot() async throws -> BrowserSnapshot
    func navigate(to url: URL) async throws
    func activate(ref: String) async throws
    func fill(ref: String, text: String) async throws
    func back() async throws
}

/// Translates a browser snapshot into the coordinate-free SemanticSnapshot
/// used by ComputerUseController.
public struct BrowserSemanticBridge: ComputerUseObservationProvider, Sendable {
    private let provider: any BrowserPageProvider
    private let pageURL: URL

    public init(provider: any BrowserPageProvider, pageURL: URL) {
        self.provider = provider
        self.pageURL = pageURL
    }

    public func captureSnapshot() async throws -> SemanticSnapshot {
        let browser = try await provider.currentSnapshot()
        let elements = browser.elements.map { el in
            SemanticElement(id: el.ref, role: el.role, label: el.label, value: el.value)
        }
        return SemanticSnapshot(screenID: browser.url.absoluteString, elements: elements)
    }

    public func preflight(url: URL) async throws {
        try await provider.navigate(to: url)
    }

    public func activate(ref: String) async throws {
        try await provider.activate(ref: ref)
    }

    public func fill(ref: String, text: String) async throws {
        try await provider.fill(ref: ref, text: text)
    }
}

/// Catalog of browser semantic actions (agent-browser verbs mapped to
/// ArchonKit risks). All actions are semantic-first; no coordinate API exists.
public struct BrowserActionCatalog: Sendable {
    public static func navigate(url: URL, id: String = "browser.navigate") -> SemanticActionDescriptor {
        SemanticActionDescriptor(
            id: id,
            description: "Navigate browser to \(url.absoluteString)",
            risk: .navigate,
            requiresApproval: false
        )
    }

    public static func activate(ref: String, id: String = "browser.activate") -> SemanticActionDescriptor {
        SemanticActionDescriptor(
            id: id,
            description: "Activate browser element @\(ref)",
            risk: .modify,
            targetRole: "button",
            requiresApproval: true
        )
    }

    public static func fill(ref: String, id: String = "browser.fill") -> SemanticActionDescriptor {
        SemanticActionDescriptor(
            id: id,
            description: "Fill browser field @\(ref)",
            risk: .modify,
            targetRole: "textbox",
            requiresApproval: true
        )
    }

    public static func back(id: String = "browser.back") -> SemanticActionDescriptor {
        SemanticActionDescriptor(
            id: id,
            description: "Browser back",
            risk: .navigate,
            requiresApproval: false
        )
    }
}

/// Host adapter that shells out to the vercel-labs/agent-browser CLI
/// (JSON-RPC over stdio). The CLI owns Chrome/CDP; this type only marshals
/// verified requests with bounds and audits. Credential-free: state is
/// kept in the CLI's session vault, not in ArchonKit.
public struct AgentBrowserCLIProvider: Sendable {
    public var executableURL: URL
    public var session: String?

    public init(executableURL: URL, session: String? = nil) {
        self.executableURL = executableURL
        self.session = session
    }

    private func baseArguments() -> [String] {
        var args: [String] = []
        if let session { args += ["--session", session] }
        return args
    }

    public func snapshotJSON() async throws -> Data {
        let (data, code) = try await run(["snapshot"] + baseArguments())
        guard code == 0 else { throw ComputerUseError.verificationFailed("agent-browser snapshot failed (\(code))") }
        return data
    }

    public func run(arguments: [String]) async throws -> (Data, Int32) {
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
                    process.waitUntilExit()
                    continuation.resume(returning: (pipe.fileHandleForReading.readDataToEndOfFile(), process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(_ args: [String]) async throws -> (Data, Int32) {
        try await run(arguments: args)
    }
}

extension AgentBrowserCLIProvider: BrowserPageProvider {
    public func currentSnapshot() async throws -> BrowserSnapshot {
        let data = try await snapshotJSON()
        return try BrowserSnapshotParser.parse(data: data, fallbackURL: URL(string: "about:blank")!)
    }

    public func navigate(to url: URL) async throws {
        let (data, code) = try await run(["open", url.absoluteString] + baseArguments())
        guard code == 0 else { throw ComputerUseError.verificationFailed("agent-browser open failed: \(String(data: data, encoding: .utf8) ?? "")") }
    }

    public func activate(ref: String) async throws {
        let (data, code) = try await run(["click", ref] + baseArguments())
        guard code == 0 else { throw ComputerUseError.verificationFailed("agent-browser click failed") }
    }

    public func fill(ref: String, text: String) async throws {
        let (data, code) = try await run(["fill", ref, text] + baseArguments())
        guard code == 0 else { throw ComputerUseError.verificationFailed("agent-browser fill failed") }
    }

    public func back() async throws {
        let (_, code) = try await run(["back"] + baseArguments())
        guard code == 0 else { throw ComputerUseError.verificationFailed("agent-browser back failed") }
    }
}

/// Parser for agent-browser snapshot JSON (tolerant of schema drift).
public struct BrowserSnapshotParser: Sendable {
    public static func parse(data: Data, fallbackURL: URL) throws -> BrowserSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BrowserSnapshot(title: "", url: fallbackURL, elements: [])
        }
        let title = (json["title"] as? String) ?? ""
        let urlString = (json["url"] as? String) ?? fallbackURL.absoluteString
        let url = URL(string: urlString) ?? fallbackURL
        let rawElements = (json["elements"] as? [[String: Any]]) ?? (json["tree"] as? [[String: Any]]) ?? []
        var elements: [BrowserElementSnapshot] = []
        for (i, raw) in rawElements.enumerated() {
            let ref = (raw["ref"] as? String) ?? "@e\(i)"
            let role = (raw["role"] as? String) ?? "unknown"
            let label = (raw["label"] as? String) ?? (raw["name"] as? String) ?? ""
            let value = raw["value"] as? String
            elements.append(BrowserElementSnapshot(ref: ref, role: role, label: label, value: value))
        }
        return BrowserSnapshot(title: title, url: url, elements: elements)
    }
}
