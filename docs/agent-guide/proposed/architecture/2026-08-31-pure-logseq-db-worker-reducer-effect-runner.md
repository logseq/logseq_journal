# Pure Logseq DB Worker Reducer and Effect Runner

## Problem

`logseq_db_worker` owns graph lifecycle, graph request admission, the Engine,
managed mutation durability, authoritative commits, mirror activation, public
responses, and worker pushes. Its runtime policy is nevertheless concentrated
in `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` rather than in a
worker domain module.

The current 1,248-line Bonsai service contains a roughly 760-line
`Managed_coordinator` together with service construction and the non-managed
graph path. It mixes:

- mutable worker state (`core`, `engine`, lifecycle generations, attached graph,
  mutation admissions, and pending mutations);
- Eio mutexes, promises, streams, fibers, and conditions;
- 42 direct `Engine` calls and mirror filesystem operations;
- deterministic lifecycle, admission, replan, cancellation, and failure policy;
- interpretation of `Logseq_sync_pure_reducer.Core.worker_effect`;
- composition with `Logseq_sync_effect_runner.Effect_runner`;
- Bonsai `Worker.Service` requests, responses, and topic publication; and
- local-target behavior that bypasses `Managed_coordinator` entirely.

Only one small part already has an explicit transition API:
`Logseq_sync_pure_reducer.Core.step`. The worker calls that reducer, mutates its
own coordinator fields, immediately interprets sync instructions, and recursively
feeds worker results back into the sync reducer. The worker's own lifecycle and
request policy are therefore not replayable as data.

`logseq_db_worker/lib/logseq_db_worker.ml` is already only 54 lines, but it is
thin because most runtime ownership lives in the Bonsai adapter, not because a
thin worker driver composes a pure worker reducer and an effect runner. Its
mutable `Graph_lifecycle` is also a second state machine outside the sync reducer.

This structure has concrete costs:

- worker policy can only be tested through an Eio-backed service or by inspecting
  source text;
- graph lifecycle and managed-sync state are mutated through separate objects;
- pending Graph requests are represented by `Eio.Promise` resolvers and
  `Hashtbl` entries rather than by replayable operation ownership;
- stale or duplicate Engine completions are fenced through distributed identity
  checks instead of one worker transition boundary;
- the managed and non-managed paths have separate open, close, fatal-error,
  invalidation, and shutdown logic; and
- the Bonsai adapter is the only module that can compose the complete production
  worker, which makes headless contract testing unnecessarily expensive.

The desired architecture is:

```text
Bonsai Worker adapter / CLI host
  -> thin Logseq_db_worker driver
       -> Logseq_db_worker_pure_reducer.Core.step
            -> immutable next worker state
            -> ordered typed instructions
                 -> Logseq_db_worker_effect_runner.Effect_runner
                      -> Engine / SQLite / mirror filesystem
                      -> Logseq_sync_effect_runner.Effect_runner
                      -> Eio scheduling and cancellation
                      -> host responses and pushes
                      -> completion event posted to the worker mailbox
                           -> thin driver
                                -> Core.step
```

The feasibility question is whether this boundary can preserve Engine authority,
atomic mutation and outbox commits, synchronous Graph request semantics, sync
composition, and every existing target without putting runtime capabilities in
the pure state.

The answer is yes. There is no specification or type-system blocker. The current
coordinator already exposes almost every necessary asynchronous boundary as a
sync event or worker effect. The remaining work is a substantial architectural
refactor, not a protocol or storage redesign.

## Proposal

### Adopt one canonical worker reducer

Add a canonical worker pure-reducer API whose central operation is exactly:

```ocaml
type state
type event
type transition =
  { next : state
  ; effects : instruction list
  }

val initial : config -> (state, create_error) result
val view : state -> view
val step : state -> event -> transition
```

`state` is immutable and opaque. `initial` and `step` must not mutate their
arguments or process-global state and must not execute callbacks, Eio effects,
Engine operations, filesystem access, clocks, randomness, or publication.

The state owns all worker orchestration facts:

- target mode and initialization phase;
- immutable graph lifecycle state;
- worker, graph, engine-session, request, mutation-admission, and lifecycle
  generations;
- the optional nested `Logseq_sync_pure_reducer.Core.t` for managed targets;
- admitted and pending Graph requests keyed by pure request identifiers;
- pending worker-effect tickets and their expected scopes;
- managed attachment and local mutation ownership;
- invalidation publication policy; and
- shutdown state.

