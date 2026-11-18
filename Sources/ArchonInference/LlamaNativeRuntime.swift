import Foundation
import os

#if canImport(llama)
import llama
#endif

/// Runtime diagnostics for the linked `llama.cpp` framework.
public enum LlamaNativeRuntime {
    /// Returns live capabilities and metadata from the linked `llama.xcframework`.
    public static func info() -> LlamaRuntimeInfo {
        #if canImport(llama)
        LlamaNativeBackend.ensureInitialized()
        let version = String(cString: llama_version())
        let templateCount = Int(llama_chat_builtin_templates(nil, 0))
        var templates: [String] = []
        if templateCount > 0 {
            var ptrs = [UnsafePointer<CChar>?](repeating: nil, count: templateCount)
            let filled = Int(llama_chat_builtin_templates(&ptrs, ptrs.count))
            for idx in 0..<min(filled, ptrs.count) {
                if let ptr = ptrs[idx] {
                    templates.append(String(cString: ptr))
                }
            }
        }
        return LlamaRuntimeInfo(
            isAvailable: true,
            llamaVersion: version,
            supportsMemoryMap: llama_supports_mmap(),
            supportsGPUOffload: llama_supports_gpu_offload(),
            maxDevices: Int(llama_max_devices()),
            builtinChatTemplates: templates.sorted()
        )
        #else
        return LlamaRuntimeInfo(
            isAvailable: false,
            llamaVersion: nil,
            supportsMemoryMap: false,
            supportsGPUOffload: false,
            maxDevices: 0,
            builtinChatTemplates: []
        )
        #endif
    }
}

#if canImport(llama)

final class AtomicAbortFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var isAborted: Bool {
        lock.withLock { $0 }
    }

    func abort() {
        lock.withLock { $0 = true }
    }

    func reset() {
        lock.withLock { $0 = false }
    }
}

let llamaNullLogger: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, _, _ in
}

let llamaAbortCallback: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { userData in
    guard let userData else { return false }
    let flag = Unmanaged<AtomicAbortFlag>.fromOpaque(userData).takeUnretainedValue()
    return flag.isAborted
}

let llamaLoadProgressCallback: @convention(c) (Float, UnsafeMutableRawPointer?) -> Bool = { _, userData in
    guard let userData else { return true }
    let flag = Unmanaged<AtomicAbortFlag>.fromOpaque(userData).takeUnretainedValue()
    return !flag.isAborted
}

/// Owns the C `llama_model`, `llama_context`, and `llama_batch_ext` handles and
/// guarantees serialized access on a dedicated worker queue.
final class LlamaContextBox: @unchecked Sendable {
    let model: OpaquePointer
    let context: OpaquePointer
    let vocab: OpaquePointer
    let batch: OpaquePointer
    let effectiveContextLength: Int
    let queue = DispatchQueue(label: "com.archon.llama.context", qos: .userInitiated)
    let abortFlag: AtomicAbortFlag
    private var freed = false

    init(
        model: OpaquePointer,
        context: OpaquePointer,
        vocab: OpaquePointer,
        batch: OpaquePointer,
        effectiveContextLength: Int,
        abortFlag: AtomicAbortFlag
    ) {
        self.model = model
        self.context = context
        self.vocab = vocab
        self.batch = batch
        self.effectiveContextLength = effectiveContextLength
        self.abortFlag = abortFlag
    }

    func freeResources() {
        guard !freed else { return }
        freed = true
        llama_batch_ext_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    deinit {
        freeResources()
    }
}

#endif
