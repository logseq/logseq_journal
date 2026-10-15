# Switch Graph Native Picker

## Problem

The graph picker uses uneven capsule buttons and loses the active graph when opened. It has no per-row local-copy management or durable presence observation.

## Decision

Implement the user's selected concept A with native equal-width list rows, a full-canvas List with Timeline-style floating close/refresh/existing account controls, an inline current marker and a separate row menu. Keep picker and request ownership in OCaml. Query one graph's mirror presence on demand with an account-generation fence; cache observations outside rendering.

The user explicitly permits discarding unsynchronized local content after confirmation (Sentinel_3c2ff0ee96f88191ab349fca7f7befe9). The confirmation must explain this loss, device-only deletion and the retained cloud copy. The active graph requires switching first. The user separately approved the minimal existing protected Core contract comment change (Sentinel_752ae13c79888191aeb7123ba1d9fd25). No other protected spec, Dune or lock edit is part of this change.

The user subsequently requested removing the header entirely and making the whole UI a List like Timeline. Reuse the existing floating chrome; retain the native controls and per-row actions without a title bar.

## Alternatives considered

### Reuse the existing graph-picker transition unchanged

It detaches the current graph and clears its identity. Keep an application-owned picker presentation instead, and use the existing Select_graph lifecycle only for an actual switch.

## Validation

- Uniform native rows preserve catalog order, expose the current marker and support long names and Dynamic Type.
- Close returns to the retained current graph; name activation switches through the worker.
- Row menus are independently reachable; current graph deletion is disabled with an explanation.
- Presence is bounded and requested only for the relevant graph, with stale and cancelled results ignored.
- Confirmation names the graph, warns that unsynchronized changes/drafts/attachments will be lost and says the cloud copy remains downloadable.
- Two native XCTest cases pass on the isolated iPhone 13 / iOS 26.1 Simulator: actual menu and row taps, cancellation, current-graph protection, ownership-busy failure and retry, retained Not downloaded rows, real-worker snapshot redownload through a controlled loopback TLS fixture, close/session retention and accessibility XXXL scrolling/menu reachability. The fixture does not implement a live remote sync service.
- Real UI submission also produced an unsent text capture and photo attachment; inspection found three durable outbox records and one account/graph-specific upload intent before confirmed local deletion removed that copy and its intent.
- Application regression: 98 tests pass, including deletion-in-flight Capture and composer retention. Sync and overlay storage suites pass 261 and 50 cases respectively; worker service, startup, semantics and source-boundary checks pass.
- Independent read-only journal-code-review found and prompted fixes for action gating and confirmation identity; the code-fix commit was re-reviewed with no remaining evidenced findings. All temporary reports, builds, hosts, network fixtures and screenshots remain outside Git.

## Risks

- Presence can be unknown or fail; expose a clear retry/status rather than assuming a downloaded copy.
- Host ARM64 OCaml restamping is an experimental Simulator compatibility path; actual runtime acceptance does not establish full iOS cross-compilation or ABI validity.

## Consequences

Presence observations are cached by account and invalidated for a graph lifecycle change. Native row controls stay mounted while property signals update text and enabled state: real Simulator testing showed that replacing interactive subtrees could leave the retained List cell with an obsolete callback binding. Headless final-state assertions alone did not reproduce that native retention boundary, so the acceptance check is the real Simulator flow.

Deletion uses a single account-scoped flight and exact terminal result. It preserves the selected graph and catalog, validates persisted local ownership, cancels target work, waits for native leases, and revalidates before mirror removal under the existing exclusive ownership primitive. Unsynchronized local content is intentionally discarded after the warning. Unbound legacy mirrors require opening once and switching away before removal.

The active graph remains usable when the picker closes during deletion of another graph. Application owns the manager snapshot and action gate; the public Root_navigation reducer does not own either, so its events cannot reproduce that guard. A regression at the public mounted Application boundary holds deletion in flight and exercises the current graph's Capture action. Each new confirmation also advances its request token so an older response cannot authorize a newer dialog.

