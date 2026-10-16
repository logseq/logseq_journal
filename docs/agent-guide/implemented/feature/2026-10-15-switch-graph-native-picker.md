# Switch Graph Native Picker

## Problem

The graph picker used uneven capsule buttons and lost the active graph when opened. It had no per-row local-copy management or durable presence observation. Deleting several local resources in sequence could lose attachment sources before mirror ownership was checked, or strand partially collected retired bytes after a failed purge.

## Decision

Use the selected concept A with native equal-width list rows and no header, following Timeline's full-canvas List and floating controls. Retain close, refresh and existing account controls. Keep catalog order, mark the current graph in place, activate names to switch, and expose Delete local copy only through the separate row menu. Do not add search, graph creation or remote deletion. OCaml owns presentation and request state; Swift provides native-specific list controls.

The user explicitly permits discarding unsynchronized content after confirmation (Sentinel_3c2ff0ee96f88191ab349fca7f7befe9). The confirmation explains that unsynchronized changes, drafts and attachments are discarded on this device, while the cloud copy remains downloadable. The active graph must be switched away from first. Local-copy deletion no longer requires a successful open or persisted account-owner marker; the approved follow-up in [Delete Unopened Local Copy](../../proposed/bugfix/2026-10-16-delete-unopened-local-copy.md) replaces that original restriction with physical directory preparation.

The user authorized the two protected deletion interface changes (Sentinel_098717acd4dc8191baeaae8a9cdbee4b), migration without compatibility paths (Sentinel_17788ec75690819198347944f824cd8c and Sentinel_8265ed5fca0c8191852d23c144887053), and retaining Delete_account_assets. Remove Delete_graph_assets, Database.delete_mirror and the obsolete graph-wide upload-checkpoint delete. Do not add wrappers or fallbacks. Dune, lockfiles and shared opam/pins remain unchanged.

Use an independent Retirement_id value type, distinct from a graph UUID. Share that storage-independent type through the existing value library, avoiding a runtime dependency from the pure reducer into the database I/O implementation.

Keep a single worker business deletion flight. Its internal resource protocol is:

- Acquire the inspected mirror's existing exclusive ownership primitive before retiring any asset source. Revalidate the physical directory and its captured lease identity immediately before the namespace commit.
- Cancel and drain target uploads, then freeze staging/checkpoint writers while capturing exact operation/payload pairs. Persist a coordinator journal before preparing assets.
- The asset owner blocks new work for the target origin/account/graph across generations, cancels existing operations and asynchronously waits for native leases. Release and cancellation controls remain available; destructive staging cleanup waits. Move the captured cache into a unique retirement namespace without unlinking its bytes.
- Mirror commit atomically renames that one canonical mirror namespace. This is not an atomic transaction over all directories. Synchronize the directory chain and persist this retirement's committed receipt before destructive cleanup in another producer. An unrelated missing or changed canonical mirror is never commit evidence.
- After durable commit, conditionally remove only captured upload rows and collect only the captured retired asset namespace. Preserve new same-graph operations and replacement canonical files. Physical purge failures stay in producer-owned pending queues; committed collection failure must not prevent redownload.
- Before commit, cancel restores only the captured asset directory with an atomic no-replace rename. A conflict preserves bytes, journal and the barrier for recovery. Aborted/account-deleted tombstones reject late preparation or restoration. Before a mirror is inspected or attached, replay its journal using exact durable commit evidence; unknown outcomes fail closed.

The producer APIs expose prepare/commit/cancel because the worker coordinates independently owned resources between those steps. Durable receipts and cleanup queues remain private. Completed receipts are looked up by ID; ordinary collection visits pending namespaces rather than all historical receipts.

## Alternatives considered

### Reuse the original picker transition

It detached the current graph and cleared its identity. Keep an application-owned picker presentation, using the existing graph selection lifecycle only for an actual switch.

### Delete attachments and then delete the mirror

A busy or stale mirror could reject deletion after its attachment sources were already gone. Merely reversing the calls would still leave post-commit cleanup failures and retries unsafe. Explicitly capture each resource and retain durable recovery evidence.

### Retain the old single-graph deletion APIs

Their production callers belong to this workflow. Migrate those callers and their contract tests, then remove the obsolete entry points rather than maintain parallel destructive paths. Account cleanup retains its separate existing purpose.

## Validation

- Public mounted Application tests reproduce catalog-refresh error visibility through the existing service and mounted property subscriptions; the reducer cannot execute the missing presentation dependency. Refresh loading/errors remain visible in the list. They also cover current marking, close/session retention, name switching, menu confirmation, action usability while another graph is deleting, and cancellation of superseded presence checks.
- A public worker actor regression faults the coordinator-journal directory with a real file, proving that mkdir/write/fsync exceptions return a retryable deletion error rather than escaping into the shared session switch. The mirror and current graph session remain available. Pure reducer events cannot execute filesystem exceptions.
- Public worker actor tests use real SQLite ownership contention to prove that busy admission precedes asset retirement. They also hold an asset preparation completion while catalog reconciliation retires another graph, proving only the exact deletion ticket/request can resolve its waiter.
- Public Database tests cover stale generations, pathname scope, preparation ownership, cancellation, durable commit replay, partial-purge retry and replacement-mirror isolation. A pure reducer cannot execute filesystem permission failures or ownership acquisition; injecting a failed completion there would not reproduce either bug.
- Public asset reducer events cover token scope validation and replay during pending work, after commit and after account cleanup. Public runner requests exercise native leases, staged-file restoration, atomic restore conflicts and replacement-cache isolation.
- Upload checkpoint tests cover durable capture roundtrips, changed-row refusal with no partial deletion, restart/replay and preservation of new same-graph rows.
- Run full repository compilation and regression/source-boundary checks before building the native probe. Simulator acceptance uses only an isolated iPhone 13 / iOS 26.1 device and rebuildable synthetic graphs, with actual list/menu taps, long names and accessibility Dynamic Type, cancellation, current-graph protection, busy failure/retry, retained Not downloaded rows and real-worker redownload through a controlled loopback TLS fixture. Also exercise intentional discard of an unsent text capture and photo attachment. The fixture is not a live remote sync service.
- Keep build manifests, exact source hashes, test results, screenshots and independent review reports outside Git. Review the final PR head with journal-code-review and wait for that head's CI terminal result.

## Risks

Unknown presence or an unresolved recovery conflict must expose an actionable error rather than assume a safe downloaded state. Restoring a prepared directory can fail if another namespace has appeared; retain the exclusive captured bytes for retry instead of overwriting the new copy.

Host ARM64 OCaml restamping is an experimental Simulator compatibility route. Runtime acceptance does not establish full iOS cross-compilation or ABI validity.

## Consequences

Presence observations are cached by account and invalidated for graph lifecycle changes. Native row controls stay mounted while property signals update text and enabled state: real Simulator testing showed that replacing interactive subtrees could retain obsolete callbacks. The active graph remains usable when the picker closes while another graph's copy is deleting.

Application owns the manager snapshot and action gate; Root_navigation does not, so its events cannot reproduce those UI guards. The worker runtime owns exact promise completion; a reducer supplied with an already incorrect completion cannot reproduce its wrapper inference bug. Resource producers own filesystem transitions, durable receipts and native leases. Each regression lives at the narrowest public owner that executes its defect.
