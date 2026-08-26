# Type-Enforced Offline Startup Boundaries Implementation Plan

Goal: Make every offline-ready managed-sync warm start incapable of constructing or executing network work before the first local Timeline frame is presented.

Architecture: Replace the flat sync-manager action variant with a capability-indexed GADT that distinguishes local actions from network-lane actions.
Represent presentation progress with abstract restoring and presented witnesses, and require either a presented witness or an explicit online-recovery witness before network actions can be constructed.

Tech Stack: OCaml 5.1.1, GADTs, abstract module interfaces, Dune virtual libraries, Eio, Bonsai Flutter worker services, repository test helpers, and source-boundary tests.

Related: Builds on `docs/agent-guide/implemented/architecture/2026-08-25-local-timeline-nonblocking-network-startup.md`, `docs/agent-guide/proposed/architecture/2026-08-26-keychain-backed-wrapped-graph-key-cache.md`, and `docs/agent-guide/proposed/testing/2026-08-26-encrypted-offline-warm-start-validation.md`.

## Problem

`Sync_manager.action` is one flat variant containing local mirror and engine work, authentication challenges, HTTP requests, WebSocket operations, timers, and network-derived engine mutation.
Both `Sync_manager.handle_command` and `Sync_manager.handle_event` return an unrestricted `action list`.
Any branch can therefore emit `Need_id_token`, `Fetch_e2ee_graph_key`, or `Connect_websocket` before `Timeline_presented`, and the compiler cannot distinguish that mistake from a valid local startup effect.

The existing `startup_presentation` variant records `Restoring_local`, `Local_feed_ready`, `Timeline_presented`, and `Reconciled`, but it is data inside a mutable snapshot rather than a capability required by network-producing functions.
Code can inspect or ignore that field and call `challenge` directly.
The current encrypted mirror branch does exactly that by routing every encrypted graph through `start_e2ee`, which immediately creates an `E2ee_key_access` token challenge.

Runtime assertions cover many existing transitions, but they only detect constructors after the manager has emitted them.
They do not make an offline-ready branch unrepresentable when a future refactor accidentally adds authentication, HTTP, WebSocket, or reconnect work.

The desired invariant is stronger than merely allowing network operations to run concurrently.
When local account binding, cached selection, and an admitted mirror are usable, no network action may be constructed or scheduled until the local Timeline frame has been acknowledged.
For an encrypted graph, the offline-ready condition additionally requires a usable wrapped graph key and private key.
When any local prerequisite is missing, the state machine may enter a separately typed online-recovery branch before presentation.

Two interface specifications record the intended contract before implementation.
They are compiled as virtual modules rather than copied into the production source
tree as ordinary interfaces.

| Specification | Responsibility |
| --- | --- |
| `spec/sync_action.mli` | Classify every manager effect as `local action` or `network action`, hide construction behind typed factories, and require a network permit for operations that can start or schedule online work. |
| `spec/sync_startup_phase.mli` | Make `restoring witness` and `presented witness` distinct abstract types, validate the Timeline acknowledgement, and mint network permits only after presentation or through explicit online recovery. |

The virtual specification library defines its own scope, graph-identity, graph
metadata, authentication-purpose, and snapshot payload contract types. It depends
only on external packages such as `uri`, never on the production library that
implements it. Production modules convert their internal catalog, authentication,
and bootstrap values at this boundary, so the virtual library cannot form a Dune
dependency cycle.

## Validation approach

Add behavior-first sync-manager tests for unencrypted offline-ready startup, an encrypted cache hit, cache miss, corrupt cached key, stale Timeline acknowledgement, graph switch, account switch, sign-out, and post-presentation reconciliation.
The cache-hit test will drive the complete local manager sequence and assert that only local actions are emitted until the current-generation Timeline acknowledgement produces a presented witness.
The cache-miss test will assert that the local transition returns an explicit online-recovery value and emits no network action by itself.
The recovery test will then consume that value and assert that an `E2ee_key_access` challenge becomes possible only in the recovery branch.
The recovery test must obtain that value from a matching sealed local-failure
receipt. It must prove that a caller holding only a restoring witness or a textual
recovery reason cannot mint online recovery.

Add scope tests that retain an old permit across account, graph, connection, and
presentation generation changes. Action constructors must derive identity and
generation fields from the permit rather than accepting independent integers, and
the manager must reject the stale scope before execution.

