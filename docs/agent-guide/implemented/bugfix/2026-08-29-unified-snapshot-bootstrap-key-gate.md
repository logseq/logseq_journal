# Unified Snapshot Bootstrap Key Gate

## Problem

Snapshot bootstrap has multiple Core entry points with different E2EE behavior.
The normal `Mirror_absent` path checks whether the selected graph is encrypted and
loads a graph-key handle before requesting snapshot authorization. Two recovery
paths bypass that gate:

- `Online_recovery_requested` requests `Snapshot_bootstrap` authorization
  immediately.
- `Local_cache_deletion_requested` clears `graph_key`, advances the graph
  generation, and then requests `Snapshot_bootstrap` authorization immediately.

Both paths can therefore fetch a complete encrypted snapshot while
`core.graph_key = None`. The download completion detects the missing capability
and fails with `encrypted snapshot requires a graph key handle`. That check is a
necessary final invariant, but it occurs too late to orchestrate key acquisition
or prevent the unnecessary download.

The existing pure-Core coverage proves the normal encrypted cold-bootstrap path,
encrypted warm-mirror attachment, and activation handle propagation. It does not
exercise every bootstrap entry point across encrypted, unencrypted, recovery, and
graph-generation transitions. This allowed recovery commands to bypass the key
gate while the contract suite remained green.

## Proposal

Introduce one private pure-Core helper for beginning snapshot bootstrap. Every
path that intends to request `Snapshot_bootstrap` authorization must call this
helper; no event handler may call `request_graph_token ... Snapshot_bootstrap`
directly.

The helper owns these invariants:

1. If no selected graph or current graph scope exists, emit no effect.
2. For an unencrypted graph, request snapshot authorization immediately.
3. For an encrypted graph with a handle scoped to the current graph generation,
   request snapshot authorization immediately.
4. For an encrypted graph without a usable handle, issue
   `Load_and_unlock_graph_key`, remember that snapshot bootstrap is waiting for the
   key, and emit no snapshot authorization request yet.
5. After key acquisition succeeds, store the scoped handle and resume through the
   same snapshot-authorization boundary.
6. If key acquisition fails, enter E2EE recovery without starting baseline,
   metadata, download, or activation work.
7. If key acquisition or snapshot bootstrap is already in flight, coalesce a
   repeated recovery request by leaving the current chain unchanged. Do not cancel
   or restart scoped work that has no newer input.

Route at least these entry points through the helper:

- `Mirror_absent` during normal graph selection.
- `Online_recovery_requested`, including retry after bootstrap failure.
- `Local_cache_deletion_requested` after establishing the new graph generation.

Keep graph-key material runner-owned. The helper may inspect only graph encryption
metadata, opaque handle presence and scope, pending bootstrap intent, and typed
effect state. It must not expose raw keys or move crypto into Core.

Add public-contract scenarios in `logseq_sync/test/core_contract.ml` using only
`Logseq_sync.Core` values from `spec/core.mli`. Cover the complete startup matrix:

| Startup route | Graph/key state | Required result |
| --- | --- | --- |
| Missing mirror | Unencrypted | Request snapshot authorization immediately |
| Missing mirror | Encrypted, no key | Load and unlock key before snapshot authorization |
| Missing mirror | Encrypted, cached-key load fails | Enter E2EE recovery; start no snapshot request |
| Missing mirror | Encrypted, remote/password key recovery succeeds | Resume snapshot authorization with the recovered handle retained |
| Available mirror | Unencrypted | Attach immediately; start no snapshot bootstrap |
| Available mirror | Encrypted, no key | Load and unlock key before attachment |
| Available mirror | Encrypted, valid scoped key | Attach with no redundant key or snapshot request |
| Online recovery | Unencrypted | Request snapshot authorization immediately |
| Online recovery | Encrypted, no key | Load and unlock key before snapshot authorization |
| Online recovery | Encrypted, valid scoped key | Reuse the handle and request snapshot authorization |
| Current-cache deletion | Unencrypted | Advance generation, delete cache, then request snapshot authorization |
| Current-cache deletion | Encrypted | Advance generation, reload a handle for the new scope, then request snapshot authorization |
| Any encrypted bootstrap | Wrong-scope or stale key completion | Never start snapshot work with that handle |
| Any bootstrap route | Repeated recovery command while work is pending | Emit no competing bootstrap chain |

