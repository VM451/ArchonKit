import Foundation

#if canImport(llama)
import llama

struct LlamaNativeBackend: LlamaBackendDriver {
    private static let initializeOnce: Void = {
        llama_log_set(llamaNullLogger, nil)
        llama_backend_init()
    }()

    static func ensureInitialized() {
        _ = initializeOnce
    }

    func loadSession(
        source: LlamaModelSource,
        configuration: LlamaConfiguration,
        metadata: LlamaGGUFMetadata
    ) async throws -> any LlamaLoadedSession {
        Self.ensureInitialized()
        try Task.checkCancellation()

        let abortFlag = AtomicAbortFlag()
        let queue = DispatchQueue(label: "com.archon.llama.loader", qos: .userInitiated)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if abortFlag.isAborted {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let box = try Self.loadBoxSync(
                            source: source,
                            configuration: configuration,
                            metadata: metadata,
                            abortFlag: abortFlag
                        )
                        continuation.resume(returning: LlamaNativeSession(box: box))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            abortFlag.abort()
        }
    }

    private static func loadBoxSync(
        source: LlamaModelSource,
        configuration: LlamaConfiguration,
        metadata: LlamaGGUFMetadata,
        abortFlag: AtomicAbortFlag
    ) throws -> LlamaContextBox {
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = configuration.gpuLayerCount
        #endif
        modelParams.load_mode = (configuration.useMemoryMap && llama_supports_mmap())
            ? LLAMA_LOAD_MODE_MMAP
            : LLAMA_LOAD_MODE_NONE
        modelParams.progress_callback = llamaLoadProgressCallback
        modelParams.progress_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()

        let loadedModel = try loadOpaqueModel(source: source, params: modelParams)
        if abortFlag.isAborted {
            if let loadedModel { llama_model_free(loadedModel) }
            throw CancellationError()
        }

        guard let model = loadedModel else {
            throw LlamaProviderError.modelLoadFailed("llama_model_load_from_file returned null for \(source.identifier).")
        }

        let trainedCtx = Int(llama_model_n_ctx_train(model))
        let effectiveCtx = trainedCtx > 0
            ? min(configuration.contextLength, trainedCtx)
            : max(configuration.contextLength, metadata.contextLength ?? configuration.contextLength)
        let effectiveBatch = min(configuration.batchSize, max(1, effectiveCtx))

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(effectiveCtx)
        ctxParams.n_batch = UInt32(effectiveBatch)
        ctxParams.n_ubatch = UInt32(effectiveBatch)
        let threadCount = Int32(configuration.threadCount ?? max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        ctxParams.n_threads = threadCount
        ctxParams.n_threads_batch = threadCount
        ctxParams.no_perf = true
        if let flash = configuration.useFlashAttention {
            ctxParams.flash_attn_type = flash ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED
        } else {
            ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        }

        let boxAbort = AtomicAbortFlag()
        ctxParams.abort_callback = llamaAbortCallback
        ctxParams.abort_callback_data = Unmanaged.passUnretained(boxAbort).toOpaque()

        guard let context = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw LlamaProviderError.contextCreationFailed("llama_init_from_model returned null.")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw LlamaProviderError.contextCreationFailed("llama_model_get_vocab returned null.")
        }
        guard let batch = llama_batch_ext_init(context) else {
            llama_free(context)
            llama_model_free(model)
            throw LlamaProviderError.contextCreationFailed("llama_batch_ext_init returned null.")
        }

        return LlamaContextBox(
            model: model,
            context: context,
            vocab: vocab,
            batch: batch,
            effectiveContextLength: effectiveCtx,
            abortFlag: boxAbort
        )
    }

    private static func loadOpaqueModel(
        source: LlamaModelSource,
        params: llama_model_params
    ) throws -> OpaquePointer? {
        switch source {
        case .localFile(let url):
            return url.path.withCString { pathPtr in
                llama_model_load_from_file(pathPtr, params)
            }
        case .splitLocalFiles(let urls):
            let ownedPaths = urls.compactMap { strdup($0.path) }
            defer {
                for ptr in ownedPaths {
                    free(ptr)
                }
            }
            guard ownedPaths.count == urls.count else {
                throw LlamaProviderError.modelLoadFailed("Failed to allocate path buffers for split GGUF files.")
            }
            var constPointers: [UnsafePointer<CChar>?] = ownedPaths.map { UnsafePointer($0) }
            return llama_model_load_from_splits(&constPointers, constPointers.count, params)
        }
    }
}

#else

struct LlamaNativeBackend: LlamaBackendDriver {
    func loadSession(
        source: LlamaModelSource,
        configuration: LlamaConfiguration,
        metadata: LlamaGGUFMetadata
    ) async throws -> any LlamaLoadedSession {
        throw LlamaProviderError.unavailableOnPlatform
    }
}

#endif
