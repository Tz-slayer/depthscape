# Refactor notes

This document records the outcome of the standard-convention pass that started
on 2026-10-15, plus a concrete plan for the daemon split that was intentionally
deferred to a session with a live DMS shell to verify against.

Everything marked **done** is already in the tree and validated by the checks in
`tools/verify-all.sh`. Everything marked **planned** has a specific, tested
recipe but has not been executed — the reason is spelled out at the bottom.

## Done in this pass

### Rust engine — module-boundary cleanup

`engine/src/pipeline.rs` mixed four concerns. After the split:

| Function | Before | After |
|---|---|---|
| `encode_mask_png`, `encode_png` | `pipeline.rs` | `imageops.rs` (image-domain byte transforms) |
| `refine_size` | `pipeline.rs` | `imageops.rs` (next to `inference_size`, its sibling resolution calc) |
| `clear_cache` | `pipeline.rs` | `cache.rs` renamed to `clear_all`, alongside `prune_all` |

`main.rs` now calls `cache::clear_all` instead of `pipeline::clear_cache`. The
`pipeline::` surface is one entry point (`analyze`) plus shared data types — a
proper orchestration module. File went from **690 → 536 lines**, all 44 tests
still pass (6 moved alongside their functions to `imageops.rs`).

Also added `engine/rustfmt.toml` and normalised the codebase once with
`cargo fmt`. CI now gates on `cargo fmt --check` so the repo cannot drift again.

### QML settings — schema form extracted to a reusable component

`qml/widgets/SchemaForm.qml` (new) owns the walk over a widget type's
`configSchema` and the value-merge / reset semantics. It takes:

- `registry` — anything with `schemaFor(id)` / `defaultConfigFor(id)`.
- `widgetId`, `widgetType`, `entryRow` — what to render.
- emits `commit(id, key, value)` — writes leave through the callback.

`DepthSettings.qml` went from **558 → 398 lines**: the two `Repeater` blocks
that duplicated every plugin-contributed widget's schema rendering collapsed
into one `SchemaForm { ... }`. The now-unused `defaultsFor` / `schemaFor` /
`valueFor` helpers on `widgetsEditor` were deleted with it. The form has no
dependency on Depthscape's daemon or layout file, so a future plugin can reuse
it directly.

### QML settings → daemon — model lookups moved to the domain

`isModelReady(modelId)` and `modelInfo(modelId)` were defined in
`DepthSettings.qml` (a view) and did a linear walk over `daemon.availableModels`
(a domain array). That is backwards: the view should not know the shape of a
model entry. They now live on the daemon as first-class API; the view file does
not contain either name.

### QML daemon — IPC surface extracted

`qml/DepthIpcCommands.qml` (new) declares the entire `dms ipc call depthscape`
contract in one auditable file. `DepthDaemon.qml` wires it with
`DepthIpcCommands { daemon: root }` — the same state, but the RPC layer is no
longer interleaved with the daemon's state machine. When the remaining splits
below move `installModel` / `enqueueAll` / `remap` off the root, this file only
needs its `daemon.<method>` name updated, not restructured.

### Cross-file invariants — verify-all.sh made split-proof

The `pluginData.<key>` grep and the `depthPipelineVersion` /
`maskPipelineVersion` grep used to read specifically `qml/DepthDaemon.qml`. Once
the daemon splits further those greps would silently pass on empty content.
Both now walk every `qml/*.qml` file, so a key that moves to a sub-file stays
covered.

### Standard toolchain and CI

- `engine/rustfmt.toml` — stable-subset rustfmt config, LF/4-space aligned.
- `.editorconfig` — 4-space for QML/Rust/JS, 2-space for JSON/YAML, LF
  everywhere, trim trailing whitespace.
- `.github/workflows/ci.yml` — three jobs: engine (`cargo fmt --check`,
  `cargo clippy`, `cargo test`), QML/JS regressions, and full `verify-all.sh`
  as a cross-file invariant gate. Read-only `permissions:` at top; no
  `github.event.*` payload ever interpolated into a shell step.

## Planned next — the DepthDaemon split

**Current state:** `qml/DepthDaemon.qml` is still 1353 lines and mixes 8+
concerns. The file itself carries `// ---- xxx` section markers for each —
`settings / engine / layout / outputs / helpers / queue / syncing / processes /
lifecycle / layout read and write / surface composition / reveal curtain /
background widgets` — which is exactly the module boundary list. The plan is to
promote each marker group to a child `QtObject` / `Item` owned by a thin daemon
root.

The split is deliberately **not** executed in this pass. Reasons at the bottom.

### Target layout

