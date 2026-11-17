import Foundation
import Testing
import ArchonComputerUse

@Suite("Browser and Desktop adapter catalogs")
struct BrowserDesktopAdapterTests {
    @Test("Browser catalog descriptors map to correct risks")
    func browserCatalogRisks() {
        let nav = BrowserActionCatalog.navigate(url: URL(string: "https://example.com")!)
        #expect(nav.risk == .navigate)
        #expect(!nav.requiresPostcondition)
        let act = BrowserActionCatalog.activate(ref: "@e1")
        #expect(act.risk == .modify)
        #expect(act.requiresPostcondition)
        #expect(act.targetRole == "button")
    }

    @Test("Desktop catalog descriptors map to correct risks")
    func desktopCatalogRisks() {
        let click = DesktopActionCatalog.click(token: "@e5")
        #expect(click.risk == .modify)
        #expect(click.requiresPostcondition)
        let nav = DesktopActionCatalog.navigate(windowID: "w1")
        #expect(nav.risk == .navigate)
    }

    @Test("Browser snapshot parser handles elements and tree shapes")
    func browserParser() throws {
        let json1 = """
        {"title":"T","url":"https://example.com","elements":[{"ref":"@e1","role":"button","label":"Go"}]}
        """.data(using: .utf8)!
        let snap1 = try BrowserSnapshotParser.parse(data: json1, fallbackURL: URL(string: "about:blank")!)
        #expect(snap1.elements.count == 1)
        #expect(snap1.elements[0].ref == "@e1")

        let json2 = """
        {"url":"https://a.com","tree":[{"ref":"@e2","role":"textbox","label":"Search"}]}
        """.data(using: .utf8)!
        let snap2 = try BrowserSnapshotParser.parse(data: json2, fallbackURL: URL(string: "about:blank")!)
        #expect(snap2.elements[0].ref == "@e2")
    }

    @Test("Desktop parser handles elements and skips empty tokens")
    func desktopParser() throws {
        let window = DesktopWindow(pid: 123, windowID: "w1", appIdentifier: "com.example", title: "Test")
        let json = """
        {"elements":[{"token":"@e1","role":"button","label":"OK"},{"token":"","role":"label","label":"skip"}]}
        """.data(using: .utf8)!
        let snap = try DesktopSnapshotParser.parse(data: json, window: window)
        #expect(snap.elements.count == 1)
        #expect(snap.elements[0].token == "@e1")
    }

    @Test("Browser bridge maps snapshot to semantic elements")
    func browserBridgeMapping() async throws {
        struct MockProvider: BrowserPageProvider {
            func currentSnapshot() async throws -> BrowserSnapshot {
                BrowserSnapshot(
                    title: "T",
                    url: URL(string: "https://example.com")!,
                    elements: [BrowserElementSnapshot(ref: "@e1", role: "button", label: "Go")]
                )
            }
            func navigate(to url: URL) async throws {}
            func activate(ref: String) async throws {}
            func fill(ref: String, text: String) async throws {}
            func back() async throws {}
        }
        let bridge = BrowserSemanticBridge(provider: MockProvider(), pageURL: URL(string: "https://example.com")!)
        let sem = try await bridge.captureSnapshot()
        #expect(sem.elements.count == 1)
        #expect(sem.elements[0].id == "@e1")
        #expect(sem.screenID == "https://example.com")
    }

    @Test("Desktop bridge maps snapshot to semantic elements")
    func desktopBridgeMapping() async throws {
        struct MockWin: DesktopWindowProvider {
            func listWindows() async throws -> [DesktopWindow] {
                [DesktopWindow(pid: 1, windowID: "w1", appIdentifier: "com.example", title: "T")]
            }
            func snapshot(window: DesktopWindow) async throws -> DesktopSnapshot {
                DesktopSnapshot(window: window, elements: [DesktopElementSnapshot(token: "@e1", role: "button", label: "OK")])
            }
            func activate(token: String, window: DesktopWindow) async throws {}
            func typeText(_ text: String, token: String, window: DesktopWindow) async throws {}
            func verify(window: DesktopWindow, predicate: (DesktopSnapshot) -> Bool) async throws -> Bool { true }
        }
        let bridge = DesktopSemanticBridge(provider: MockWin())
        let sem = try await bridge.captureSnapshot(window: DesktopWindow(pid: 1, windowID: "w1", appIdentifier: "com.example", title: "T"))
        #expect(sem.elements[0].id == "@e1")
    }
}