Add Bonsai worker-service tests that run the encrypted offline-ready sequence with Auth, HTTP, WebSocket, pull, and reconnect executors configured to fail immediately if invoked.
The test must open the local engine and reach the Timeline presentation command with every network invocation counter remaining zero.
After presentation, it must observe that reconciliation can acquire a permit and start the expected authentication challenge.

Add application integration coverage that uses a cached encrypted graph and never supplies a network executor completion.
The assertion is behavioral: the same local feed is presented, the startup does not emit an auth push before that frame, and an online recovery is reported instead of silently stalling when the local wrapped key is unavailable.

Extend `test/source_boundary_test.ml` to require the typed action and phase modules and to forbid direct Auth, HTTP, or WebSocket execution from the local-action interpreter.
This complements the OCaml types because OCaml does not globally track arbitrary side effects imported by a module.

Run the focused tests with `dune exec ./logseq_db_worker/test/test_sync_manager.exe` and `dune exec ./logseq_db_worker/test/test_bonsai_service.exe`, and expect both executables to exit successfully.
Run application integration and source-boundary tests with `dune exec ./test/logseq_db_worker_application_integration_test.exe` and `dune exec ./test/source_boundary_test.exe`, and expect both executables to exit successfully.
Run the full suite with `dune runtest` and expect no regression.

NOTE: I will write *all* tests before I add any implementation behavior.

## Decision

### Compile `spec/` as the canonical Dune virtual library

Add `spec/dune` and define `Sync_action` and `Sync_startup_phase` as the virtual
modules of one specification library. The checked-in `spec/*.mli` files are the
only canonical signatures for these modules.

```lisp
(library
 (name logseq_db_worker_sync_spec)
 (package logseq_db_worker)
 (wrapped false)
 (modules sync_action sync_startup_phase)
 (virtual_modules sync_action sync_startup_phase)
 (default_implementation logseq_db_worker_sync_impl)
 (libraries uri))
```

The existing `logseq_db_worker` library consumes
`logseq_db_worker_sync_spec` and excludes the two implementation modules from its
own module set. A dedicated production implementation library owns only the two
virtual implementations and declares:

```lisp
(library
 (name logseq_db_worker_sync_impl)
 (package logseq_db_worker)
 (modules sync_action sync_startup_phase)
 (implements logseq_db_worker_sync_spec)
 (libraries uri))
```

The virtual library selects this dedicated library as its default implementation
for production executables and tests. The dedicated implementation provides
`sync_action.ml` and `sync_startup_phase.ml`. Do not copy the virtual
`.mli` files into `logseq_db_worker/lib`, generate parallel interfaces, or retain
an ordinary non-virtual implementation path. Dune must check every production
implementation directly against the signatures under `spec/`.

Do not add `(implements ...)` to the existing `logseq_db_worker` library. Dune
does not allow an implementation library to introduce additional public modules;
using the existing multi-module library as the implementation would make its
other modules private. The dedicated implementation library avoids that accidental
API collapse while keeping the virtual contract canonical.

The virtual signatures own minimal transport-free contract values for graph
identity, graph metadata, authentication purpose, snapshot metadata, and startup
scope. They do not refer to `Sync_catalog`, `Sync_auth`, `Sync_bootstrap`, or other
modules owned by `logseq_db_worker`. The dedicated implementation library also
does not depend on `logseq_db_worker`, avoiding a dependency cycle through the
consumer of the virtual library. Production manager code performs one explicit
conversion at the contract boundary and does not retain a parallel legacy action
interface.

### Use one capability-indexed action GADT

Introduce abstract marker types and index every action by the lane permitted to emit it.

```ocaml
type local
type network
type account
type graph
type connection

type _ action =
  | Inspect_mirror : inspect_mirror -> local action
  | Load_and_verify_wrapped_graph_key : wrapped_key_lookup -> local action
  | Verify_and_save_wrapped_graph_key : wrapped_key_save -> local action
  | Delete_wrapped_graph_key : graph_cleanup -> local action
  | Delete_account_secrets : account_cleanup -> local action
  | Open_graph : open_graph -> local action
  | Need_id_token : scoped_challenge -> network action
  | Fetch_e2ee_graph_key : fetch_e2ee_graph_key -> network action
  | Connect_websocket : connect_websocket -> network action
```

