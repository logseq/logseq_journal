# Warm Start Selected Graph Restoration

## Problem

Every application launch enters the graph picker even after the user selected and
successfully opened a graph on the previous launch. The expected warm-start
behavior is to restore that selected graph, validate its local mirror, and enter
the existing graph-open path without requiring another selection gesture.

The regression was introduced by the pure-Core cutover in commit
`4f1141447d94bd7ecc2b81e40e34ec0142206fc9`. The current catalog-cache type and
JSON codec still carry `selectedGraph`, but the active transition paths do not
preserve or consume it:

- `Graph_selected` updates only the in-memory snapshot and emits mirror inspection;
  it does not emit `Save_catalog` with the selected graph.
- `Fetch_catalog_kind` completion constructs the saved cache with
  `selected_graph:None`, so a refresh can erase a selection even if one was
  otherwise retained.
- `Load_catalog_kind` completion extracts only `catalog_cache_graphs`; it discards
  `catalog_cache_selected_graph` and calls `catalog_loaded`, which unconditionally
  publishes `awaiting_selection = true`.
- Same-account `Account_authenticated` reconciliation clears a graph that local
  cache restoration already opened, and an early remote catalog completion can
  overwrite the still-loading cache with `selected_graph:None`.

The UI is following the published state correctly: `Journal_startup.derive` maps
`awaiting_selection` to `Awaiting_selection`, and `Application` renders the graph
picker for that phase. The defect is therefore in selected-graph persistence and
restoration policy inside `Logseq_sync.Core`, not in graph-picker presentation.

The pre-cutover runtime updated its catalog cache when `Select_graph` was handled
and, after loading a cached catalog, automatically dispatched `Select_graph` when
the cached selection was still present. Those two behaviors were not carried into
the new reducer.

Current public-contract coverage verifies only that `Graph_selected` updates the
selection in the same in-memory Core value and delegates mirror inspection. It
does not exercise the durable round trip from selection, through a saved catalog
cache, into a fresh Core warm start. Consequently the complete sync test suite
passes while the launch behavior remains broken.

## Proposal

Make `Pure_core` the sole owner of selected-graph cache policy and restore the
warm-start behavior through existing typed transitions.

When a current catalog graph is selected, persist a catalog cache containing the
current user ID, current catalog, and `Some graph_id`. Keep mirror inspection and
state publication in their existing ordered transition; catalog-cache persistence
remains advisory and a `Save_catalog` failure must not invalidate or close an
otherwise usable graph.

`Return_to_graph_picker` closes the current graph and presents the picker for the
remainder of the current process, but it does not clear the persisted selection.
The cache represents the most recently opened graph, so the next application
launch automatically restores that graph unless it is no longer admitted by the
catalog.

When a catalog cache is loaded, consume the complete cache value rather than only
its graph list:

1. Publish the cached graph list for the current account.
2. If `selectedGraph` identifies a graph in that same cached list, restore it by
   entering the same private graph-selection transition used by
   `Graph_selected`. This transition must establish a new graph generation and
   scope, clear `awaiting_selection`, set the selected graph, and delegate
   `Inspect_mirror`.
3. If the cache has no selection, or the selected graph is absent from the cached
   list, remain in `Awaiting_selection` and do not inspect or attach any graph.
4. Never construct a graph scope from a cached UUID that is not admitted by the
   loaded catalog.

When a remote catalog is fetched or refreshed, save it with the current admitted
selection when that graph remains in the new catalog. If the selected graph is no
longer present, clear the in-memory and cached selection, close or detach the
replaced graph through the existing graph-replacement authority, and publish
`Awaiting_selection`. Do not write `selected_graph:None` unconditionally.

Same-account authentication reconciliation must preserve local cache loading and
an already restored selected graph. If the remote catalog completes before the
local cache load, retain that result inside Core without writing the cache. Apply
and persist it only after the local completion establishes whether a selected graph
must be restored. Different-account authentication continues to replace the local
account state.

Add regression scenarios to `logseq_sync/test/core_contract.ml` before changing
the implementation. The tests must use only the public `Logseq_sync.Core`
contract and typed request/completion values:

- selecting a catalog graph emits `Save_catalog` whose encoded or observable
  selection is that graph ID, while still delegating `Inspect_mirror`;
- a fresh Core receiving `Restore_local_account` followed by a successful
  `Load_catalog` completion containing a valid `selectedGraph` restores the
  selection, clears `awaiting_selection`, advances graph generation, and
  delegates `Inspect_mirror` without a `Graph_selected` UI event;
- a loaded cache with `selectedGraph = None` remains in `Awaiting_selection` and
  delegates no graph work;
- a loaded cache whose selected graph is absent from its graph list remains in
  `Awaiting_selection`, publishes no selected graph, and delegates no graph work;
- a remote catalog refresh preserves and saves a still-admitted selected graph
  instead of overwriting it with `None`;
- a remote catalog refresh that removes the selected graph clears the selection
  and cannot inspect, attach, or retain the removed graph; and
- a `Save_catalog` failure after graph selection leaves the selected graph and
  mirror-open path usable because the cache is advisory;
- same-account authentication after warm restoration preserves the selected graph
  while starting catalog reconciliation; and
- authentication and remote catalog completion before local cache completion do
  not erase the pending selected graph or overwrite its cache with `None`.

