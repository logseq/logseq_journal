# Complete Managed Mutation Failures

## Problem

A managed mutation becomes asynchronous after the worker successfully prepares
it. `Managed_coordinator.begin_mutation` creates an `Eio.Promise`, stores its
resolver in `pending_mutations`, sends `Core.Local_batch_prepared`, and returns
`Await_mutation`. The public Graph request then waits for that Promise before it
can return a response.

The service uses `Worker.Service.Serial`, so the waiting request occupies the
only request lane. Sync completions can still enter through the worker-owned
daemon, but later Graph requests and client commands cannot complete until the
mutation Promise resolves.

Failures before Promise registration are bounded: reading or decoding the
outbox, preparing the Engine mutation, or constructing `local_batch_input`
returns an immediate protocol failure. The defect begins after admission into
`pending_mutations`.

The Core-to-worker contract has only a successful terminal action,
`Commit_local_batch`, and only a successful completion event,
`Local_batch_committed`. It has no operation-correlated rejection effect.
Several reachable post-admission paths therefore lose the completion:

- local planning failure enters `catalog_failed` without notifying the worker;
- encryption, protected-value replacement, transaction encoding, and outbox
  encoding failures also update only Core state;
- account replacement, sign-out, graph replacement, catalog revocation, cache
  replacement, and shutdown can clear or cancel Core-owned pending plans without
  resolving the worker Promise;
- runner cancellation suppresses `Runner_completed`, so canceled crypto cannot
  accidentally provide the missing terminal event; and
- `Detach_graph` and Engine close do not drain scoped entries from
  `pending_mutations`.

The coordinator currently removes and resolves an admitted mutation only while
handling `Commit_local_batch`. One failure can therefore leave the Promise
unresolved forever and starve every later request accepted by the same Serial
service.

Failure mapping is also too coarse. `mutation_failure` maps planning, crypto,
scope closure, Engine availability, persistence, and lifecycle failures to
`Unsupported_semantics`, so callers cannot distinguish an invalid request from
a valid request abandoned because its account or graph closed.

The intended local success boundary is the atomic Engine commit of optimistic
projection plus durable outbox record. Remote submission and acknowledgement
happen later and must not own the original Graph response. The current contract
defines the successful half of that local lifecycle but not the failing half.

## Proposal

Adopt one completion invariant:

> Once an operation enters `pending_mutations`, exactly one terminal outcome
> must retire it: durable local commit, explicit local rejection, or lifecycle
> cancellation.

Replace the success-only worker action with one exhaustive operation-correlated
completion. Its conceptual shape is:

```ocaml
type local_batch_failure_kind =
  | Planning_failed
  | Encryption_failed
  | Encoding_failed
  | Scope_closed
  | Engine_unavailable
  | Persistence_failed

type local_batch_action =
  | Commit of { outbox_records : string list }
  | Reject of
      { kind : local_batch_failure_kind
      ; message : string
      }

type local_batch_completion_request =
  { operation_id : graph_id
  ; scope : graph_scope
  ; action : local_batch_action
  }
```

The exact names belong in the canonical `.mli`, but this should replace obsolete
success-only `Commit_local_batch` behavior rather than add a compatibility path.

Core must emit a correlated rejection for every error reached after
`Local_batch_prepared` is admitted:

- local batch planning;
- protected-value encryption or replacement;
- transaction encoding;
- outbox record encoding; and
- cancellation of a pending plan at a graph or account boundary.

Changing public sync state is not a mutation completion. If a failure should
also pause or fail sync, the same reducer transition must emit both the state
change and the correlated rejection.

The coordinator must retain immutable admission ownership with each pending
entry: operation ID, graph scope, Engine instance, basis at admission, prepared
mutation, and resolver. Use one terminal helper that:

1. finds the operation by ID;
2. verifies the supplied scope and Engine instance;
3. removes the entry before invoking its resolver;
4. resolves it exactly once;
5. diagnoses duplicate or stale completions without applying them; and
6. never applies a prepared mutation to a replacement Engine.

Lifecycle teardown is an independent final safety net. Graph detach, graph
replacement, account replacement, sign-out, local-cache replacement, and
shutdown must terminally settle and remove every matching pending mutation
before closing or replacing its Engine. Teardown rejects a pre-durable operation
immediately rather than waiting for its local commit. If the commit already won
the coordinator lock and crossed the atomic durable boundary, its success and
outbox record remain valid. Core completion and teardown may race; whichever
terminal action owns the coordinator lock first retires the operation, and the
later completion is stale and harmless.

A late crypto completion from a retired operation must not commit, resolve a new
operation that reused an ID, publish an invalidation for a replacement graph, or
alter new graph sync state.

Successful response remains tied to `Engine.commit_managed_mutation`. Once that
atomic local commit succeeds, later WebSocket or authoritative failure cannot
retroactively convert the Graph response to failure. Before that commit, every
failure returns a bounded `Protocol.Failed` response preserving the original
request ID and `Execute` phase.

Keep the service Serial for this repair so mutation ordering and read-after-write
semantics do not change. Concurrency can be considered separately after every
Promise has a complete lifecycle; increasing concurrency is not a substitute for
completion.

## Decision

Adopt the exhaustive exactly-once completion contract and retain Serial mutation
ordering. Every post-admission path terminates the original Graph request; public
sync state changes never substitute for the operation-correlated result.

Graph detach, account replacement, sign-out, cache replacement, and shutdown
immediately reject an admitted mutation that has not crossed the atomic durable
commit boundary. A mutation whose projection and outbox record already committed
remains successful and is not rolled back by teardown or later remote failure.

