# ArchonFull

`ArchonFull` is a convenience re-export facade:

```swift
import ArchonFull
```

It re-exports the base ArchonKit products without adding duplicate logic. It
intentionally excludes `ArchonMemoryProxima` and `ArchonInference` and therefore does
not force optional ProximaKit or `LlamaFramework` dependencies.

Use direct product imports when a feature module should make its dependency
graph explicit or avoid heavier integrations. Use `ArchonFull` at an
application composition boundary when the convenience import is valuable.
