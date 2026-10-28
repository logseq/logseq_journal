# Resident Graphs

## Problem

The requested feature keeps up to three graphs open in one account. Hidden graphs
continue synchronization while only the visible graph computes presentation work.
The current application equates selection with graph lifetime, so switching resets
runtime state and can interrupt an in-flight Capture save.

Inspection baseline: `ae63fadba3be93aef2a69ebd037db3887eb02935` (remote main
verified on 2026-10-28). The implementation now separates account and graph owners.

Observed ownership boundaries:

- `logseq_sync/lib/pure_reducer/core.ml:1481`: selection increments graph and
  presentation generations and calls `reset_graph_operations`. The current
  graph's key, bootstrap, pull and submission state are replaced.
- `logseq_sync/lib/pure_reducer/core.ml:3776`: changing the target retires its
  websocket; the hidden graph therefore cannot keep synchronizing.
- `logseq_db_worker/lib/pure_reducer/core.ml:183` and `:434`: one database owns
  every unscoped `Graph_request`.
- `logseq_db_worker/lib/effect_runner/effect_runner.ml:493`: asset validity
  depends on `snapshot.selected_graph`, invalidating hidden graphs' work.
- `logseq_db_worker/lui/logseq_db_worker_lui_service.mli`: `Graph_request` and
  `Get_graph_state` carry no target; non-asset topic coalescing keeps only the
  newest push, which would lose another graph's pending invalidation.
- `app/application.ml:693`, `:3240` and `:3516`: selection interrupts saving,
  resets the sole graph runtime and retires graph leases.

## Proposal

Separate one account owner from up to three graph sessions and one visible graph.
Each session owns its DB, sync connection, request/action queues, subscription,
assets, runtime caches, navigation, Capture/append drafts and retained UI position.
Auth, ID-token acquisition/cache, catalog and platform lifecycle remain shared.

Use the complete existing graph scope (account, graph UUID and lifetime
generation) as the target of every graph operation and completion. A visibility
change must not increment that lifetime, cancel leases, detach DBs, fail saves or
rebind queued effects to the current UI. Closing/replacing a session retires only
that exact scope. Reopening the same UUID gets a fresh lifetime; old completions
may release their own resources but cannot update the reopened session.

Protected contract changes explicitly authorized by the user:

| Contract | Required change | Reason |
| --- | --- | --- |
| `logseq_sync/spec/pure_reducer/core.mli` | Separate resident configuration/open/close/replace from visible focus events | Focus must leave synchronization owners alive |
| Same | Query admitted scope, asset context and synchronization state by graph; expose bounded resident session state | A single selected graph cannot be the admission authority |
| Same | Add graph scope to `Local_outbox_changed` | A hidden graph's mutation must wake its own submission queue |
| Same | Extend catalog-cache encoding/decoding for ordered residents and last visible graph, with old single-selection format migration | Restore the same order across restart without creating a second catalog owner |
| `logseq_db_worker/spec/pure_reducer/core.mli` | Scope `Graph_request`, projection events/pushes, asset/upload admission and `import_context` | Request destination cannot be inferred at execution time |
| Same | Represent per-graph DB/assets/recovery state and scoped lifecycle publication/results | Closing one graph must not close another; late closes must identify their owner |

Propagate these contracts through existing `logseq_db_worker/lib` and `lui`
interfaces, request admission, transport, asset/media runtimes and application
state. Coalesce graph pushes per scope, preserving all pending graphs. Bound
resident membership to three unique authorized catalog entries. Keep lifetime
generations unique and separate from UI presentation generations.

No current evidence requires changes to either effect-runner `.mli` under `spec/`
or to Dune files. Use existing compiled modules/test entry points. Any later
protected-contract need must identify the exact missing boundary first.

Switch graph owns the three resident slots and their order. At capacity, adding
another graph requires an explicit replacement target; it never evicts silently.
Removing a resident closes only its runtime, preserving its local mirror. Logout
retires all sessions for the account. No concurrent multi-account use is added.

