# ArchonInference

`ArchonInference` is an optional local GGUF inference product powered by
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) (`LlamaFramework`
XCFramework, release `b12492`, MIT license). It wraps the upstream C/C++/Metal
runtime behind ArchonKit's vendor-neutral `LLMProvider` and
`ModelRuntimeAdapter` contracts while keeping `ArchonFull` and the core MLX/Core
AI boundaries untouched.

## Decision and partial-rebuild boundary

`ArchonInference` applies ArchonKit's **PARTIAL / ADAPT** posture:

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

Upstream `llama-b12492-xcframework.zip` ships binary slices for:

- `macos-arm64_x86_64` (macOS 27+)
- `ios-arm64` (physical iOS devices)

On platforms without an upstream slice in `LlamaFramework` (such as `visionOS`),
`ArchonInference` compiles via `#if canImport(llama)` and fails closed with
`LlamaProviderError.unavailableOnPlatform`. Simulator builds of `ArchonInference`
itself require an XCFramework built with `./build-xcframework.sh` including
`ios-sim`; because `ArchonInference` is excluded from `ArchonFull`, all base
products continue to build across iOS Simulator and visionOS without requiring
simulator slices.

## Usage

```swift
import ArchonAgent
import ArchonInference

let provider = LlamaLocalProvider(
    modelURL: localGGUFURL,
    configuration: .standard
)

let response = try await provider.generate(
    prompt: [.user("Summarize local-first AI boundaries.")],
    tools: [],
    options: GenerationOptions(temperature: 0.2, maxTokens: 256)
)
```

For multi-model lifecycle management and memory pressure unloading, use
`LlamaModelManager`. For `ArchonModels.ModelRuntimeAdapter` integration over
explicit GGUF packages, use `LlamaModelRuntimeAdapter`.

## Still not default: open gates

`ArchonInference` remains an explicit opt-in product excluded from `ArchonFull`.
Package tests prove GGUF binary header inspection (including interop with
`ggml`'s native C writer), memory-budget gating, request validation, tool-call
and JSON-schema handling, streaming cancellation, `ZeroCloudMode` compliance, and
`LlamaFramework` symbol linkage. Physical-device thermal, real-GGUF latency, and
signed-app memory measurements remain consuming-app acceptance gates under
[validate a release](../../how-to/validate-a-release.md).
