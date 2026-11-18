import Foundation

/// A validated local model source for llama.cpp GGUF execution.
public enum LlamaModelSource: Sendable, Equatable, Hashable {
    /// A single GGUF file stored locally on disk.
    case localFile(URL)

    /// Ordered GGUF shards stored locally on disk (for split multi-part models).
    case splitLocalFiles([URL])

    /// All file URLs backing this source in load order.
    public var fileURLs: [URL] {
        switch self {
        case .localFile(let url):
            return [url]
        case .splitLocalFiles(let urls):
            return urls
        }
    }

    /// The primary GGUF file URL carrying model metadata.
    public var primaryURL: URL? {
        fileURLs.first
    }

    /// Stable identifier for provider identity and caching.
    public var identifier: String {
        switch self {
        case .localFile(let url):
            return url.path
        case .splitLocalFiles(let urls):
            if let first = urls.first {
                return "\(first.path)#shards(\(urls.count))"
            }
            return "empty-split"
        }
    }
}