The full specification classifies all existing constructors rather than maintaining a second legacy action variant.
`Activate_snapshot`, `Apply_sync_frame`, and `Recover_submitted` are classified as network-lane actions because they are consequences of online bootstrap or reconciliation even when their interpreter ultimately mutates local state.
`Close_websocket` is a network-lane action but does not require a permit because closing an existing transport cannot initiate online work.

An offline startup transition returns only `local action list`.
The following accidental change must fail to type-check.

```ocaml
let invalid : local action list =
  [ Need_id_token challenge ]
```

The shared Eio queue can carry `packed action` values only after a typed planner has produced them.
Existential packing belongs at the worker dispatch boundary and must not become the return type of the offline startup planner.

### Derive every network action from a scoped permit

Expose action constructors as private so the service can pattern-match them while callers cannot construct network actions directly.
Use account-, graph-, and connection-scoped permits. Every permit contains the
managed sync origin, user and graph identity appropriate to its level, all relevant
generations, and an opaque permit ID.

Provide smart constructors that derive action scope from the permit. Do not accept
independent identity or generation arguments.

```ocaml
val need_id_token : 'scope network_permit -> auth_purpose -> network action
val fetch_catalog : account network_permit -> token:string -> network action
val fetch_e2ee_graph_key : graph network_permit -> token:string -> network action
val connect_websocket : connection network_permit -> token:string -> network action
```

The manager retains the permit and its sealed scope across an asynchronous token
challenge so handling `Provide_id_token` cannot replace old scope fields with the
current snapshot. Every async completion returns the original scope.

Types prevent mixing independently supplied scope fields, but they cannot revoke a
value after mutable runtime state advances. Immediately before action emission and
again on completion, the manager compares the permit scope with its current scope.
Account, graph, connection, or presentation changes clear retained permits and
challenges. A stale permit or completion is ignored.

### Represent presentation as an abstract phase witness

Use abstract phantom-indexed witnesses rather than a freely constructible presentation variant.

```ocaml
type restoring
type presented
type _ witness

val acknowledge_timeline
  : restoring witness
  -> timeline_ack
  -> presented witness option

val permit_reconciliation
  : presented witness
  -> graph network_permit
```

Only a current account, graph, and presentation generation acknowledgement can produce `presented witness`.
A caller holding `restoring witness` cannot call `permit_reconciliation`.

Local prerequisite actions return opaque request receipts. Only a matching failed
completion can create a sealed failure receipt, and only that receipt can produce
online recovery.

```ocaml
type 'kind local_request
type 'kind failure_receipt

val recover
  : restoring witness
  -> 'kind failure_receipt
  -> online_recovery option

val permit_recovery
  : online_recovery
  -> (graph network_permit, [ `Already_consumed ]) result
```

There is no public function that accepts a caller-selected `recovery_reason` and
mints authority. The reason is a read-only projection of the failure receipt for UI
and diagnostics. `recover` validates request nonce and startup scope, and returns
`None` for stale or mismatched receipts. Consuming the recovery ticket returns
`Error `Already_consumed` on every later attempt, so it cannot authorize a second
recovery sequence.

No local account binding or cached selection means no offline-ready restore witness
exists and follows the existing cold-start authentication entry point. The sealed
recovery protocol covers failures after a scoped offline-ready candidate has been
created: mirror admission, wrapped-key verification, private-key availability, and
local graph open.

### Serialize the complete wrapped-key lifecycle

Classify wrapped-key load-and-verify, verify-and-save, graph deletion, and account
secret deletion as local actions. Load failure returns a scoped failure receipt.
Save failure is non-secret diagnostic state and does not fail the current online
session. Delete actions are idempotent cleanup effects.

Sign-out advances the account generation before emitting
`Delete_account_secrets` with the captured old account identity. The serialized
local interpreter executes all earlier secret writes before that cleanup, so an
in-flight save cannot recreate a key after sign-out. Cleanup completion may update
only diagnostics and cannot mutate a replacement account.

The manager, phase witnesses, actions, and events carry only verified wrapped keys.
Plaintext graph keys are abstract `Sync_graph_key.t` values owned by the Engine
crypto boundary. `Sync_e2ee_session` stores no plaintext key, and
`Activate_snapshot` carries a wrapped key that Engine unwraps internally.

### Keep decision and execution ownership separate

Preserve `Sync_manager` as the serialized state-machine owner and `Logseq_db_worker_bonsai_service` as the only production action interpreter.
Split its interpreter entry points by capability before existentially packing general queue work.

