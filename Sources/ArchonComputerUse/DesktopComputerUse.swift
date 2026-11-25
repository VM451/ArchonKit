import Foundation
import ArchonCore

// MARK: - Decision
// vercel-labs/agent-desktop (and its underlying cua-driver style host) is audited
// as PARTIAL / ADAPT: ArchonKit adopts the exact-window, snapshot→act→verify
// discipline (observe before input, act once via element token, verify from
// fresh state) but implements it as host-owned semantic adapters. No private
// AX APIs, no background_unavailable fallback without consent, no portal.

/// Desktop window identifier on the host (pid + window id from AX).
public struct DesktopWindow: Sendable, Codable, Equatable, Hashable {
    public let pid: pid_t
    public let windowID: String
    public let appIdentifier: String
    public let title: String

    public init(pid: pid_t, windowID: String, appIdentifier: String, title: String) {
        self.pid = pid
        self.windowID = windowID
        self.appIdentifier = appIdentifier
        self.title = title
    }
}

/// Element as reported by an AX snapshot (maps to @eN-style token on the host).
public struct DesktopElementSnapshot: Codable, Sendable, Equatable {
    public let token: String
    public let role: String
    public let label: String
    public let value: String?

    public init(token: String, role: String, label: String, value: String? = nil) {
        self.token = token
        self.role = role
        self.label = label
        self.value = value
    }
}

/// Desktop window snapshot (exact target, not desktop).
public struct DesktopSnapshot: Sendable {
    public let window: DesktopWindow
    public let elements: [DesktopElementSnapshot]

    public init(window: DesktopWindow, elements: [DesktopElementSnapshot] = []) {
        self.window = window
        self.elements = elements
    }
}

/// Host-owned desktop adapter. The host drives a single window via AX;
/// ArchonKit only translates the snapshot and validates the request.
public protocol DesktopWindowProvider: Sendable {
    func listWindows() async throws -> [DesktopWindow]
    func snapshot(window: DesktopWindow) async throws -> DesktopSnapshot
    func activate(token: String, window: DesktopWindow) async throws
    func typeText(_ text: String, token: String, window: DesktopWindow) async throws
    func verify(window: DesktopWindow, predicate: (DesktopSnapshot) -> Bool) async throws -> Bool
}

/// Translates a desktop window snapshot into the coordinate-free SemanticSnapshot.
public struct DesktopSemanticBridge: Sendable {
    private let provider: any DesktopWindowProvider

    public init(provider: any DesktopWindowProvider) {
        self.provider = provider
    }

    public func captureSnapshot(window: DesktopWindow) async throws -> SemanticSnapshot {
        let desktop = try await provider.snapshot(window: window)
        let elements = desktop.elements.map { el in
            SemanticElement(id: el.token, role: el.role, label: el.label, value: el.value)
        }
        return SemanticSnapshot(screenID: "\(window.appIdentifier)/\(window.windowID)", elements: elements)
    }

    public func activate(token: String, window: DesktopWindow) async throws {
        try await provider.activate(token: token, window: window)
    }

    public func typeText(_ text: String, token: String, window: DesktopWindow) async throws {
        try await provider.typeText(text, token: token, window: window)
    }

    public func verify(window: DesktopWindow, predicate: (DesktopSnapshot) -> Bool) async throws -> Bool {
        let snap = try await provider.snapshot(window: window)
        return predicate(snap)
    }
}

extension DesktopSemanticBridge: ComputerUseObservationProvider {
    private var defaultWindow: DesktopWindow? { nil }
    public func captureSnapshot() async throws -> SemanticSnapshot {
        // Hosts must supply a window when using this bridge via a window-scoped
        // provider; this convenience captures from the first listed window.
        let windows = try await provider.listWindows()
        guard let first = windows.first else { throw ComputerUseError.observationUnavailable }
        return try await captureSnapshot(window: first)
    }
}

// MARK: - cua-driver CLI host

#if os(macOS)
/// Host adapter that shells out to the `cua-driver` CLI (agent-desktop's
/// native counterpart). The CLI owns AX access; this type only marshals
/// bounded, audited requests. It follows the cua always-on rule:
/// observe → act (once) → verify from fresh state.
public struct CUADriverProvider: Sendable {
    public var executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Runs `cua-driver <subcommand>` and returns stdout + exit code.
    public func run(arguments: [String]) async throws -> (Data, Int32) {
        try await HostProcessRunner.run(executableURL: executableURL, arguments: arguments)
    }

