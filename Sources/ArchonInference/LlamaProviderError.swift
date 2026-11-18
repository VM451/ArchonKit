import Foundation

/// Typed failures raised by `ArchonInference`.
public enum LlamaProviderError: Error, LocalizedError, Sendable, Equatable {
    case emptyPrompt
    case invalidOptions(String)
    case invalidConfiguration(String)
    case contextWindowExceeded(Int, Int)
    case invalidModelPath(String)
    case symlinkRejected(String)
    case invalidGGUF(String)
    case memoryEstimateUnavailable
    case insufficientMemory(predictedPeakBytes: UInt64, availableBudgetBytes: UInt64)
    case unavailableOnPlatform
    case modelLoadFailed(String)
    case contextCreationFailed(String)
    case tokenizationFailed(String)
    case decodeFailed(Int32)
    case grammarInitializationFailed
    case modelNotRegistered(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "llama.cpp generation requires at least one non-empty chat message."
        case .invalidOptions(let reason):
            return "llama.cpp generation options are invalid: \(reason)"
        case .invalidConfiguration(let reason):
            return "llama.cpp configuration is invalid: \(reason)"
        case .contextWindowExceeded(let current, let max):
            return "llama.cpp prompt context (\(current) tokens) exceeded limit (\(max) tokens)."
        case .invalidModelPath(let reason):
            return "Invalid GGUF model path: \(reason)"
        case .symlinkRejected(let path):
            return "Symbolic link rejected for GGUF model path: \(path)"
        case .invalidGGUF(let reason):
            return "Invalid GGUF model file: \(reason)"
        case .memoryEstimateUnavailable:
            return "llama.cpp model loading is blocked because no peak-memory estimate could be established."
        case .insufficientMemory(let predictedPeakBytes, let availableBudgetBytes):
            return "llama.cpp model loading is blocked: predicted peak memory \(predictedPeakBytes) bytes exceeds the current safe model budget of \(availableBudgetBytes) bytes."
        case .unavailableOnPlatform:
            return "The llama.cpp native runtime is unavailable on this platform or target slice."
        case .modelLoadFailed(let reason):
            return "llama.cpp failed to load GGUF model: \(reason)"
        case .contextCreationFailed(let reason):
            return "llama.cpp failed to initialize inference context: \(reason)"
        case .tokenizationFailed(let reason):
            return "llama.cpp failed to tokenize prompt: \(reason)"
        case .decodeFailed(let code):
            return "llama.cpp token evaluation failed with status \(code)."
        case .grammarInitializationFailed:
            return "llama.cpp failed to compile the requested GBNF grammar."
        case .modelNotRegistered(let id):
            return "No GGUF model is registered under identifier '\(id)'."
        }
    }
}