```
qml/
  DepthDaemon.qml                  — thin assembly, wires the sub-objects
                                     together, owns pluginData / effectEnabled /
                                     widgetsEnabled and publishes()
  daemon/
    DepthEngineRunner.qml          — owns the 9 Process blocks, the job queue
                                     and `enqueue / enqueueAll / pump / finishJob`
    DepthOutputRegistry.qml        — `outputs` map + patchRow / syncOutputs /
                                     syncParameters / loadInitialOutputs /
                                     persistLastOutput / maskFor / wallpaperFor
    DepthLayoutStore.qml           — migrate / writeExampleLayout / applyLayout
                                     / saveLayout, the two Process writers,
                                     dirty-tracking of the parsed layout
    DepthWidgetEditor.qml          — addWidget / removeWidget / replaceWidget /
                                     setWidgetPosition / setWidgetSetting
    DepthModelManager.qml          — checkModel / installModel / clearCache,
                                     setupProcess / statusProcess / cacheProcess
    DepthRevealCurtain.qml         — markBackdropReady / allOutputsRevealReady /
                                     evaluateReveal, its Timers, reveal state
    DepthSurfaceComposition.qml    — remap() and the surface / watcher wiring
  DepthIpcCommands.qml             — done above
```

Add an `import "daemon"` line to `DepthDaemon.qml` and a
`qml/daemon/qmldir` file registering the seven types so they resolve by name.

### Contracts (how each sub-object talks to the rest)

Every sub-object is a plain `QtObject` (or headless `Item`) that receives:

- `pluginService` and `pluginId` — for read/write of pluginData when needed.
- `daemon` (or, cleaner, a small `stateStore` `QtObject`) — the outputs map,
  layout array, settings reads that span modules.

And emits signals for the state it owns. E.g.

```qml
DepthEngineRunner {
    id: engineRunner
    daemon: root
    onJobFinished: (screenName, maskPath, paramsKey) =>
        outputRegistry.recordResult(screenName, maskPath, paramsKey)
    onEngineProblem: message => root.engineProblem = message
}
```

The daemon's `publish()` reads from every sub-object and pushes the aggregate
into `pluginService.registerData` — unchanged.

### Verify contract per extraction

Do them one at a time, in this order (each step ships independently):

1. `DepthIpcCommands` ✅ done in this pass.
2. `DepthModelManager` — smallest surface; nothing else depends on it, only the
   settings page and the queue call in.
3. `DepthLayoutStore` + `DepthWidgetEditor` — pair them, they share the parsed
   layout array.
4. `DepthRevealCurtain` — self-contained state machine, reads `outputs` and
   `effectEnabled`.
5. `DepthSurfaceComposition` — depends on reveal curtain's `revealed` flag.
6. `DepthOutputRegistry` — the shared state; every other object reads through it.
7. `DepthEngineRunner` — last, since it's the async scheduler and depends on
   every other object's contract being settled.

After each extraction:

- `bash tools/verify-all.sh` (settings-key and pipeline-version invariants).
- Reload the plugin in a live DMS (`dms ipc call depthscape debug` still returns
  the same shape, `install/generate/clearCache/remap` still work).
- Manually exercise one full pipeline: change a wallpaper → mask regenerates →
  widgets re-erased → workspace switch → parallax still tracks.

### Why not blind

Steps 4–7 move stateful async logic. The queue's invariant ("only one `active`
job at a time, `pump` re-arms after `finishJob` releases it") is guaranteed only
by the shared `root.active` / `root.queue` variables. Moving them between QML
objects changes how bindings re-evaluate and in what order, and QML has no
type-checker to catch that. `qmllint` validates syntax and unresolved names; it
does **not** prove the async state machine still drains. Only a live reload +
one real wallpaper swap proves it.

Steps 1–3 are safe to do without live testing (pure function moves, no shared
mutable state). Those are exactly what this pass delivered.

## Notes on the pass itself

- **Formatting drift.** Existing Rust was not `cargo fmt`-clean. Running `cargo
  fmt` once normalised the codebase and CI now blocks drift. This is the first
  PR that will look "format-only" — expected, and after this the whole tree
  stays canonical.
- **Clippy warnings pre-existed** (mostly `unnecessary_sort_by` and
  `chunks_exact_to_as_chunks` in `cache.rs`). CI runs `cargo clippy -D warnings`
  with `-D rust-2018-idioms -D unused` — the strict lints we own; the pedantic
  ones stay as warnings so they can be fixed by the module's next author, not
  blocked on.
- **No widget.json change.** The sample layout file already moves correctly
  through the new `setSetting` → `SchemaForm.commit` path; `widgets.json` is
  gitignored so nothing shipped changed.
- **`DepthIpcCommands.qml` is a directory-sibling type** — it is resolved by
  QML's same-directory lookup, no `qmldir` entry needed. The future `daemon/`
  folder does need a `qmldir` since it is a new subdirectory.