The state must not contain `Engine.t`,
`Engine.prepared_managed_mutation`, `Eio.Promise`, `Eio.Mutex`,
`Eio.Stream`, `Hashtbl`, `Worker.Session_context`, a function value, or a
mutable cancellation handle. Engine and prepared-resource identity is represented
by opaque scoped IDs only when an ID is actually required.

Graph lifecycle becomes a pure part of this state. Delete the mutable
`Graph_lifecycle` API instead of retaining a parallel lifecycle implementation.

### Compose the sync reducer as a pure child reducer

For managed targets, worker `state` contains the sync `Core.t`. Worker events
cover application commands, Graph requests, worker-runner completions, nested
sync-runner events, and shutdown. A private helper performs a nested sync step:

```text
worker event
  -> worker policy
  -> Sync Core.step when synchronization must advance
  -> store the returned sync next state
  -> translate each ordered sync instruction into a worker instruction
```

The worker reducer must not duplicate catalog, WebSocket, E2EE, checksum,
submission, or pull policy. `Logseq_sync_pure_reducer.Core` remains the sole
owner of those rules.

Translate the three sync instruction classes as follows:

- `Run sync_effect` becomes a worker instruction delegated to the existing sync
  effect runner;
- `Delegate worker_effect` enters worker reducer policy and normally produces a
  typed worker runner request; and
- `Publish output` becomes a typed public worker output while preserving its
  relative ordering with the other instructions.

Do not synchronously call worker `step` from either effect runner. Every
completion, including an immediately available Engine or filesystem result,
must be posted to the serialized worker mailbox. This prevents hidden recursive
state transitions and gives stale and duplicate completions one admission point.

### Use an explicit worker effect algebra

Define closure-free, typed worker requests and completions. The conceptual shape
is:

```ocaml
type engine_handle
type prepared_handle
type effect_id
type 'a ticket

type _ runner_request =
  | Open_engine : graph_open -> engine_opened runner_request
  | Close_engine : engine_handle -> unit runner_request
  | Execute_read : engine_handle * Protocol.request -> Protocol.response runner_request
  | Inspect_mutation : engine_handle * Mutation.t -> mutation_context runner_request
  | Commit_mutation : mutation_commit -> Mutation.success runner_request
  | Inspect_authoritative : engine_handle -> authoritative_facts runner_request
  | Commit_authoritative : authoritative_commit -> authoritative_result runner_request
  | Commit_outbox : outbox_commit -> string list runner_request
  | Inspect_mirror : mirror_request -> mirror_inspection runner_request
  | Activate_snapshot : snapshot_activation -> unit runner_request
  | Delete_mirror : mirror_deletion -> unit runner_request

type runner_effect = Request : 'a ticket * 'a runner_request -> runner_effect
type runner_completion =
  | Completion : 'a ticket * ('a, effect_error) result -> runner_completion

type instruction =
  | Run_worker of runner_effect
  | Run_sync of Logseq_sync_pure_reducer.Core.runner_effect
  | Publish of output
```

The exact request split may be refined while writing the `.mli`, but each
request must expose one authority boundary and one typed completion. Request and
completion payloads contain immutable facts, not callbacks or Engine values.

The reducer mints effect and scope identity, records the pending owner, consumes
each completion at most once, and rejects wrong-generation, wrong-engine,
duplicate, and unsolicited completions. The runner owns the actual Engine table,
prepared resources, Eio fibers, cancellation handles, and host waiters.

### Preserve Graph request semantics without promises in pure state

Wrap every host request in a pure worker request ID. The Bonsai adapter registers
the host waiter outside reducer state, posts the request event to the worker
mailbox, and waits outside the serialized reducer loop. A terminal `Reply`
output resolves that waiter.

The pure reducer records only request ownership and terminal status. This keeps
the existing requirement that a Graph mutation returns success only after the
projected database mutation and durable outbox record commit atomically, while
removing `Eio.Promise.u` and resolver callbacks from policy state.

The same request ID and graph scope fence late mutation, graph replacement,
fatal storage error, and shutdown completions. Exactly one transition publishes
the terminal reply. A later completion is ignored and may produce a redacted
diagnostic output.

### Keep transaction authority effectful and transaction policy pure

