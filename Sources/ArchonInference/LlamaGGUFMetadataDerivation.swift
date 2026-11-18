import Foundation

/// Quantization lookup and KV-cache sizing helpers derived from GGUF metadata headers.
enum LlamaGGUFMetadataDerivation {
    static func deriveKVCacheBytesPerToken(
        blockCount: Int?,
        attentionHeadCount: Int?,
        attentionHeadCountKV: Int?,
        embeddingLength: Int?,
        keyLength: Int?,
        valueLength: Int?
    ) -> UInt64? {
        guard let blocks = blockCount, blocks > 0,
              let kvHeads = attentionHeadCountKV ?? attentionHeadCount, kvHeads > 0 else {
            return nil
        }

        let kDim: Int
        let vDim: Int
        if let keyLength, keyLength > 0, let valueLength, valueLength > 0 {
            kDim = keyLength
            vDim = valueLength
        } else if let embd = embeddingLength, embd > 0,
                  let heads = attentionHeadCount, heads > 0 {
            let headDim = max(1, embd / heads)
            kDim = headDim
            vDim = headDim
        } else {
            return nil
        }

        // Default GGUF KV cache element size is FP16 (2 bytes) for both K and V.
        let (dimSum, ov1) = UInt64(kDim).addingReportingOverflow(UInt64(vDim))
        guard !ov1 else { return nil }
        let (perLayer, ov2) = dimSum.multipliedReportingOverflow(by: UInt64(kvHeads) * 2)
        guard !ov2 else { return nil }
        let (total, ov3) = perLayer.multipliedReportingOverflow(by: UInt64(blocks))
        guard !ov3 else { return nil }
        return total
    }

    static func quantizationName(forFileType code: UInt32) -> String? {
        switch code {
        case 0: return "F32"
        case 1: return "F16"
        case 2: return "Q4_0"
        case 3: return "Q4_1"
        case 7: return "Q8_0"
        case 8: return "Q5_0"
        case 9: return "Q5_1"
        case 10: return "Q2_K"
        case 11: return "Q3_K_S"
        case 12: return "Q3_K_M"
        case 13: return "Q3_K_L"
        case 14: return "Q4_K_S"
        case 15: return "Q4_K_M"
        case 16: return "Q5_K_S"
        case 17: return "Q5_K_M"
        case 18: return "Q6_K"
        case 19: return "IQ2_XXS"
        case 20: return "IQ2_XS"
        case 21: return "Q2_K_S"
        case 22: return "IQ3_XS"
        case 23: return "IQ3_XXS"
        case 24: return "IQ1_S"
        case 25: return "IQ4_NL"
        case 26: return "IQ3_S"
        case 27: return "IQ3_M"
        case 28: return "IQ2_S"
        case 29: return "IQ2_M"
        case 30: return "IQ4_XS"
        case 31: return "IQ1_M"
        case 32: return "BF16"
        case 36: return "TQ1_0"
        case 37: return "TQ2_0"
        case 38: return "MXFP4_MOE"
        default: return nil
        }
    }
}