Classify local crypto failure with typed causes rather than error-string matching:

- every crypto failure immediately fails and retires the current mutation;
- missing, invalid, mismatched, or corrupt key material also places graph sync in
  the explicit E2EE recovery/failure state while keeping the local mirror
  readable;
- a transient platform or provider failure places sync in a retryable paused
  state; and
- a mutation-specific planning, replacement, or encoding failure rejects only
  that mutation and does not classify the graph key as invalid.

No late crypto completion may turn any of these terminal outcomes into a commit.

## Alternatives considered

### Make the worker service concurrent

This lets later requests overtake one stalled Promise but does not retire the
Promise or prepared mutation. Enough failures still exhaust any bound, and
concurrent mutations add basis and ordering races.

### Add a timeout around `Promise.await`

A timeout can return failure while Core later commits the mutation, causing the
public response to lie. A timeout is safe only if it atomically retires the
operation and fences every late completion, which is the proposed terminal
protocol.

### Infer mutation failure from public Core state

Public phases are not correlated with operation IDs. Catalog or transport
failure can coexist with a valid local mutation, so inference can reject the
wrong request or leak the real one.

### Resolve directly from the effect runner

The runner knows crypto outcome but does not own prepared Engine state, durable
commit, or the Graph response. Direct resolution would violate worker authority
and bypass Core policy.

### Reject every pending mutation when sync becomes `Failed`

This is too broad. Remote catalog, bootstrap, WebSocket, or pull failure does not
necessarily invalidate an admitted local operation. Rejection must be scoped and
operation-correlated.

## Acceptance criteria

- Every operation inserted into `pending_mutations` is removed by exactly one
  terminal path.
- Pre-admission validation failures remain immediate and create no pending entry.
- Planning, encryption, protected-value replacement, transaction encoding, and
  outbox encoding failures each return a bounded `Protocol.Failed Execute`
  response for the original request.
- After each injected failure, a subsequent request completes and the Serial
  service lane is not retained.
- Success is returned only after projection and durable outbox commit atomically.
- Remote submission failure after local commit does not change the returned
  success.
- Engine commit failure emits no invalidation and exposes no prepared projection.
- Detach, replacement, catalog revocation, account replacement, sign-out, cache
  replacement, and shutdown terminally settle all affected pending operations
  according to the selected boundary policy.
- Cancellation before local commit cannot later become a successful commit.
- A commit/detach race serializes to exactly one success or one lifecycle failure
  and can never commit into a replacement graph.
- Late or duplicate Core, crypto, and worker completions are harmless and cannot
  resolve a Promise twice.
- An old-graph completion cannot publish invalidation into a replacement graph.
- Failure responses preserve request ID, phase, intentional error category, and
  a bounded sanitized message without plaintext values, keys, or tokens.
- Shutdown retains no prepared mutation or unresolved Promise even when Engine is
  already absent.
- Deterministic tests cover every post-admission failure, detach, account change,
  late completion, shutdown, and a successful local commit followed by remote
  failure.
- Tests use bounded waits and prove that the next service request runs.
- The success-only completion API is removed without fallback behavior.

## Risks

- Core rejection and lifecycle cleanup intentionally overlap; an incorrect
  exactly-once helper can double-resolve or hide the more accurate reason.
- Immediate rejection on detach may surprise callers that expected an edit to
  finish while navigating away. Waiting instead retains the old Engine longer.
- Retaining Serial ordering means legitimately slow crypto still delays later
  requests until success or cancellation.
- Coarse public errors can make lifecycle or platform failures appear to be
  invalid user mutations; adding error categories changes the protocol contract.
- Treating every crypto failure as graph-terminal can make transient platform
  errors unnecessarily disruptive, while treating every failure as local-only
  can leave a graph with an unusable key.
- Fatal storage corruption or ownership loss must remain service-terminal and
  must not be masked as an ordinary recoverable rejection.
- Dependency error strings require sanitization before entering public protocol
  responses or diagnostics.

## Consequences

- Every admitted mutation now has an explicit success or rejection completion
  carrying its operation, admission, and graph scope identity.
- Worker teardown can settle affected callers before revoking an Engine without
  allowing late completions to act on a replacement Engine.
- Mutation execution remains serialized per graph, while a separate
  control-plane lane can perform account teardown during a blocked mutation.
- Crypto failures are classified as invalid key material or provider failure so
  Core can choose the intended local or graph-level response.
- A successful durable local commit remains successful even if later remote
  submission fails.

## Questions

- None. The user selected immediate rejection before durable commit, no rollback
  after durable commit, and typed mutation/E2EE handling for crypto failures.

## Implementation

Core now delegates `Complete_local_batch` with a `Commit` or typed `Reject`
action for every post-admission path. The worker records the admission ID,
exact graph scope, and owning Engine for each pending mutation, removes the
entry before resolving it, and ignores duplicate or stale completions.

Account, graph, cache, and shutdown teardown drain matching pending mutations.
The Bonsai service uses two request lanes with an explicit graph-request lock,
allowing control-plane teardown to revoke a blocked graph while preserving
serial graph mutation ordering.

## Verification evidence

- The sync reducer contract tests pass with injected planning and encryption
  failures producing terminal worker effects.
- The worker Engine and Bonsai service tests pass, including independent
  control-plane execution and stale-completion fencing.
- `dune build @all`, `dune runtest`, changed-file `ocamlformat --check`, and
  `git diff --check` pass.