Purity does not mean moving SQLite or mutable Engine resources into `state`.
The worker reducer decides which operation is legal and what must happen next;
the runner performs storage and platform interactions and reports immutable
facts.

The current local mutation sequence becomes:

```text
Graph mutation request
  -> reducer admits request and asks for immutable Engine context
  -> runner reads basis, projected database, durable outbox, and time fact
  -> reducer performs pure validation and mutation planning
  -> reducer advances the nested sync reducer for local-batch encoding/crypto
  -> sync crypto is executed by the sync effect runner
  -> reducer emits an atomic managed-mutation commit request
  -> worker runner validates Engine generation and precondition, then commits
  -> completion re-enters the reducer
  -> reducer advances sync state, publishes invalidation, and replies
```

`Mutation_plan.plan` is already deterministic when given `now_ms` and a
`Datascript.db`. The pure planning portions currently embedded in
`Engine.prepare_managed_mutation`, `Engine.replan_managed_mutation`, and
`Managed_coordinator.replan_authoritative_outbox` should be extracted into pure
helpers used by the worker reducer. Clock values become explicit input facts.

The final Engine commit still revalidates an immutable precondition and graph
generation. This preserves atomicity and closes the time-of-check/time-of-use
window without retaining an Engine capability in reducer state. Obsolete
prepared-mutation paths should be deleted if the final commit request can carry
the complete immutable plan; do not keep both APIs.

Authoritative application follows the same pattern:

```text
sync worker effect
  -> reducer requests authoritative Engine facts
  -> runner returns precondition, checkpoint, database, and durable outbox
  -> reducer performs pure decode, replan, projection, and sync policy
  -> reducer requests one atomic authoritative commit
  -> runner revalidates and commits database, checkpoint, projection, and outbox
  -> reducer consumes the result before advancing the sync cursor
```

Database query execution, SQLite staging, ownership revalidation, file
installation, encryption primitives, and response-size encoding remain
effect-runner or Engine responsibilities. They are mechanisms, not worker state
transition policy.

### Cover managed and non-managed targets with one reducer

The refactor covers `Managed_sync`, `Snapshot`, `Import_snapshot`,
`Synced_mirror`, and `Native_local_graph`. The current `Managed` and
`Graph_bound` service branches become variants of one pure worker state machine.

Non-managed targets use the same open, close, request, fatal-error, invalidation,
and shutdown event/effect protocol without allocating a nested sync core. This
removes the existing duplicate lifecycle path. Do not preserve the current
`Graph_bound` path as a fallback or temporary compatibility coordinator.

### Make `logseq_db_worker.ml` the thin driver

After construction, the driver has only three responsibilities:

1. receive one serialized event from the worker mailbox;
2. replace the current immutable state with `Pure_reducer.step state event`.next;
3. submit the returned ordered instructions to `Effect_runner` in order.

Conceptually:

```ocaml
let dispatch t event =
  let transition = Pure_reducer.step t.state event in
  t.state <- transition.next;
  List.iter (Effect_runner.submit t.runner) transition.effects
```

The production implementation also needs bounded exception containment and
mailbox shutdown, but it must not pattern-match on domain events or effects.
Those decisions belong to the reducer or runner. It must not call `Engine`,
`Synced_mirror`, `Worker.Session_context`, or the sync effect runner directly.

The Bonsai service becomes an adapter that constructs dependencies, maps public
request and topic types, registers request waiters, posts events, and translates
published outputs. It contains no `Managed_coordinator`, graph lifecycle policy,
Engine calls, pending mutation table, or sync-step loop.

### Enforce the dependency direction physically

A same-library module split would improve names but would not prove purity and
would create cycles around the current umbrella module. Use the same physical
library approach as `logseq_sync`:

Create these canonical specification roots, mirroring the organization of
`logseq_sync/spec/pure_reducer` and `logseq_sync/spec/effect_runner`:

```text
logseq_db_worker/
├── spec/
│   ├── pure_reducer/
│   │   ├── dune
│   │   └── core.mli
│   └── effect_runner/
│       ├── dune
│       └── effect_runner.mli
└── lib/
    ├── pure_reducer/
    │   ├── dune
    │   ├── core.ml
    │   └── private pure planning helpers
    └── effect_runner/
        ├── dune
        ├── effect_runner.ml
        └── private Engine, mirror, mailbox, and host helpers
```

