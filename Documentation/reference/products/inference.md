# ArchonInference

`ArchonInference` is an optional on-device inference product with exactly two
runtime choices, selected explicitly by the host through
`ArchonInference.makeProvider(...)`:

1. **Apple Core AI first** — an exported Core AI model bundle supplied as an
   `ArchonInference.CoreAIModel` (directory, context limit, predicted peak
   memory). The asset is validated against the device memory budget, loaded
   eagerly via Apple's
   [`CoreAILanguageModel`](https://github.com/apple/coreai-models)
   (`CoreAILM` `1.0.0`, macOS/iOS 27+), and served through
   `FoundationModelsRuntime` + `AppleFoundationModelProvider`.
2. **llama.cpp second** — a local GGUF file served by `LlamaLocalProvider`
   ([ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp),
   `LlamaFramework` XCFramework release `b12492`, MIT license).

Core AI is preferred whenever a Core AI asset is supplied and the device
supports it; llama.cpp is used only when Core AI is unavailable or no Core AI
asset was supplied. Native preparation errors propagate — a supplied but
invalid Core AI model never silently falls back to GGUF. If neither backend
can be selected, `makeProvider` throws
`InferenceSelectionError.noAvailableBackend`. Neither path downloads weights,
uses a cloud provider, or implicitly selects the Apple Intelligence system
model. Both runtimes use ArchonKit's `LLMProvider` contract. The GGUF path
also offers a `ModelRuntimeAdapter`. `ArchonFull` stays unchanged.

## Decision and partial-rebuild boundary

`ArchonInference` applies ArchonKit's **PARTIAL / ADAPT** posture:

- **Apple Core AI (`CoreAILM`)**: Uses Apple's official `coreai-models` 1.0.0
  package for the `CoreAILanguageModels` target, which adapts exported Core AI
  assets onto the Foundation Models `LanguageModel` protocol.
- **Adapted upstream binary (`LlamaFramework`)**: Uses the official
  `llama-b12492-xcframework.zip` release artifact verified by SHA-256 checksum,
  providing embedded Metal kernels and Accelerate/BLAS CPU execution without
  rebuilding C++ sources in SwiftPM.
- **Rebuilt ArchonKit Swift layer**: Implements Swift 6 strict-concurrency actor
  isolation, a pure-Swift zero-weight-allocation GGUF v2/v3 header parser
  (`LlamaGGUFInspector`), device peak-memory budget gating, symlink/path-safety
  validation, incremental UTF-8 multi-byte decoding, streaming stop-sequence
  filtering, GBNF JSON grammar constraints (`options.responseFormatJSON`), tool
  call schema injection and extraction, cooperative task cancellation wired into
  `ggml_abort_callback`, and multi-model memory-pressure management
  (`LlamaModelManager`).

No `llama.h` or `gguf.h` C symbols enter `ArchonInference`'s public Swift API.

## Platform slice support

The `CoreAILM` product is linked only on macOS and iOS (`.when(platforms:
[.macOS, .iOS])`); `ArchonInference.isCoreAIAvailable` additionally requires a
non-simulator ARM device running OS 27 or newer.

Upstream `llama-b12492-xcframework.zip` ships binary slices for:

- `macos-arm64_x86_64` (macOS 27+)
- `ios-arm64` (physical iOS devices)

On targets without either backend (such as visionOS), `makeProvider` throws
`InferenceSelectionError.noAvailableBackend`. A direct `LlamaLocalProvider`
call cannot run without a linked llama.cpp slice. Building `ArchonInference`
for iOS Simulator requires a llama.cpp XCFramework with an `ios-sim` slice;
Core AI selection is disabled in the simulator. `ArchonFull` does not link
either inference backend.

## Usage

Add `ArchonInference` to the host target. Supply a Core AI export directory
containing the `.aimodel`, tokenizer, and configuration files, or a local
GGUF file. See [Apple's export and loading guide](https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session)
for Core AI asset preparation.

```swift
import ArchonAgent
import ArchonInference

let provider = try await ArchonInference.makeProvider(
    coreAIModel: .init(
        directory: exportedCoreAIModelDirectory,
        maxContextTokens: modelContextLimit,
        predictedPeakMemoryBytes: estimatedPeakBytes
    ),
    ggufModelURL: localGGUFURL
)

let response = try await provider.generate(
    prompt: [.user("Summarize local-first AI boundaries.")],
    tools: [],
    options: GenerationOptions(temperature: 0.2, maxTokens: 256)
)
```

`coreAIModel` and `ggufModelURL` are both optional; pass only the assets the
device should consider. The Core AI path reports text-only capabilities (no
tool calling, JSON schema, vision, top-p, or custom stop sequences through this
scoped adapter). The llama.cpp path keeps its full `LlamaLocalProvider`
contract. For multi-model lifecycle management and memory pressure unloading
on the GGUF side, use `LlamaModelManager`; for `ArchonModels.ModelRuntimeAdapter`
integration over explicit GGUF packages, use `LlamaModelRuntimeAdapter`.

## Still not default: open gates

`ArchonInference` remains an explicit opt-in product excluded from `ArchonFull`.
macOS package tests cover provider selection, the Core AI missing-memory-estimate
guard, GGUF binary header inspection (including interop with
`ggml`'s native C writer), request validation, tool-call and JSON-schema
handling, streaming cancellation, `ZeroCloudMode` compliance, and
`LlamaFramework` symbol linkage. Real-weight generation on either runtime,
physical-device thermal behavior, and signed-app memory measurements remain
consuming-app acceptance gates under
[validate a release](../../how-to/validate-a-release.md).