```text
Offline-ready input
  -> restoring witness
  -> local action list
  -> local interpreter
  -> local feed and frame acknowledgement
  -> presented witness
  -> network permit
  -> network action list
  -> network interpreter

Missing local prerequisite
  -> online_recovery
  -> network permit
  -> authenticated recovery
```

The local interpreter receives Keychain, mirror, engine, and presentation capabilities.
It does not receive Auth, HTTP, WebSocket, pull, or reconnect capabilities.
The network interpreter is the only entry point that can call those facilities.

### Implementation record

#### Step 1: Add failing manager behavior tests

1. Extend `logseq_db_worker/test/test_sync_manager.ml` with an unencrypted offline-ready fixture and an encrypted offline-ready fixture containing a cached catalog, admitted mirror, local private key, and locally loaded wrapped graph key.
2. Drive the fixture through mirror inspection, local key loading, graph open, local feed readiness, and Timeline acknowledgement.
3. Assert before implementation that the current manager incorrectly emits `Need_id_token` and record the failing result.
4. Add cache-miss and stale-acknowledgement cases that assert explicit online recovery and generation fencing.
5. Add a negative capability test proving that a restoring witness and
   `recovery_reason` alone cannot create recovery, plus stale-permit tests for every
   generation.
6. Run `dune exec logseq_db_worker/test/test_sync_manager.exe` and confirm the new assertions fail for the intended reason.

#### Step 2: Introduce the capability-indexed action module

1. Add `spec/dune` with `sync_action` and `sync_startup_phase` listed under
   `virtual_modules` in `logseq_db_worker_sync_spec`.
2. Define minimal graph identity, graph metadata, authentication purpose, snapshot
   payload, and scope types inside the virtual signatures so they do not refer to
   production-owned modules.
3. Make the existing `logseq_db_worker` library depend on
   `logseq_db_worker_sync_spec` and exclude `sync_action` and
   `sync_startup_phase` from its own module set.
4. Add the dedicated `logseq_db_worker_sync_impl` library with only those two
   modules and `(implements logseq_db_worker_sync_spec)`. Select it through the
   virtual library's `default_implementation`.
5. Create `logseq_db_worker/lib/sync_action.ml` with private-constructor smart
   constructors and existential packing. Do not create or copy
   `logseq_db_worker/lib/sync_action.mli`.
6. Move every payload and constructor from `Sync_manager.action` into `Sync_action`
   and classify it exactly once.
7. Update `logseq_db_worker/lib/sync_manager.mli` and
   `logseq_db_worker/lib/sync_manager.ml` to use typed local, network, and packed
   actions.
8. Compile the production implementation through Dune and fix signature,
   exhaustiveness, or capability mismatches without weakening the virtual
   interfaces.

#### Step 3: Introduce the presentation witness

1. Create `logseq_db_worker/lib/sync_startup_phase.ml` as the production
   implementation of the virtual `spec/sync_startup_phase.mli`. Do not create or
   copy `logseq_db_worker/lib/sync_startup_phase.mli`.
2. Keep generation-bearing witness, scoped local-request, failure-receipt,
   recovery-ticket, and permit representations hidden by the virtual interface.
3. Replace the mutable `startup_presentation` decision field with an existentially stored phase witness plus a read-only snapshot projection for diagnostics and UI status.
4. Make the Timeline acknowledgement transition validate account, graph, and presentation generations before returning a presented witness.
5. Make local prerequisite failures return sealed failure receipts; validate those
   receipts before returning `online_recovery` without constructing network
   actions.
6. Record recovery-ticket consumption and reject reuse.
7. Run the focused manager tests and confirm stale acknowledgement, fabricated
   recovery, stale failure receipt, and recovery reuse cases pass.

#### Step 4: Gate every network-producing manager path

1. Change `challenge`, token-response routing, catalog refresh, bootstrap, E2EE fetch, WebSocket connection, pull, transaction submission, reconnect, and foreground probe helpers to require the correctly scoped current `network_permit`.
2. Remove independent identity and generation arguments from network smart constructors.
3. Preserve the permit across token challenge issuance and validate its original
   scope again when `Provide_id_token` arrives.
