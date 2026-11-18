import Foundation
import ArchonAgent
import ArchonCore

#if canImport(llama)
import llama

enum LlamaNativePrompting {
    static func formatPrompt(
        model: OpaquePointer,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        templateOverride: String?
    ) -> String {
        let normalized = LlamaChatFormatting.normalizedMessages(from: prompt, tools: tools)
        let templatePtr: UnsafePointer<CChar>? = templateOverride.flatMap { strdup($0).map { UnsafePointer($0) } }
            ?? llama_model_chat_template(model, nil)
        let ownsTemplateCopy = templateOverride != nil
        defer {
            if ownsTemplateCopy, let templatePtr {
                free(UnsafeMutablePointer(mutating: templatePtr))
            }
        }

        guard let templatePtr else {
            return LlamaChatFormatting.formatChatML(normalized)
        }

        var cMessages: [llama_chat_message] = []
        var ownedStrings: [UnsafeMutablePointer<CChar>] = []
        cMessages.reserveCapacity(normalized.count)
        ownedStrings.reserveCapacity(normalized.count * 2)
        defer {
            for ptr in ownedStrings {
                free(ptr)
            }
        }

        for msg in normalized {
            guard let rolePtr = strdup(msg.role), let contentPtr = strdup(msg.content) else {
                return LlamaChatFormatting.formatChatML(normalized)
            }
            ownedStrings.append(rolePtr)
            ownedStrings.append(contentPtr)
            cMessages.append(llama_chat_message(role: rolePtr, content: contentPtr))
        }

        let estimatedChars = normalized.reduce(0) { $0 + $1.content.utf8.count + $1.role.utf8.count + 32 }
        var outputBuffer = [CChar](repeating: 0, count: max(2048, estimatedChars * 2))
        var requiredLength = llama_chat_apply_template(
            templatePtr,
            &cMessages,
            cMessages.count,
            true,
            &outputBuffer,
            Int32(outputBuffer.count)
        )
        if requiredLength < 0 {
            return LlamaChatFormatting.formatChatML(normalized)
        }
        if Int(requiredLength) >= outputBuffer.count {
            outputBuffer = [CChar](repeating: 0, count: Int(requiredLength) + 1)
            requiredLength = llama_chat_apply_template(
                templatePtr,
                &cMessages,
                cMessages.count,
                true,
                &outputBuffer,
                Int32(outputBuffer.count)
            )
            if requiredLength < 0 || Int(requiredLength) >= outputBuffer.count {
                return LlamaChatFormatting.formatChatML(normalized)
            }
        }
        return String(decoding: outputBuffer[0..<Int(requiredLength)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func tokenize(text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        var capacity = max(64, utf8Count + 16)
        var tokens = [llama_token](repeating: 0, count: capacity)
        var count = text.withCString { cStr in
            llama_tokenize(vocab, cStr, Int32(utf8Count), &tokens, Int32(capacity), true, true)
        }
        if count == Int32.min {
            throw LlamaProviderError.tokenizationFailed("Prompt exceeds maximum token buffer size.")
        }
        if count < 0 {
            capacity = Int(-count) + 8
            tokens = [llama_token](repeating: 0, count: capacity)
            count = text.withCString { cStr in
                llama_tokenize(vocab, cStr, Int32(utf8Count), &tokens, Int32(capacity), true, true)
            }
        }
        guard count > 0 else {
            throw LlamaProviderError.tokenizationFailed("Tokenization produced zero tokens.")
        }
        return Array(tokens[0..<Int(count)])
    }

    static func buildSamplerChain(
        vocab: OpaquePointer,
        options: GenerationOptions,
        configuration: LlamaConfiguration
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        let chainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(chainParams) else {
            throw LlamaProviderError.contextCreationFailed("Failed to create llama sampler chain.")
        }

        let grammarString: String?
        if let custom = configuration.customGBNFGrammar {
            grammarString = custom
        } else if configuration.jsonGrammarEnabled && options.responseFormatJSON {
            grammarString = LlamaChatFormatting.jsonObjectGBNF
        } else {
            grammarString = nil
        }

        if let grammarString {
            guard let grammarSampler = grammarString.withCString({ gStr in
                "root".withCString { rStr in
                    llama_sampler_init_grammar(vocab, gStr, rStr)
                }
            }) else {
                llama_sampler_free(chain)
                throw LlamaProviderError.grammarInitializationFailed
            }
            llama_sampler_chain_add(chain, grammarSampler)
        }

        let rawTemp = options.temperature ?? 0.7
        let temp = Float(rawTemp.isFinite ? max(0.0, rawTemp) : 0.7)
        let rawTopP = options.topP ?? 1.0
        let topP = Float(rawTopP.isFinite ? min(1.0, max(0.0, rawTopP)) : 1.0)

        if configuration.topK > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(configuration.topK))
        }
        if topP < 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        }
        if configuration.minP > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(configuration.minP, 1))
        }
        if configuration.repeatPenalty != 1.0 && configuration.repeatLastN > 0 {
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_penalties(
                    llama_vocab_n_tokens(vocab),
                    configuration.repeatLastN,
                    configuration.repeatPenalty,
                    0.0,
                    0.0
                )
            )
        }

        if temp <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temp))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(configuration.seed ?? 0xFFFF_FFFF))
        }

        return chain
    }

    static func tokenPieceBytes(
        token: llama_token,
        vocab: OpaquePointer,
        scratchBuffer: inout [CChar]
    ) -> [UInt8] {
        var length = llama_token_to_piece(vocab, token, &scratchBuffer, Int32(scratchBuffer.count), 0, false)
        if length < 0 {
            let needed = Int(-length)
            scratchBuffer = [CChar](repeating: 0, count: needed)
            length = llama_token_to_piece(vocab, token, &scratchBuffer, Int32(scratchBuffer.count), 0, false)
        }
        guard length > 0 else { return [] }
        return scratchBuffer[0..<Int(length)].map { UInt8(bitPattern: $0) }
    }
}

#endif
