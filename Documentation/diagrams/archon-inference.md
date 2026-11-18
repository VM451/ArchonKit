# ArchonInference — how it works

`ArchonInference` is an optional local GGUF inference adapter that wraps
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) (`LlamaFramework`)
behind `ArchonAgent`'s `LLMProvider` and `ArchonModels`'s `ModelRuntimeAdapter`.
It is excluded from `ArchonFull` so applications opt in explicitly.

```mermaid
flowchart TD
    Host[Host app / ArchonAgent Graph] --> Provider[LlamaLocalProvider]
    Provider --> Guard[Request, Symlink & GGUF Header Guard]
    Guard --> Budget[DeviceHardwareProfile Peak-Memory Gate]
    Budget --> Coord[LlamaSessionCoordinator actor]
    Coord --> Native[LlamaNativeSession / dedicated serial DispatchQueue]
    Native --> XCF[LlamaFramework XCFramework — Metal / CPU]
    Manager[LlamaModelManager / LlamaModelRuntimeAdapter] --> Provider
```

No `llama` C pointer or C struct enters ArchonKit's public Swift API. Model
memory budgets, symlink checks, and GGUF header validation execute before weight
allocation.