4. Mint reconciliation permits only from a presented witness.
5. Mint pre-presentation permits only from a validated, unconsumed online-recovery ticket.
6. Treat sign-out and transport close as teardown that can cancel or close existing work but cannot initiate new requests.
7. Run `dune exec logseq_db_worker/test/test_sync_manager.exe` and confirm all manager behaviors pass.

#### Step 5: Split the worker interpreters

1. Update `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` so local and network action interpreters are distinct functions.
2. Give the local interpreter access only to mirror, Keychain, engine, cache, and local event enqueueing operations.
3. Keep Auth push emission, HTTP, WebSocket, pull, submission, and timers in the network interpreter.
4. Pack actions only at the common serialized queue boundary.
5. Add a worker-service test whose network facilities fail if called before presentation.
6. Run `dune exec logseq_db_worker/test/test_bonsai_service.exe` and confirm the offline-ready test reaches graph open with zero network calls.

#### Step 6: Integrate wrapped-key loading

1. Add scoped `Load_and_verify_wrapped_graph_key`,
   `Verify_and_save_wrapped_graph_key`, `Delete_wrapped_graph_key`, and
   `Delete_account_secrets` local actions and completion events.
2. Update `logseq_db_worker/lib/sync_e2ee_session.mli` and
   `logseq_db_worker/lib/sync_e2ee_session.ml` to retain only the wrapped key and
   verification state, with no plaintext graph-key field.
3. Introduce abstract `Sync_graph_key.t` for Engine crypto operations and remove
   plaintext strings from action and event payloads.
4. Change `Activate_snapshot` to carry a wrapped key and perform unwrap inside the
   Engine crypto boundary.
5. Update the shared native and worker bridge files selected by the Keychain
   architecture decision to implement the scoped verify, save, and cleanup
   operations.
6. Keep cache miss, corrupt item, and missing private key in the sealed
   online-recovery branch.
7. Run the manager, E2EE session, Engine, native host, and worker-service tests.

#### Step 7: Enforce source and application boundaries

1. Extend `test/source_boundary_test.ml` to require the `spec/` virtual-library
   stanza, the dedicated `logseq_db_worker_sync_impl` implementation stanza, the
   existing `logseq_db_worker` consumer dependency, absence of copied production
   `.mli` files, and prohibition of direct network modules from the local
   interpreter.
2. Extend `test/logseq_db_worker_application_integration_test.ml` with a network-unavailable encrypted warm-start fixture.
3. Assert that the local Timeline is presented before any auth push or network executor invocation.
4. Run `dune exec test/source_boundary_test.exe` and `dune exec test/logseq_db_worker_application_integration_test.exe`.
5. Run `dune runtest` and require the complete suite to pass.

#### Step 8: Finish the decision lifecycle

1. Record final sign-out, accessibility, revocation, device-gate, CI-lane, and
   explicit-recovery decisions in the dependent architecture and testing docs.
2. Preserve the failing-test-first capability and manager evidence.
3. Run every focused, application, native, Flutter, and full-suite gate.
4. Run `spec-dev-tool check --all` before and after dependency-ordered lifecycle
   transitions.

No implementation file was added under `spec/`. The user-authorized contract
revision changed only the canonical `spec/*.mli` interfaces.
Dune changes are limited to defining the virtual specification, its production
consumer dependency, and the dedicated implementation stanza. No task modifies
an OCaml file in the bonsai_flutter repository.

## Alternatives considered

### Keep the flat action variant and add runtime assertions

Rejected because every manager branch remains able to construct network work before presentation.
Tests would detect known violations but could not make them unrepresentable.

### Split actions into two ordinary variants

Rejected because a GADT retains one exhaustive action family for the interpreter while allowing planners to return `local action list` or `network action list` precisely.
An ordinary wrapper sum would make it easier for the offline planner to return a general packed list accidentally.

### Use only a Boolean `timeline_presented` flag

Rejected because any function can ignore or overwrite a Boolean.
An abstract presented witness can be required as a function argument and cannot be manufactured by ordinary callers.

### Forbid all pre-presentation networking without a recovery branch

Rejected because cold start, missing cache, corrupt wrapped key, and missing private key must still be able to authenticate and recover.
The explicit recovery capability preserves that product behavior without weakening the offline-ready path.

### Adopt a new OCaml effect-system library

Rejected as unnecessary for this boundary.
GADTs, abstract module types, capability values, the existing serialized effect interpreter, and source-boundary tests provide the required constraint without a new runtime dependency.

## Acceptance criteria

