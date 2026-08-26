# Warm Start Local Mirror Status Copy

## Problem

Every managed warm start briefly renders `Downloading graph` with `Preparing the
local mirror` even when the selected graph already has a valid, persistent SQLite
mirror. Physical iPhone inspection confirmed that the existing 1.1 MB `db.sqlite`
was retained across launches and that only the runtime lock and pending-intent
files changed during the latest launch.

The misleading copy is caused by state ordering rather than repeated network
transfer. `Select_graph` unconditionally changes the sync-manager phase to
`Bootstrapping` before emitting `Inspect_mirror`. The service publishes that
snapshot before resolving the mirror, and the application maps every
`Bootstrapping` snapshot to the download copy. A slower physical device presents
the intermediate frame reliably even though `Inspect_mirror` immediately returns
`Mirror_ready`.

`Bootstrapping` must mean that the worker has established that no usable local
mirror exists and is preparing a remote snapshot. It must not describe local
mirror admission, metadata validation, or engine open.

## Decision

Set the selected graph phase to `Opening_graph` while the worker inspects the local
mirror. Preserve the existing synchronous `Inspect_mirror` effect and all mirror
ownership, file, and sync-metadata validation. Enter `Bootstrapping` only after a
current-generation `Mirror_missing` event establishes that remote snapshot
bootstrap is required.

Keep the existing UI copy unchanged: `Opening_graph` continues to render
`Opening graph`, while genuine `Bootstrapping` continues to render `Downloading
graph` and its measured snapshot progress. Do not trust the advisory cached mirror
status as proof that a mirror exists; filesystem validation remains authoritative.

### Implementation outcome

`Select_graph` now publishes `Opening_graph` before its unchanged
`Inspect_mirror` effect. A current-generation `Mirror_missing` event remains the
only transition that begins snapshot bootstrap for the warm-start path. The
application's existing phase-to-copy mapping therefore shows `Opening graph` while
validating and opening an existing mirror, and reserves `Downloading graph` for a
confirmed missing mirror.

The sync-manager regression first failed against the former unconditional
`Bootstrapping` transition, then passed after the one-phase change. Full OCaml tests
passed. A signed Debug build was reinstalled on the physical iPhone while retaining
its existing data container. During a ten-second cold launch, 82 render-tree
samples observed zero instances of `Downloading graph`, `Preparing the local
mirror`, or `Authenticating`; the sampled startup advanced through `Opening graph`
to the Timeline.

## Alternatives considered

### Add an `Inspecting_mirror` phase

This would describe the operation most precisely, but expands the public manager
state and every exhaustive consumer for an intermediate operation that currently
shares the same user-facing local-open copy and behavior as `Opening_graph`.

### Derive the phase from cached mirror status

The catalog cache is advisory and can be stale after a crash, restore, or external
file loss. It must not bypass or contradict authoritative mirror validation.

### Suppress the pre-inspection manager snapshot

This couples service publication ordering to one effect and can hide legitimate
selection and generation changes. Publishing an accurate `Opening_graph` state is
simpler and preserves observability.

## Acceptance criteria

- Selecting a cached graph enters `Opening_graph` while emitting `Inspect_mirror`.
- A valid local mirror advances from `Opening_graph` to local engine open without
  publishing a misleading `Bootstrapping` phase.
- `Mirror_missing` changes the phase to `Bootstrapping` before requesting a fresh
  snapshot token.
- The real bootstrap screen retains `Downloading graph`, byte progress, and
  snapshot preparation copy.
- Mirror validation remains filesystem- and metadata-based rather than trusting
  cached mirror status.
- A physical iPhone warm launch does not display `Downloading graph` when its
  persistent local mirror is valid.

## Consequences

- Warm-start mirror validation is presented as local graph opening rather than a
  network download.
- A confirmed missing mirror retains the existing authenticated snapshot bootstrap
  and measured download progress behavior.
- The advisory catalog mirror status remains non-authoritative, so every selected
  mirror still receives filesystem and durable sync-metadata validation.

## Risks

- A genuinely missing mirror may briefly publish `Opening_graph` before the serial
  mirror inspection reports `Mirror_missing`; it must then transition immediately
  to the truthful download state.
- Encrypted mirrors that require remote key recovery remain outside the local-only
  warm-start guarantee and may spend longer in an opening or unlock state.

## Questions

- None. The physical-device evidence and existing phase semantics determine the
  required boundary.