Timeline retains its current appearance: no graph title strip, dots, drawer or
hint. A right drag moves the whole page, including its existing floating controls,
with the next configured graph entering from the left. Only a committed right
gesture changes focus; a cancelled gesture returns to its origin. One resident
does not install a switching gesture. Two/three wrap in configured order. Left
drags never switch. Native vertical scrolling wins; detail back gestures,
composer, keyboard, image preview and QuickLook retain their gestures. Use native
SwiftUI/UIKit root-page APIs, without per-row geometry or scroll scans.

Hidden synchronization applies data and marks presentation interests dirty; it
does not hydrate/re-render each hidden Timeline on each push. Focus refreshes
from the graph's current DB before publishing its new visible presentation.
Pending Capture commands keep their original graph/session and mutation identity.

### Reviewable implementation batches

Deliver one complete non-Draft PR, with internal commits for the following work:

1. Add the required failing behavioral tests up front through existing public
   reducer boundaries and integration surfaces. Cover all rows in Acceptance
   criteria. Observe expected failures before implementation, separating a
   missing contract compile error from a demonstrated behavior failure.
2. Implement account/resident ownership, stable per-graph scopes and configuration
   persistence/migration. Make lifecycle/admission tests pass first.
3. Implement per-scope worker/DB/effect routing, coalescing and resource retirement.
   Prove hidden synchronization and stale-completion fencing independently from UI.
4. Split application graph state/stores/drafts from account/platform state, and
   make focus a presentation operation. Preserve Capture saves during focus changes.
5. Add resident management to Switch graph, then native whole-page right-only
   interaction with cancellation and gesture arbitration. Refactor with tests green.
6. Run final source build/tests, independent read-only review of exact final
   SHA/diff, isolated Simulator GUI acceptance and actual recording; fix findings,
   revalidate affected evidence, then create and attach the formal PR. Do not merge
   or publish a release.

### Evidence preparation and target policy

Both user-provided PNG references were materialized through Library and visually
inspected. The storyboard's old left-swipe/non-loop annotations are superseded by
the latest request; only its whole-page translation is applicable.

Two booted iOS 26.1 Simulators were identified read-only; neither was installed,
erased, signed out or seeded by this task. Their real contents are unverified.
Use a new task-owned Simulator and/or a distinct probe bundle/container with
synthetic graphs. Existing warm-start fixtures support four synthetic encrypted
graphs with memory-only secrets, but block network auth: by themselves they do
not establish hidden server synchronization. Use an isolated synthetic transport
fixture for synchronization acceptance and state that evidence's limits.

The latest inspected producer and Simulator manifests both bind the baseline
SHA. Prepared OCaml 5.5.0/Dune 3.23.1 inputs and matching LUI package already exist;
do not relocate or repin them. Retain fresh source/provenance verification. The
current native Simulator route remains experimental host-restamped code with
`cross_abi_validated=false`; Simulator acceptance does not establish device ABI.

Final required checks: `dune build @all app/native_embed.exe.o`,
`dune runtest --force`, decision-document validation, independent review and
affected native/GUI acceptance. Bind logs, manifests and recordings to final full
HEAD SHA, SDK, UDID, app hash and fixture inputs. Upload actual recordings through
Library, retain returned IDs, and distinguish upload from content readback.

## Alternatives considered

### Three existing full application/worker instances

Each instance still owns its auth/catalog lifecycle and writes the same catalog
selection cache. This duplicates account authority, introduces account cleanup
races and does not meet the agreed sharing boundary.

### Cache three screens while switching the existing worker

This only changes appearance. Selection still retires the old websocket/DB and
interrupts saving. It cannot satisfy hidden synchronization or safe late callbacks.

## Acceptance criteria

- Complete every applicable scenario below on the final source revision; report
  missing evidence explicitly rather than treating earlier source or mock UI as acceptance.