- `spec/sync_action.mli` defines one private capability-indexed action GADT covering
  every current manager action plus the complete local wrapped-key lifecycle.
- `spec/sync_startup_phase.mli` defines abstract restoring and presented witnesses, explicit online recovery, and abstract network permits.
- The virtual signatures define their own minimal contract DTOs and do not depend
  on `Sync_catalog`, `Sync_auth`, `Sync_bootstrap`, or the production implementation.
- `spec/dune` defines both interfaces as the `virtual_modules` of
  `logseq_db_worker_sync_spec`.
- The existing `logseq_db_worker` library consumes the virtual specification, while
  the dedicated `logseq_db_worker_sync_impl` library uses
  `(implements logseq_db_worker_sync_spec)`, owns only the two implementation
  modules, and cannot compile when either `.ml` violates its virtual signature.
- Production executables and tests select `logseq_db_worker_sync_impl` as the
  virtual library's default implementation.
- No copied or generated `sync_action.mli` or `sync_startup_phase.mli` exists in
  the production implementation directory.
- The implemented offline-ready manager API returns only `Sync_action.local Sync_action.t list` before Timeline acknowledgement.
- No function can construct a request-starting network action without a current presentation or validated recovery permit.
- No caller can create online recovery from a restoring witness and a caller-chosen
  reason; a matching sealed local-failure receipt is required.
- Network actions derive identity and generations exclusively from their scoped
  permit and accept no independent scope fields.
- A restoring witness cannot be supplied to the reconciliation permit function.
- Cache miss and other local prerequisite failures produce an explicit recovery capability without emitting network work in the same transition.
- A stale account, graph, or presentation acknowledgement cannot produce a presented witness or network permit.
- Stale local completions, recovery tickets, permits, token challenges, and network
  completions are rejected by runtime scope validation.
- Wrapped-key load, verified save, graph deletion, and account-secret deletion are
  serialized local actions with generation-scoped completions.
- The production worker retains one serialized manager and engine owner while separating local and network interpreters.
- Both unencrypted and locally key-complete encrypted offline-ready integration paths reach the local Timeline with no Auth, HTTP, WebSocket, pull, or reconnect invocation.
- Post-presentation reconciliation and explicit online recovery retain current catalog, E2EE, WebSocket, pull, and submission behavior.
- No obsolete flat action type, compatibility wrapper, fallback constructor, or parallel legacy manager API remains.
- No `spec/*.ml` file, alternate non-virtual implementation path, or bonsai_flutter
  OCaml file exists or changes.

## Implementation evidence

`spec/dune` now defines the canonical virtual library and the production Dune
stanza implements it with only `sync_action.ml` and `sync_startup_phase.ml`.
`Sync_action` is a private-constructor local/network GADT with permit-requiring
network factories and a capability-preserving queue classifier. The obsolete flat
manager action type and every legacy constructor path were removed.

`Sync_manager` stores abstract restoring/presented witnesses and scoped permits.
The typed `open_selected_graph_local` planner returns only
`Sync_action.local Sync_action.t list`; existential packing happens after that
planner. Timeline acknowledgement is the only reconciliation-permit source.
Mirror, wrapped-key, and private-key failures are sealed by the local interpreter,
validated against their restore witness, projected as `Recovering_online`, and
produce no network action in the failure transition. A separate command consumes
the one-shot ticket; replayed receipts and tickets are rejected.

The worker has exhaustive `interpret_local_action` and
`interpret_network_action` entry points. Local code owns mirror, Keychain, Engine,
and cleanup work; network code owns Auth, HTTP, WebSocket, pull, submission, and
timers. Source-boundary tests require the split, require receipt creation in the
worker, forbid receipt creation in the manager, and require the local-only planner
type.

The encrypted compiled fixture reaches local Engine open and Timeline
presentation with no pre-presentation auth push. Focused capability, manager,
E2EE-session, Engine, worker-service, application-integration, and source-boundary
tests pass. The complete `dune runtest` suite, Flutter analyze/tests, standalone
Swift harness, signed macOS RunnerTests, isolated real-Keychain macOS lane, iOS app
build, and iOS RunnerTests build-for-testing also pass.

## Consequences

Adding a network-producing sync effect now requires a capability classification,
a scoped permit factory, manager scope validation, and execution in the network
interpreter. Adding a local startup prerequisite requires a scoped request and a
sealed completion. This increases the number of boundary types, but makes the
offline-ready planner and recovery transition reviewable at compile time and
removes the obsolete unrestricted manager action surface.

