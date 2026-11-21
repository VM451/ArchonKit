# Changelog

## Unreleased

### Added

- AI / LLM context quality for `ArchonSearchClient.ask`: parallel page fetch,
  `PassageChunker` (query-scored paragraph chunking with a 0.7 relevance
  threshold and best-passage fail-safe), `AIContextPacker` (token-budget
  packing with `ContextQualityStats` and an extractive `directAnswer`),
  `SearchHostAuthority` (deterministic 0...1 domain weights), and date
  grounding (`lastModified`/`effectiveDate` on results, sources, citations).
- Shared HTTPS and resolved-address network policy with fail-closed defaults.
- Optional [`ArchonInference`](Documentation/reference/products/inference.md)
  selects Apple Core AI for exported models first and llama.cpp for local GGUF
  second. Both use `LLMProvider`; GGUF also offers a `ModelRuntimeAdapter`
  with header inspection, memory gating, GBNF JSON constraints, streaming
  cancellation, and memory-pressure management.
- CI checks for package builds, Swift Testing, product scope, dependency-license
  evidence, scorecard structure, and whitespace.
- Resource and request-size limits for model catalogs, agent tools, providers,
  and local vector memory.

### Changed

- Package renamed from Archon (archon-swift) to ArchonKit. Update the SwiftPM
  dependency URL to https://github.com/VM451/ArchonKit.git; product names
  (`ArchonCore`, `ArchonModels`, …) are unchanged.
- Graph builders are single-owner, require an explicit entry point, validate
  references before compilation, and install reducers synchronously.
- Tool effect ledgers reserve call IDs atomically and replay completed effects
  safely under retries.
- Cloud provider capabilities now report non-streaming behavior until native
  incremental transport is implemented; provider credentials are no longer
  publicly readable.
- Model replacement restores the previous resident set on a failed load, and
  background model installs use atomic replacement.

### Migration notes

- `GraphBuilder.compile()` is now throwing. Handle `GraphError.invalidGraph` and
  provide an explicit `setEntryPoint(...)`.
- Custom `ToolEffectLedger` implementations must adopt
  `reserve(callID:toolName:)`, `record(_:)`, and `release(callID:)`.

The MLX Swift, MLX LM, Hugging Face, and Transformers dependencies intentionally
remain in `ArchonAgent` so local-agent functionality is ready out of the box.
