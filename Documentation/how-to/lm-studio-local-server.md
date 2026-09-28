# Serve a macOS app from a local LM Studio server

This guide wires a macOS app to models running in [LM Studio](https://lmstudio.ai)
through `ArchonAgent.LMStudioProvider`. LM Studio hosts the model and its
OpenAI-compatible server on the Mac; Archon supplies the typed graph,
provider routing, tools, and lifecycle around it.

## 1. Start the server in LM Studio

1. Load a model in LM Studio.
2. Open the server view and start the server (default `http://localhost:1234/v1`).
3. Note the exact model identifier shown for the loaded model.

No API key is needed unless the server settings define one. The provider,
the model weights, and server lifecycle stay entirely in LM Studio; Archon
never launches, downloads, or manages them.

## 2. Resolve the provider

```swift
import ArchonAgent

let provider = ArchonAI.lmStudio(model: "qwen3-8b")
// Equivalent explicit form:
// let provider = ArchonAI.model(.lmStudio(model: "qwen3-8b"))
```

`model` must name the model loaded in LM Studio; `"local-model"` is only a
placeholder default. A changed port or host takes a custom root:

```swift
let provider = ArchonAI.lmStudio(
    model: "qwen3-8b",
    baseURL: URL(string: "http://localhost:1235/v1")!
)
```

If the server sets an API key, pass it as `apiKey` from the app's own
credential storage. Keys are never stored by the provider.

## 3. Generate against it

```swift
let response = try await provider.generate(
    prompt: [.user("Summarize local-first inference.")],
    tools: [],
    options: GenerationOptions()
)
```

Pass the same provider into graph nodes, agent tools, or a
`RealtimeSession` model path anywhere an `any LLMProvider` is accepted.

Streaming uses the same OpenAI-compatible SSE transport as the cloud
adapters, so `provider.stream(prompt:tools:options:)` works unchanged.

## 4. Know the capability baseline

`LMStudioProvider` reports a local baseline (on-device, streaming transport,
tool passthrough), not a per-model promise. Tool calling, vision, JSON
schema, and context length depend on the model loaded in LM Studio. When the
app serves a known model, narrow the contract explicitly:

```swift
let provider = LMStudioProvider(
    model: "qwen3-8b",
    capabilities: .mlxLocal
)
```

The provider never participates in user-facing catalog discovery or adaptive
on-device routing: a localhost server is an explicit host integration, not
an in-process runtime or a catalogued artifact.

## 5. Keep ZeroCloud honest

`ZeroCloudMode` still permits loopback LM Studio endpoints and fails closed
on anything else before any request is built, so a custom `baseURL` cannot
turn the local path into arbitrary network egress:

```swift
// Throws GraphError.zeroCloudViolation under ZeroCloudMode:
let lan = ArchonAI.lmStudio(
    model: "qwen3-8b",
    baseURL: URL(string: "http://192.168.1.5:1234/v1")!
)
```

## 6. macOS host checklist

These stay in the consuming application; the package cannot grant them:

- Outgoing-connections sandbox entitlement for the app target, so it may
  reach the loopback server.
- A local-networking App Transport Security allowance for the plain-`http`
  loopback URL (verify the current ATS keys for the deployment target).
- Privacy Descriptions only if the app itself captures microphone, camera,
  or screen input for realtime sessions; plain text inference needs none.
- Live inference against the local server is a consuming-app gate: prove it
  in the signed app, not from package tests, which cover endpoints, request
  shape, factory wiring, and ZeroCloud behavior with stubbed transport only.