## Risks

- Existentially packing actions too early would erase the compile-time distinction and recreate the current unrestricted list under another name.
- A public network constructor would allow callers to bypass the permit even if the GADT index remains correct.
- A permit retained across asynchronous token work could become stale after account, graph, connection, or presentation generation changes.
- OCaml does not prevent a local interpreter from directly importing and calling a network module, so source and module ownership checks remain necessary.
- Classifying network-derived local mutations such as `Activate_snapshot` and `Apply_sync_frame` changes several existing tests and may expose hidden pre-presentation behavior.
- Strictly delaying reconciliation for offline-ready startup strengthens the earlier nonblocking-network decision and may delay revocation discovery until the first Timeline frame.
- The action refactor touches one large exhaustive interpreter and a broad manager test suite, so intermediate commits may compile only after a complete small batch is applied.
- If a virtual signature refers directly to a module owned by its production
  implementation, Dune will expose a dependency cycle. The virtual signatures own
  minimal boundary DTOs and production converts values exactly once.
- Adding `(implements ...)` directly to the existing multi-module
  `logseq_db_worker` library would make every module that does not implement a
  virtual module private. The dedicated implementation library is required to
  preserve the intended production module surface.

## Testing Details

The tests exercise observable startup behavior rather than asserting only that marker types exist.
They prove that a real manager and worker sequence with valid local encrypted prerequisites reaches graph open and Timeline presentation while fail-fast network facilities remain unused.
Recovery, generation fencing, teardown, and post-presentation reconciliation tests demonstrate that the stronger local boundary does not remove required online behavior.

## Implementation Details

- Use private GADT constructors and smart constructors instead of exposing an unrestricted network variant.
- Treat `spec/*.mli` as compiled virtual interfaces and the single source of truth;
  never copy them into the production library.
- Make the production modules implement `logseq_db_worker_sync_spec` through Dune
  `(implements ...)` in a dedicated two-module implementation library so signature
  conformance is a build invariant without privatizing unrelated modules.
- Keep existential packing at the serialized service queue boundary.
- Store phase witnesses and permits with every generation, derive all network action
  scope fields from permits, and retain runtime checks for temporal freshness
  because types cannot revoke old values after state mutation.
- Preserve the public snapshot presentation enum only as a projection, not as authority.
- Require a permit for token challenges and every request-starting or
  request-scheduling action; transport close remains permit-free because it cannot
  initiate network work.
- Return explicit online recovery only from a matching sealed local-failure receipt.
- Keep plaintext graph keys out of manager/session/action/event strings and confine
  them to abstract `Sync_graph_key.t` values inside the Engine crypto boundary.
- Remove the obsolete flat action type in the same change, with no compatibility
  path or migration layer.

## Decisions

- `spec/sync_action.mli` and `spec/sync_startup_phase.mli` are Dune
  `virtual_modules` in one canonical virtual specification library. Production
  supplies `.ml` implementations through a dedicated `(implements ...)` library,
  and does not duplicate their `.mli` files. The existing `logseq_db_worker`
  library consumes the virtual contract instead of implementing it directly.
- The virtual signatures own minimal boundary DTOs and have no dependency on
  production-owned sync modules.
- Recovery authority comes only from a scope-matched sealed local-failure receipt;
  `recovery_reason` is diagnostic data and cannot mint a permit.
- Network actions derive all identity and generation fields from account-, graph-,
  or connection-scoped permits. Runtime scope validation rejects temporal staleness.
- Wrapped-key load/verify, verify/save, graph cleanup, and account-secret cleanup
  are serialized local actions.
- Plaintext graph keys use abstract `Sync_graph_key.t` only inside the Engine crypto
  boundary and do not enter manager actions, events, or E2EE session state.
- The strict zero-network-before-presentation rule applies uniformly to every
  offline-ready managed-sync warm start. An encrypted graph is offline-ready only
  when all required local key material is usable; otherwise it enters explicit
  online recovery.
- All network GADT constructors are private and can be created only through smart
  constructors that require a current `network_permit`.
- `Activate_snapshot`, `Apply_sync_frame`, and `Recover_submitted` are network-lane
  actions because they are consequences of online bootstrap or reconciliation,
  even though their executors mutate local engine state.

## Questions

- None.

---
