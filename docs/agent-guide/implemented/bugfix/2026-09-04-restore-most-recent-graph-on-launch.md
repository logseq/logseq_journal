# Restore Most Recent Graph On Launch

## Problem

`docs/ux-guidelines.md` requires launch to open the most recently opened graph
immediately instead of presenting graph selection. A Computer Use walkthrough of
the current macOS debug application reproduced the opposite behavior: after
opening the cached `ocaml-sync-test` graph, quitting, and launching again, the
application transitions from "Loading your graphs" to "Choose a graph".

The catalog cache already persists `selectedGraph`. The regression is in
`Logseq_sync_pure_reducer.Core`: successful `Load_catalog` completion copies that
identifier into the public snapshot but unconditionally sets
`awaiting_selection = true`. It does not admit the cached identifier against the
loaded catalog, construct a graph scope, retain the selected graph value, or
delegate mirror inspection. The UI therefore renders the graph picker correctly
for an incorrect runtime state.

The same visual walkthrough found no additional guideline violation. The visible
Timeline remains within the three-divider limit, Account uses the Material dialog
surface, and Settings uses Material filter chips. Those behaviors do not require
product changes.

## Proposal

Restore the runtime-owned warm-selection transition in the pure reducer. When a
catalog cache loads successfully, first publish the loaded graph catalog. If its
cached selected graph is present in that catalog, enter the same graph-selection
transition used by an explicit selection, except that loading the cache must not
rewrite the cache. This transition must clear `awaiting_selection`, advance graph
generation, set the selected graph and admitted graph scope, and delegate mirror
inspection so the normal local-open path can present Timeline.

If the cache has no selected graph or the identifier is not present in the cached
catalog, fail closed to graph selection and start no graph work. Never construct
a scope from an unadmitted cached identifier.

Keep durable selection distinct from the process-local selection cleared by
`Graph_picker_requested`. Returning to the picker must not erase the cached most
recent graph, so a later application launch restores it again.

Remote catalog application must preserve a selected graph that remains admitted
and must clear, fence, and detach a selected graph that the authoritative catalog
removes. Same-account authentication must reconcile remotely without discarding
an in-progress or completed local warm restore. If authentication arrives before
local cache loading completes, record deferred reconciliation and do not request
the remote catalog until local admission has been decided.

Implement this behavior inside `Core`; do not add a UI-owned synthetic selection,
a Flutter fallback, a compatibility cache, or a migration path. Tests verify the
runtime behavior but are not the mechanism that provides it.

## Decision

Accept the proposal. The pure reducer owns warm graph selection, durable recent
selection, same-account startup ordering, and authoritative catalog revocation.
Flutter continues to render the state it receives and does not synthesize a graph
selection.

## Alternatives considered

### Dispatch a synthetic selection from the UI

Rejected. It would make startup depend on rendering a picker frame and duplicate
catalog admission and graph-generation policy outside the reducer.

### Treat the cached identifier as selected only in the public snapshot

Rejected. A displayed identifier without an admitted graph scope cannot inspect
or open the local mirror and leaves `awaiting_selection` contradictory.

### Add a fallback cache or migration

Rejected. The active cache already contains the required data, and the repository
removes obsolete paths instead of preserving backward compatibility.

## Acceptance criteria

- After a graph has been selected and persisted, a terminated macOS app launch
  proceeds from loading to that graph's Timeline without showing graph selection.
- A valid cached selection is admitted against its cached catalog, advances graph
  generation, clears `awaiting_selection`, and delegates mirror inspection without
  a UI `Graph_selected` event.
- Missing and stale cached selections remain in graph selection and start no graph
  work.
- Returning to graph selection affects the current process but does not erase the
  most-recently-opened graph used by the next launch.
- Same-account online reconciliation preserves local warm restoration, including
  authentication before cache-load completion.
- A catalog refresh preserves an admitted selection and clears, fences, and
  detaches a removed selection.
- Timeline remains within the three-divider limit, and affected UI continues to
  use the existing Flutter Material components.
- Focused reducer tests, the complete test suite, formatting checks, agent document
  validation, and a post-fix Computer Use walkthrough pass.

## Risks

- Cache load, authentication, and remote catalog discovery are concurrent. Applying
  them in arrival order without explicit retained state can erase a valid local
  selection or overwrite its cache before admission.
- Reusing explicit graph selection during cache restoration can accidentally save
  the cache again and create unnecessary write churn.
- A removed catalog graph may still own in-flight mirror, key, or network work;
  revocation must advance generation and cancel or detach the old scope.

## Consequences

Warm launch now enters the existing mirror-open path without a graph-picker frame
when the active cache contains a valid recent selection. Returning to the picker
remains process-local, while catalog removal remains authoritative and clears the
durable selection. The reducer carries three private fields for cache-load status,
deferred same-account reconciliation, and the durable recent graph; no public API
or cache format changes.

## Implementation outcome

Implemented on 2026-09-04.

- `Core` now distinguishes the durable cached graph from the process-local
  selection and restores only an account-matching, catalog-admitted cached graph.
- Warm restoration reuses graph admission without rewriting the cache, advances
  graph generation, and delegates mirror inspection directly from cache load.
- Same-account authentication preserves an in-flight cache load and starts remote
  catalog reconciliation only after local admission.
- Authoritative catalog refresh preserves admitted selection and clears, fences,
  cancels, and detaches a removed selection before persisting the new cache.
- Cache-save failure is advisory and cannot invalidate an otherwise usable graph.
- Focused and complete OCaml suites, Flutter tests, Flutter analysis, formatting,
  full build, and agent-document validation passed.
- A post-build Computer Use walkthrough selected `ocaml-sync-test`, terminated the
  macOS app, relaunched it, and observed Timeline as the first completed interface
  without graph selection. Timeline divider count and Material component usage
  remained aligned with `docs/ux-guidelines.md`.

## Questions

- None.
