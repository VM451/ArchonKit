#if !LOCAL_STUB
import SwiftUI
import Combine
#if canImport(WebKit)
import WebKit
#endif

/// MainActor observable controller managing UI state, loading progress, event stream absorption, and WebKit binding for `SandboxView`.
@MainActor
public final class SandboxViewController: ObservableObject {
    @Published public private(set) var isLoading: Bool = true
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var logs: [SandboxEvent] = []
    @Published public private(set) var auditRecords: [SandboxAuditRecord] = []

    public let workspace: SandboxWorkspace
    public let configuration: SandboxConfiguration
    public let engine: SandboxEngine

    private var eventStreamTask: Task<Void, Never>?
    private var auditStreamTask: Task<Void, Never>?
    #if canImport(WebKit)
    public var webView: WKWebView?
    #endif
    
    public init(workspace: SandboxWorkspace, configuration: SandboxConfiguration = .default) {
        self.workspace = workspace
        self.configuration = configuration
        self.engine = SandboxEngine(workspace: workspace, configuration: configuration)
        
        startObservingEvents()
    }
    
    deinit {
        eventStreamTask?.cancel()
        auditStreamTask?.cancel()
    }

    private func startObservingEvents() {
        eventStreamTask = Task { [weak self, engine] in
            for await event in engine.eventStream {
                guard !Task.isCancelled else { break }
                self?.handleEvent(event)
            }
        }
        auditStreamTask = Task { [weak self, engine] in
            for await record in engine.auditStream {
                guard !Task.isCancelled else { break }
                self?.handleAuditRecord(record)
            }
        }
    }

    private func handleAuditRecord(_ record: SandboxAuditRecord) {
        auditRecords.append(record)
        // Keep audit buffer bounded to latest 200 items
        if auditRecords.count > 200 {
            auditRecords.removeFirst(auditRecords.count - 200)
        }
    }
    
    private func handleEvent(_ event: SandboxEvent) {
        logs.append(event)
        // Keep log buffer bounded to latest 200 items
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        
        switch event {
        case .lifecycle(let state):
            if state == .ready {
                self.isLoading = false
                self.isReady = true
            } else if state == .error {
                self.isLoading = false
            }
        case .uncaughtError(let message, _):
            self.errorMessage = message
        default:
            break
        }
    }
    
    public func bootstrap() async {
        // Initial setup complete
        self.isLoading = false
        self.isReady = true
    }
    
    public func clearLogs() {
        self.logs.removeAll()
    }

    public func clearAuditRecords() {
        self.auditRecords.removeAll()
    }
}

#else
import Foundation
import Combine

/// Stub that satisfies call sites compiled with LOCAL_STUB (CLT macOS).
/// It mirrors the full controller's public surface so tests and hosts link.
@MainActor
public final class SandboxViewController: ObservableObject {
    public var isLoading: Bool = true
    public var isReady: Bool = false
    public var errorMessage: String?
    public var logs: [SandboxEvent] = []
    public var auditRecords: [SandboxAuditRecord] = []
    public let workspace: SandboxWorkspace
    public let configuration: SandboxConfiguration
    public let engine: SandboxEngine
    public init(workspace: SandboxWorkspace = SandboxWorkspace.defaultTemplate(), configuration: SandboxConfiguration = .default) {
        self.workspace = workspace
        self.configuration = configuration
        self.engine = SandboxEngine(workspace: workspace, configuration: configuration)
    }
    public init() {
        self.workspace = SandboxWorkspace.defaultTemplate()
        self.configuration = .default
        self.engine = SandboxEngine(workspace: self.workspace, configuration: self.configuration)
    }
    public func bootstrap() async { isLoading = false; isReady = true }
    public func clearLogs() { logs.removeAll() }
    public func clearAuditRecords() { auditRecords.removeAll() }
}
#endif
