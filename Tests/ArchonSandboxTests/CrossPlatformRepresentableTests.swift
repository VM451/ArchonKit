import Testing
@testable import ArchonSandbox
import ArchonCore

@Suite("Cross-platform representable — iOS/iPadOS/macOS/visionOS")
@MainActor
struct CrossPlatformRepresentableTests {

    @Test("NativeSandboxRepresentable is available on this platform")
    func representableAvailable() {
        let workspace = SandboxWorkspace.defaultTemplate()
        let controller = SandboxViewController(workspace: workspace)

        // The type must exist on every declared platform (iOS, macOS, visionOS).
        // Before the fix this failed to compile on iOS with
        // "Unable to resolve module dependency: 'AppKit'" because the LOCAL_STUB
        // branch imported AppKit unconditionally.
        #if os(iOS) || os(visionOS)
        let representable = NativeSandboxRepresentable(controller: controller)
        _ = representable
        #elseif os(macOS)
        let representable = NativeSandboxRepresentable(controller: controller)
        _ = representable
        #else
        // Placeholder path for other platforms (watchOS/tvOS) — View stub.
        let representable = NativeSandboxRepresentable(controller: controller)
        _ = representable
        #endif
    }

    @Test("SandboxView body gate includes visionOS")
    func sandboxViewIncludesVisionOS() {
        // Compiling ArchonSandboxView on visionOS exercises the
        // `(os(iOS) || os(macOS) || os(visionOS)) && canImport(WebKit)`
        // gate. On visionOS WebKit is available, so the view must
        // reference NativeSandboxRepresentable instead of the
        // "not available" fallback.
        let workspace = SandboxWorkspace.defaultTemplate()
        let view = ArchonSandboxView(workspace: workspace, configuration: .default)
        _ = view
    }

    @Test("ArchonDeviceCapabilities reports a known platform")
    func platformIsKnown() {
        let caps = ArchonDeviceCapabilities.current
        // ArchonPlatform is exactly iOS / iPadOS / macOS / visionOS.
        // iPadOS is a subset of os(iOS) at the SDK level, distinguished
        // by device identifier at runtime.
        #if os(iOS)
        #expect(caps.platform == .iOS || caps.platform == .iPadOS)
        #elseif os(visionOS)
        #expect(caps.platform == .visionOS)
        #elseif os(macOS)
        #expect(caps.platform == .macOS)
        #else
        #expect(ArchonPlatform.allCases.contains(caps.platform))
        #endif
    }
}