For every encrypted scenario, assert negative ordering as well as the final happy
path: before the correct handle exists there must be no
`Fetch_snapshot_baseline`, `Fetch_snapshot_metadata`, `Download_snapshot`, or
`Activate_snapshot` instruction. Continue asserting at download completion that
encrypted activation contains `Some` correctly scoped handle and unencrypted
activation contains `None`.

## Decision

Adopt one private Core snapshot-bootstrap helper and route normal cold bootstrap,
online recovery, and current-cache deletion through it. The helper gates encrypted
snapshot work on a correctly scoped graph-key handle and resumes the same intent
after successful key acquisition.

Repeated `Online_recovery_requested` events are coalesced while key acquisition or
snapshot bootstrap is already in flight. Core keeps the existing typed request and
emits no replacement key request, authorization request, cancellation, or parallel
bootstrap chain. A new chain starts only after the current attempt reaches a
terminal failure or the graph scope changes.

Add the complete pure-Core startup matrix described above before implementation,
including positive completion paths and negative ordering assertions. Keep the
download-completion handle check as defense in depth.

## Alternatives considered

### Keep the download-completion check as the only invariant

Rejected because it fails after network and disk work has completed and cannot
recover the missing key. It is useful as defense in depth, not as startup policy.

### Duplicate the encryption check in each recovery handler

Rejected because the current bug was caused by duplicated entry logic. Additional
copies would continue to drift when new recovery or bootstrap commands are added.

### Let the worker acquire a graph key during activation

Rejected because authentication and startup policy belong to Core, while the
worker owns mirror persistence. Worker-side key acquisition would hide ordering
from the reducer, duplicate recovery state, and weaken public contract tests.

### Rebind an existing handle after graph-generation changes

Rejected because a handle is scoped to the generation for which it was issued.
After local-cache deletion, Core must request a new handle rather than changing or
forging the scope of an existing capability.

## Acceptance criteria

- Every snapshot authorization request originates through one private Core helper.
- No encrypted snapshot baseline, metadata, download, or activation starts before
  a correctly scoped graph-key handle is available.
- Online recovery and current-cache deletion acquire a key before bootstrapping an
  encrypted graph.
- Current-cache deletion reloads the key for the incremented graph generation.
- Key acquisition failure enters E2EE recovery and delegates no snapshot work.
- Repeated recovery commands cannot create competing key or snapshot chains.
- Pure-Core public-contract tests cover every row in the startup matrix.
- Existing runner and worker tests continue to pass without exposing raw key
  material through `spec/core.mli`.

## Risks

- The existing `bootstrap_after_key` boolean may be too weak to distinguish a
  queued bootstrap intent from an already active key, token, or download request.
  The implementation may need a more explicit private bootstrap phase, but no new
  public type should be introduced unless tests require it.
- Recovery commands can arrive while asynchronous effects are in flight. The
  helper must preserve typed ticket consumption and must not accept stale
  completions from a previous graph generation.
- Local-cache deletion changes graph scope. Reusing the old handle would violate
  capability scoping even if its underlying raw key bytes are unchanged.
- A broad startup matrix can become coupled to incidental effect ordering. Tests
  should assert security and sequencing invariants while avoiding unrelated UI
  publication order.

## Consequences

Every snapshot entry point will enforce the same encrypted-graph capability gate,
so recovery commands cannot bypass behavior already required by normal cold
bootstrap. Cache deletion will reload a handle for its new graph generation rather
than reusing an out-of-scope capability.

Coalescing repeated recovery requests makes retry idempotent while work is active
and preserves the original typed ticket chain. It intentionally gives up manual
restart semantics during an in-flight attempt; retry becomes available again only
after failure or scope replacement.

## Questions

- None. Repeated online recovery requests are coalesced while the current key or
  snapshot chain is in flight.