    public func listWindowsJSON() async throws -> Data {
        let (data, code) = try await run(arguments: ["list_windows"])
        guard code == 0 else { throw ComputerUseError.verificationFailed("cua-driver list_windows failed") }
        return data
    }

    public func windowStateJSON(pid: pid_t, windowID: String) async throws -> Data {
        let (data, code) = try await run(arguments: ["get_window_state", "--pid", "\(pid)", "--window", windowID])
        guard code == 0 else { throw ComputerUseError.verificationFailed("cua-driver get_window_state failed") }
        return data
    }

    public func click(token: String, pid: pid_t, windowID: String) async throws {
        let (data, code) = try await run(arguments: ["click", "--pid", "\(pid)", "--window", windowID, "--token", token])
        guard code == 0 else { throw ComputerUseError.verificationFailed("cua-driver click failed: \(String(data: data, encoding: .utf8) ?? "")") }
    }

    public func typeText(_ text: String, token: String, pid: pid_t, windowID: String) async throws {
        let (data, code) = try await run(arguments: ["type_text", "--pid", "\(pid)", "--window", windowID, "--token", token, text])
        guard code == 0 else { throw ComputerUseError.verificationFailed("cua-driver type_text failed: \(String(data: data, encoding: .utf8) ?? "")") }
    }
}
#endif

// MARK: - Catalog

/// Desktop semantic action descriptors (agent-desktop verbs mapped to risks).
public struct DesktopActionCatalog: Sendable {
    public static func click(token: String, id: String = "desktop.click") -> SemanticActionDescriptor {
        SemanticActionDescriptor(
            id: id,
            description: "Click desktop element \(token)",
            risk: .modify,
            targetRole: "button",
            requiresApproval: true
        )
    }

    public static func typeText(id: String = "desktop.typeText") -> SemanticActionDescriptor {
        SemanticActionDescriptor(
            id: id,
            description: "Type text into desktop field",
            risk: .modify,
            targetRole: "textbox",
            requiresApproval: true
        )
    }

    public static func navigate(windowID: String, id: String = "desktop.navigate") -> SemanticActionDescriptor {
        SemanticActionDescriptor(
            id: id,
            description: "Focus desktop window \(windowID)",
            risk: .navigate,
            requiresApproval: false
        )
    }
}

#if os(macOS)
/// Desktop observation provider that mediates between the cua-driver CLI
/// JSON and the semantic controller. Enforces the cua rule: exact window,
/// fresh snapshot per action, no stale token reuse.
public struct DesktopObservationProvider: Sendable {
    private let driver: CUADriverProvider
    private let window: DesktopWindow

    public init(driver: CUADriverProvider, window: DesktopWindow) {
        self.driver = driver
        self.window = window
    }

    public func snapshot() async throws -> DesktopSnapshot {
        let data = try await driver.windowStateJSON(pid: window.pid, windowID: window.windowID)
        return try DesktopSnapshotParser.parse(data: data, window: window)
    }
}

extension DesktopObservationProvider: ComputerUseObservationProvider {
    public func captureSnapshot() async throws -> SemanticSnapshot {
        let snap = try await snapshot()
        let elements = snap.elements.map { SemanticElement(id: $0.token, role: $0.role, label: $0.label, value: $0.value) }
        return SemanticSnapshot(screenID: "\(window.appIdentifier)/\(window.windowID)", elements: elements)
    }
}
#endif

/// Tolerant parser for cua-driver JSON (handles schema drift).
public struct DesktopSnapshotParser: Sendable {
    public static func parse(data: Data, window: DesktopWindow) throws -> DesktopSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DesktopSnapshot(window: window, elements: [])
        }
        let raw = (json["elements"] as? [[String: Any]]) ?? (json["tree"] as? [[String: Any]]) ?? []
        var elements: [DesktopElementSnapshot] = []
        for rawEl in raw {
            let token = (rawEl["token"] as? String) ?? (rawEl["ref"] as? String) ?? ""
            guard !token.isEmpty else { continue }
            let role = (rawEl["role"] as? String) ?? "unknown"
            let label = (rawEl["label"] as? String) ?? ""
            let value = rawEl["value"] as? String
            elements.append(DesktopElementSnapshot(token: token, role: role, label: label, value: value))
        }
        return DesktopSnapshot(window: window, elements: elements)
    }
}