`logseq_db_worker/spec/pure_reducer/core.mli` is the canonical public contract
for worker state, events, typed instructions, completions, outputs, views,
`initial`, and `step`. `logseq_db_worker/spec/effect_runner/effect_runner.mli` is
the canonical public contract for constructing the runtime interpreter,
submitting worker instructions, posting completion events, and shutdown.

Like `logseq_sync/spec`, each spec directory defines a public virtual library and
contains interfaces only. Do not place an implementation `.ml`, adapter, type
conversion layer, or private helper in either spec directory. The selected
default implementations live in the corresponding `lib/pure_reducer` and
`lib/effect_runner` directories and use the exact nominal types declared by the
virtual modules.

The intended public module paths are:

```ocaml
Logseq_db_worker_pure_reducer.Core
Logseq_db_worker_effect_runner.Effect_runner
```

The Dune shape follows the existing sync libraries:

```lisp
; logseq_db_worker/spec/pure_reducer/dune
(library
 (name logseq_db_worker_pure_reducer)
 (public_name logseq_db_worker.pure_reducer)
 (modules core)
 (virtual_modules core)
 (default_implementation logseq_db_worker_pure_reducer_impl)
 ...)

; logseq_db_worker/spec/effect_runner/dune
(library
 (name logseq_db_worker_effect_runner)
 (public_name logseq_db_worker.effect_runner)
 (modules effect_runner)
 (virtual_modules effect_runner)
 (default_implementation logseq_db_worker_effect_runner_impl)
 ...)
```

The ellipses stand only for the final direct library dependencies and flags; the
module names, public names, virtual-module ownership, and source roots are part
of this decision. Do not add a combined spec directory, an umbrella virtual
module, or a second nominal copy of worker protocol types.

```text
logseq_db_worker.contract
  Config / Error / Protocol / public value types
           |
           +-----------------------+
           |                       |
           v                       v
logseq_db_worker.pure_reducer   logseq_db_worker.engine
           |                       |
           +-----------+-----------+
                       v
logseq_db_worker.effect_runner
           ^
           |
logseq_sync.effect_runner and logseq_sync.pure_reducer
           |
           v
logseq_db_worker       (thin driver and canonical facade)
           |
           v
logseq_db_worker.bonsai
```

The pure reducer may depend on the worker contract, `logseq_db_types`,
`datascript_ocaml`, and `logseq_sync.pure_reducer`. It must not depend on Eio,
Unix, SQLite, `logseq_db_storage`, Bonsai Flutter, the Engine implementation,
the sync effect runner, or native platform stubs.

The worker effect runner depends on the pure reducer, Engine implementation,
and both selected sync libraries. It is the only worker module that executes
worker effects. The thin driver depends on the selected pure reducer and effect
runner. The Bonsai adapter depends on the driver and Bonsai Worker APIs.

Use true module aliases in the canonical facade only where retaining current
`Logseq_db_worker.Config`, `Error`, and `Protocol` names is part of the selected
API. Do not duplicate their nominal types and do not add forwarding
implementations or deprecated paths.

This physical split requires explicit Dune changes during implementation. No
Dune or production source file is changed by this feasibility decision.

### Test the reducer before replacing the runtime

Add public-API-only reducer tests for exact state and ordered effects. At minimum
cover:

- all five target initializations and open success/failure;
- graph request admission before, during, and after lifecycle changes;
- managed local mutation success and every post-admission failure;
- duplicate mutation identity and fingerprint conflict;
- graph switch, account replacement, cache deletion, fatal Engine failure, and
  shutdown with pending requests;
- authoritative inspect, conflict, replan, commit, and stale completion;
- outbox transition success, rejection, and wrong-precondition completion;
- exact once-only replies and invalidations;
- duplicate, unsolicited, wrong-scope, and wrong-generation completions;
- composition traces that assert the exact translation of nested sync
  instructions; and
- deterministic replay from the same initial state.

Runner contract tests use fake Engine, mirror, sync-runner, clock, and host
dependencies. They prove resource ownership, completion posting, cancellation,
precondition revalidation, waiter resolution, and shutdown without retesting
worker policy.

Keep the existing Engine atomicity, storage, managed-sync end-to-end, Bonsai
service, Flutter adapter, CLI, source-boundary, and application tests as
integration gates. Replace source-text assertions that require
`Managed_coordinator` inside the Bonsai service with assertions for the new
dependency direction and thin adapter.

