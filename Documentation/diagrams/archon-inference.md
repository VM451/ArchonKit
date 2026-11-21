# ArchonInference — how it works

`ArchonInference` is an optional on-device inference product with exactly two
runtime choices behind `ArchonInference.makeProvider(...)`: Apple Core AI
first, then [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
(`LlamaFramework`). It is excluded from `ArchonFull` so applications opt in
explicitly.

```mermaid
flowchart TD
    Host[Host app / ArchonAgent Graph] --> Select[ArchonInference.makeProvider]
    Select --> CoreAIGate{Core AI asset supplied<br/>and device supports Core AI?}
    CoreAIGate -->|yes| Validate[File URL, context &<br/>peak-memory budget gates]
    Validate --> Eager[CoreAILanguageModel<br/>resourcesAt: .eager]
    Eager --> FMRuntime[FoundationModelsRuntime<br/>explicit LanguageModel]
    FMRuntime --> FMProvider[AppleFoundationModelProvider]
    CoreAIGate -->|no| GGUF{GGUF URL supplied<br/>and llama slice present?}
    GGUF -->|yes| Provider[LlamaLocalProvider]
    GGUF -->|no| Fail[InferenceSelectionError<br/>.noAvailableBackend]
    Provider --> Guard[Request, Symlink & GGUF Header Guard]
    Guard --> Budget[DeviceHardwareProfile Peak-Memory Gate]
    Budget --> Coord[LlamaSessionCoordinator actor]
    Coord --> Native[LlamaNativeSession / dedicated serial DispatchQueue]
    Native --> XCF[LlamaFramework XCFramework — Metal / CPU]
    Manager[LlamaModelManager / LlamaModelRuntimeAdapter] --> Provider
```

Core AI preparation errors propagate instead of silently falling back to GGUF.
No `llama` C pointer or C struct enters ArchonKit's public Swift API, and no
weights are downloaded by either path. Model memory budgets, symlink checks,
and GGUF header validation execute before weight allocation.