At least one testcase must model the complete durable boundary by taking the
cache requested by the selection transition, encoding and decoding it through the
public catalog-cache codec, and supplying it as the load completion to a fresh
Core. This is the regression test that proves behavior across process restarts
rather than only within one reducer instance.

Do not restore the deleted mutable `Logseq_sync.Api`, add a second cache-policy
helper outside Core, or add compatibility readers, fallback paths, or migration
logic for the obsolete pre-reducer cache location and schema. The fix applies to
the current cache contract; after users select a graph once under the fixed
runtime, subsequent launches must restore it.

## Decision

Make `Pure_core` own both the current selected graph and the distinct most-recently
selected cached graph. Persist an admitted UI selection, restore an admitted cache
selection through the private graph-selection transition without rewriting the
cache, and preserve or clear the cached selection when applying a remote catalog.

Treat same-account `Account_authenticated` as online reconciliation rather than
account replacement. Preserve completed and pending local restoration, retain an
early remote catalog inside Core while the local cache is loading, and apply and
persist that catalog after the local completion. Continue replacing state for a
different authenticated account or sign-out.

## Alternatives considered

### Restore the selection in `Application`

The UI could inspect the catalog and dispatch a synthetic `select-graph` action.
This would duplicate cache admission and generation policy above Core, make warm
startup depend on a rendered frame, and leave non-UI Core consumers with the same
broken behavior.

### Let `Effect_runner` auto-select after reading the file

The runner owns bounded filesystem execution and cache encoding, but it must not
own synchronization policy or call `Core.step`. Interpreting `selectedGraph` in
the runner would weaken the pure reducer boundary and make the transition harder
to replay and test.

### Persist the selection in a separate preference

The active catalog-cache contract already contains `selectedGraph`. A second
preference would introduce two sources of truth and require reconciliation for
account changes, catalog removal, and graph switching.

### Reintroduce the deleted pre-reducer catalog store

The old runtime coupled selection, mirror status, origin, and catalog persistence
in a mutable cache model. Restoring it would create parallel orchestration paths
and violate the completed pure-Core cutover. Only the missing behavior should be
implemented in the current Core contract.

### Add a legacy cache migration or fallback reader

The repository explicitly removes obsolete paths rather than preserving backward
compatibility. A legacy reader would also address only the first upgraded launch;
it would not fix the current runtime's failure to save and consume its own
`selectedGraph` field.

## Acceptance criteria

- Selecting an admitted graph persists that graph ID in the current catalog
  cache without delaying or invalidating mirror inspection.
- A fresh Core restores a valid cached selected graph and delegates
  `Inspect_mirror` without requiring a `Graph_selected` UI event.
- Warm startup with a valid selected graph does not publish
  `awaiting_selection = true` as its terminal catalog-load result and therefore
  does not render the graph picker.
- A missing, malformed, or no-longer-admitted cached selection fails closed to
  `Awaiting_selection` and starts no graph work.
- Remote catalog refresh preserves a still-admitted selection and clears a
  removed selection using existing detach and generation-fencing authority.
- `Return_to_graph_picker` displays the picker for the current process without
  clearing the persisted most-recently-opened graph; the next launch restores it.
- Catalog-cache save failure remains non-fatal to the selected graph and its local
  mirror-open path.
- Same-account online reconciliation preserves a completed or still-pending local
  selected-graph restoration, including when the remote catalog arrives first.
- `logseq_sync/test/core_contract.ml` covers selection persistence, a complete
  cache codec/restart round trip, valid warm restoration, absent and stale cached
  selections, refresh preservation/removal, and advisory save failure.
- Existing runner, worker, startup, and application tests continue to pass.
- No legacy cache reader, migration, compatibility alias, duplicate preference,
  or UI-owned auto-selection path is introduced.
- `dune runtest logseq_sync/test`, `dune runtest`, `dune build @all`,
  `dune build @fmt`, `git diff --check`, and `spec-dev-tool check --all` pass.

## Risks

- Reusing a graph-selection helper from cache restoration can accidentally emit a
  redundant cache save immediately after loading the same value. The transition
  design should keep persistence ordering explicit and avoid a write loop while
  retaining one source of selection policy.
- `select_graph` currently clears pending effect IDs as part of graph replacement.
  Adding `Save_catalog` must not leave its ticket immediately stale or cancel an
  unrelated current-account cache write accidentally.
- A remote catalog refresh can race graph-local work. Removal of the current graph
  must advance generation and cancel/detach through existing typed scopes before
  publishing the picker state.
- Catalog cache is advisory and may be stale or corrupt. Restoration must always
  admit the selected UUID against the graph list before constructing graph scope
  or touching a mirror.
- The current cache file path does not read the deleted pre-reducer cache. The
  first launch after upgrading may still require one manual selection; no
  compatibility migration is included.

## Consequences

Warm startup now enters the existing mirror inspection and graph-open path without
a graph-picker gesture whenever the current cache contains an admitted selection.
Returning to the picker remains a process-local action and does not discard the
most-recently-opened graph used by the next launch.

Core carries private state for an in-progress local catalog load and one early
remote catalog result. This prevents same-account online reconciliation from
overwriting durable selection before local admission is known, while keeping all
cache interpretation and graph generation policy inside the pure reducer.

## Questions

- None. `Return_to_graph_picker` does not clear the persisted most-recently-opened
  graph, and the next launch automatically restores it.