### Implement as one cutover, not two production coordinators

The work can be developed in testable internal batches, but the production
cutover must replace the old coordinator atomically:

1. specify the worker reducer event, effect, completion, output, and view types;
2. implement pure lifecycle and local-target traces;
3. add nested sync composition and managed mutation/authoritative traces;
4. implement the worker effect runner and fake-runner contracts;
5. add the thin driver and Bonsai adapter;
6. switch all targets and callers to the new path; and
7. delete `Managed_coordinator`, mutable `Graph_lifecycle`, direct Engine calls
   from the Bonsai service, and obsolete prepared or compatibility APIs.

Do not ship a runtime flag, fallback coordinator, mirrored state, compatibility
module, or migration layer.

## Alternatives considered

### Extract `Managed_coordinator` into another effectful module

This would make the Bonsai service shorter and is the lowest-cost refactor, but
the coordinator would retain mutable state, Eio promises and locks, direct
Engine calls, and non-replayable policy. It changes file placement without
creating the requested architecture.

### Make only `Graph_lifecycle` pure

An immutable graph lifecycle reducer is useful but covers only the existing
54-line facade state. Mutation admissions, sync worker effects, authoritative
commits, request replies, and non-managed runtime policy would remain effectful
and distributed.

### Reuse the sync reducer as the complete worker reducer

`Logseq_sync_pure_reducer.Core` deliberately does not own Engine lifecycle,
Graph protocol requests, local-target behavior, host replies, or SQLite commit
authority. Adding them would reverse the existing package boundary and make
sync depend on worker concepts. The worker needs its own reducer that composes,
rather than enlarges, the sync reducer.

### Store `Engine.t` and promises inside otherwise immutable reducer state

OCaml permits opaque mutable values inside an immutable record, so the type
would compile, but replaying a state would reuse live capabilities and promise
resolvers. This is nominal immutability rather than a pure reducer and is not
selected.

### Use OCaml 5 algebraic effects directly in `step`

`state -> event -> transition` would no longer describe all behavior if `step`
could call `Effect.perform`. OCaml 5.1 does not expose an effect row in the
function type, and missing handlers, captured continuations, cancellation, and
replay become dynamic concerns. Explicit request and completion values provide
the required audit boundary.

### Convert only the managed-sync branch

This would leave `Graph_bound` with a second mutable lifecycle and direct Engine
path, preserve duplicated shutdown and invalidation policy, and give
`logseq_db_worker` two canonical architectures. All targets are included in the
selected cutover.

### Keep pure reducer and effect runner in the existing library

This avoids Dune changes but permits the reducer implementation to import Engine,
SQLite, Unix, and Eio modules accidentally. It also creates a dependency cycle
if the umbrella `Logseq_db_worker` module is both the contract source and the
thin driver. A physical contract/reducer/engine/runner split is required.

## Acceptance criteria

- `Logseq_db_worker_pure_reducer.Core` exposes immutable `state`, explicit
  `event`, ordered `instruction`, `transition`, `initial`, `view`, and
  `step : state -> event -> transition`.
- `logseq_db_worker/spec/pure_reducer` contains exactly the canonical
  `core.mli` and its virtual-library `dune` file, following the
  `logseq_sync/spec/pure_reducer` layout.
- `logseq_db_worker/spec/effect_runner` contains exactly the canonical
  `effect_runner.mli` and its virtual-library `dune` file, following the
  `logseq_sync/spec/effect_runner` layout.
- The selected implementations live under `logseq_db_worker/lib/pure_reducer`
  and `logseq_db_worker/lib/effect_runner`; neither spec directory contains an
  `.ml` file, private helper, adapter, or duplicated contract type.
- The two installed public virtual libraries are
  `logseq_db_worker.pure_reducer` and `logseq_db_worker.effect_runner`, exposing
  `Logseq_db_worker_pure_reducer.Core` and
  `Logseq_db_worker_effect_runner.Effect_runner` respectively.
- Replaying the same event trace from the same initial state produces equal
  public views and equal ordered instructions.
- The pure reducer implementation contains no mutation, process-global counter,
  function-valued capability, Eio, Unix, SQLite, filesystem, Engine handle,
  promise, lock, callback invocation, or performed OCaml effect.
- The worker state contains no `Engine.t`, prepared Engine object, waiter, or
  cancellation handle; runtime resources are referenced only by scoped opaque
  identities.