| Scenario | Observable result / narrowest owner |
| --- | --- |
| One resident | No switch interception; normal Timeline interaction |
| Two / three residents | Right-only ordered loop, including final graph to first |
| Left swipe | No focus or runtime change |
| Right drag cancelled/reversed | Page returns; no committed focus change |
| Vertical scroll and other native gestures | No graph switch; scrolling/detail/composer/preview remain usable |
| Separate Capture and append drafts | Graph A's text/attachments never appear in B; returning restores A |
| Save in flight during focus change | Original graph commits once; no lost or duplicated Capture |
| Hidden graph remote update | Its scoped DB/queue advances while visible graph stays unchanged |
| Focus after hidden synchronization | Latest synchronized data is visible; no stale cached page |
| Hidden presentation cost | No hidden row-store/body updates for each sync event |
| Late response after focus | Completes its original live graph, never the visible one |
| Late response after close/reopen | Fenced by original lifetime; new session is untouched |
| Full three-slot membership | User chooses replacement; all other sessions remain running |
| Remove then restore | Local mirror remains; reopened graph receives fresh runtime scope |
| Restart | Resident order and last visible graph restored; old cache format migrates |
| Account logout/revocation | All owned sessions retire, no stale callback updates another account |
| UI delivery | Actual Simulator clips show success loop, drafts, hidden sync and cancellation; exact Library IDs retained |

Prefer public pure reducer regressions for ownership, configuration and lifecycle.
Use service integration only for routing/coalescing boundaries not represented by
those reducers. GUI recordings supply the specifically requested visual evidence;
they do not replace source-level correctness checks.

## Risks

- Scope equality currently includes account presentation data. Visibility changes
  must not accidentally expire still-resident graph scopes.
- Multiple pending graphs must survive bounded push coalescing; keeping only the
  latest topic payload can silently lose hidden changes.
- Close/replace must preserve disk mirrors and pending outbox content while safely
  releasing sessions and native file leases.
- Pending synchronization remains subject to actual iOS app lifecycle limits.
- This is a cross-layer ownership change; a UI-only partial PR is not complete.

## Questions

- Authorization resolved: the feature changes the two protected public contracts
  `logseq_sync/spec/pure_reducer/core.mli` and
  `logseq_db_worker/spec/pure_reducer/core.mli`, with the corresponding
  implementations, consumers and tests described above. `AGENTS.md` explicitly
  requires a request to change `.mli` contracts under `spec/`. The user explicitly authorized these two contracts on 2026-10-28
  (Sentinel_67314c7d73bc81918cebf4134793a9aa); no automatic-review denial occurred. No permission for additional
  protected contracts, Dune changes, merging or release publishing is requested.

### Current validation and remaining evidence

- Full source build and `dune runtest --force` pass on the current implementation.
  Coverage includes 344 sync tests, resident worker routing/teardown, per-scope
  push coalescing and 150 application tests.
- A real iOS Simulator App builds through the maintained importer. It uses
  experimental host-restamped OCaml, with `cross_abi_validated=false`.
- Independent review findings about hidden graph network permission, account
  ledgers, shutdown, asset callback ownership and application retirement were
  addressed. Independent read-only review of the final implementation diff
  (`35ef9e6f1a2b671e94ccc33705792d7aa3bf08329f8cb22dd2572561c17a311f`)
  reported no remaining P1/P2 in the reviewed scope.
- GUI interaction and recording are pending: the host Mac is locked and the
  computer-use tool cannot unlock it. No simulator gesture or visual acceptance
  is claimed. The task owns a separate synthetic-data Simulator; shared devices
  remain untouched.
- The warm-start fixture blocks authentication, so it cannot by itself prove
  hidden server synchronization. A recording of that scenario and save-in-flight
  graph switching still require actual acceptance. Native scroll-position
  retention across graph focus also remains unverified.

### Real transport follow-up

The first remote CI run for the initial PR head was cancelled before any step
executed because GitHub could not allocate a hosted macOS ARM64 runner. This
was a runner-capacity failure, not a source test result.

A pinned-certificate loopback fixture subsequently reproduced an additional
physical routing defect: the socket table still used the constant diagnostic
string `start-websocket` as its key. It now uses the complete connection scope,
and running websocket operations have graph/connection-specific identities.
The regression verifies two real TLS sockets, separate baseline responses, a
hidden graph notification and its own Pull, and a successful B retry Pull/response after
A retires. This does not claim authoritative DB application or GUI acceptance.
