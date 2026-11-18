import Foundation
import ArchonAgent
import ArchonCore

#if canImport(llama)
import llama

enum LlamaNativeGeneration {
    static func run(
        box: LlamaContextBox,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions,
        configuration: LlamaConfiguration,
        onEvent: (LlamaStreamTokenEvent) -> Void
    ) throws {
        if box.abortFlag.isAborted { throw CancellationError() }

        let formattedPrompt = LlamaNativePrompting.formatPrompt(
            model: box.model,
            prompt: prompt,
            tools: tools,
            templateOverride: configuration.chatTemplateOverride
        )
        let promptTokens = try LlamaNativePrompting.tokenize(text: formattedPrompt, vocab: box.vocab)
        let nCtx = Int(llama_n_ctx(box.context))
        guard promptTokens.count < nCtx else {
            throw LlamaProviderError.contextWindowExceeded(promptTokens.count, nCtx)
        }

        if let memory = llama_get_memory(box.context) {
            llama_memory_clear(memory, true)
        }

        let sampler = try LlamaNativePrompting.buildSamplerChain(
            vocab: box.vocab,
            options: options,
            configuration: configuration
        )
        defer { llama_sampler_free(sampler) }

        var position: Int32 = 0
        try evaluatePromptTokens(promptTokens, box: box, position: &position)

        let availableRoom = max(1, nCtx - promptTokens.count)
        let maxCompletion = min(options.maxTokens ?? 4096, availableRoom)
        var utf8Decoder = LlamaUTF8PieceDecoder()
        var stopFilter = LlamaStopSequenceFilter(stopSequences: options.stopSequences)
        var completionTokens = 0
        var hitEOG = false
        var pieceBuffer = [CChar](repeating: 0, count: 256)

        for _ in 0..<maxCompletion {
            if box.abortFlag.isAborted { throw CancellationError() }

            let token = llama_sampler_sample(sampler, box.context, -1)
            if llama_vocab_is_eog(box.vocab, token) {
                hitEOG = true
                break
            }
            completionTokens += 1

            let pieceBytes = LlamaNativePrompting.tokenPieceBytes(
                token: token,
                vocab: box.vocab,
                scratchBuffer: &pieceBuffer
            )
            let decodedText = utf8Decoder.append(pieceBytes)
            if !decodedText.isEmpty {
                let safeDelta = stopFilter.push(decodedText)
                if !safeDelta.isEmpty {
                    onEvent(.textDelta(safeDelta))
                }
                if stopFilter.didMatchStopSequence {
                    break
                }
            }

            if completionTokens >= maxCompletion {
                break
            }

            try decodeSingleToken(token, box: box, position: &position)
        }

        let trailingUTF8 = utf8Decoder.flush()
        if !trailingUTF8.isEmpty && !stopFilter.didMatchStopSequence {
            let safeDelta = stopFilter.push(trailingUTF8)
            if !safeDelta.isEmpty {
                onEvent(.textDelta(safeDelta))
            }
        }
        let remainder = stopFilter.flush()
        if !remainder.isEmpty {
            onEvent(.textDelta(remainder))
        }

        onEvent(.completed(
            promptTokens: promptTokens.count,
            completionTokens: completionTokens,
            hitEOG: hitEOG || stopFilter.didMatchStopSequence
        ))
    }

    private static func evaluatePromptTokens(
        _ promptTokens: [llama_token],
        box: LlamaContextBox,
        position: inout Int32
    ) throws {
        let batchCapacity = max(1, Int(llama_n_batch(box.context)))
        var offset = 0
        while offset < promptTokens.count {
            if box.abortFlag.isAborted { throw CancellationError() }
            let end = min(offset + batchCapacity, promptTokens.count)
            llama_batch_ext_clear(box.batch)
            for idx in offset..<end {
                let batchIndex = llama_batch_ext_add_token(box.batch, 0, promptTokens[idx])
                guard batchIndex >= 0 else {
                    throw LlamaProviderError.decodeFailed(batchIndex)
                }
                var pos = position
                _ = llama_batch_ext_set_pos(box.batch, batchIndex, &pos)
                if idx == promptTokens.count - 1 {
                    _ = llama_batch_ext_set_output_logits(box.batch, batchIndex, true)
                }
                position += 1
            }
            let rc = llama_process(box.context, LLAMA_PROCESS_TYPE_DECODE, box.batch)
            if box.abortFlag.isAborted { throw CancellationError() }
            guard rc == 0 else {
                throw LlamaProviderError.decodeFailed(rc)
            }
            offset = end
        }
    }

    private static func decodeSingleToken(
        _ token: llama_token,
        box: LlamaContextBox,
        position: inout Int32
    ) throws {
        llama_batch_ext_clear(box.batch)
        let batchIndex = llama_batch_ext_add_token(box.batch, 0, token)
        guard batchIndex >= 0 else {
            throw LlamaProviderError.decodeFailed(batchIndex)
        }
        var pos = position
        _ = llama_batch_ext_set_pos(box.batch, batchIndex, &pos)
        _ = llama_batch_ext_set_output_logits(box.batch, batchIndex, true)
        position += 1

        let rc = llama_process(box.context, LLAMA_PROCESS_TYPE_DECODE, box.batch)
        if box.abortFlag.isAborted { throw CancellationError() }
        guard rc == 0 else {
            throw LlamaProviderError.decodeFailed(rc)
        }
    }
}

#endif