- Managed state composes the exact public `Logseq_sync_pure_reducer.Core` types
  without a duplicate sync protocol or conversion layer.
- Every nested sync instruction is translated in order, and every sync or worker
  runner completion re-enters through the serialized worker mailbox.
- The worker reducer is the sole owner of graph lifecycle, request admission,
  pending-operation ownership, stale-completion rejection, reply policy,
  invalidation policy, and shutdown policy for all five targets.
- The worker effect runner is the sole owner of Engine resources, mirror
  filesystem operations, Eio runtime resources, sync effect-runner delegation,
  request waiters, and host effect execution.
- Local mutation success is published only after one atomic projection and
  durable-outbox commit; every admitted mutation receives exactly one terminal
  reply.
- Authoritative cursor state advances only after one atomic database,
  checkpoint, projection, and outbox commit.
- Engine generation and immutable preconditions are revalidated at every commit,
  so a pure inspect/plan/commit sequence cannot commit into a replacement graph.
- `logseq_db_worker/lib/logseq_db_worker.ml` only constructs or dispatches the
  reducer and runner and does not pattern-match on domain events or effects.
- `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` is a host adapter
  with no `Managed_coordinator`, direct `Engine` operation, mutable graph
  lifecycle, sync-step loop, or pending mutation table.
- The existing managed and `Graph_bound` runtime branches are removed rather
  than preserved as fallbacks.
- Source-boundary tests enforce the one-way dependency graph and purity
  restrictions.
- Reducer trace, runner contract, Engine atomicity, storage, service, end-to-end,
  application, Flutter adapter, CLI, source-boundary, and full repository tests
  pass.
- `dune build @all`, `dune build @fmt`, `dune runtest`, `git diff --check`, and
  `spec-dev-tool check --all` pass after implementation.

## Risks

- This is a large refactor. The current Bonsai service is not merely an adapter;
  it contains runtime behavior accumulated across graph lifecycle, sync, crypto,
  storage, and error-handling fixes.
- Making request completion event-driven can deadlock if the Bonsai request fiber
  occupies the only fiber capable of draining the mailbox. The driver needs one
  independent serialized event loop, and host waiters must live outside it.
- Ordered effect issuance does not imply ordered asynchronous completion.
  Tickets, scopes, and pending ownership must reject out-of-order or late results.
- Moving planning across the Engine boundary introduces a time-of-check/time-of-use
  window. Generation and precondition validation at atomic commit is mandatory.
- Nested sync transitions can accidentally be reduced twice if a worker effect
  is both translated and directly interpreted. Only the worker reducer may
  translate sync instructions; neither runner may call a reducer.
- `Datascript.db` values are treated as immutable domain facts. If any selected
  Datascript operation mutates its input observably, that operation must remain
  behind the runner boundary.
- A public virtual-library split changes the build graph and installation
  manifest. All callers and tests must switch atomically, with no compatibility
  aliases other than selected canonical facade aliases.
- Extracting clock-dependent planning requires every clock read to become an
  explicit input fact. Accidentally reading a clock in the reducer would break
  deterministic replay.
- Error values must remain bounded and sanitized when moving from runner
  completions into reducer diagnostics and public protocol failures.

## Consequences

- Worker orchestration becomes replayable and testable without Eio, SQLite,
  filesystem fixtures, Bonsai Worker sessions, or network dependencies.
- `logseq_db_worker.ml` becomes the actual composition root rather than a small
  facade beside an effectful Bonsai-owned coordinator.
- The Bonsai adapter becomes replaceable by a headless or alternative host using
  the same worker driver.
- Graph lifecycle, local and managed targets, sync composition, pending requests,
  and shutdown share one state machine and one stale-completion policy.
- Engine and storage remain worker-owned effectful capabilities; the architecture
  does not move database authority into `logseq_sync`.
- More intermediate event and effect types are required. This explicit protocol
  is the cost of deterministic replay, typed completion ownership, and removing
  hidden continuations.
- The refactor is feasible but medium-to-high risk and should be implemented as
  an architecture change with reducer-first tests, not as a file-move cleanup.

## Questions

None. The requested whole-package conversion, thin driver, pure `step` API, and
the required `logseq_db_worker/spec/pure_reducer` and
`logseq_db_worker/spec/effect_runner` virtual-library roots determine the
selected boundary. The repository rule against compatibility paths remains in
force.
