# Detach Managed Graph On Account Boundaries

## Problem

Core clears its public account and graph fields when authentication changes, but
it does not consistently tear down worker-owned resources belonging to the
previous account.

When a different user authenticates, `authenticate_new_account` clears
`current_graph_scope`, key state, pending reducer work, outbox state, and
WebSocket liveness, then immediately publishes the new state and requests a
catalog token. It emits neither `Cancel_effects` for the previous account nor
`Detach_graph` for its Engine.

Sign-out has the same Engine ownership defect. `sign_out` clears Core state and
issues runner cancellation, but emits no worker detach. Existing graph-selection
and authoritative-catalog-removal paths do cancel the previous graph scope and
delegate `Detach_graph`, so account boundaries currently bypass an otherwise
established teardown policy.

The worker closes an Engine only after an explicit detach, replacement attach,
mirror deletion, or shutdown. Until one of those later events, the old Engine
and `attached_scope` remain present. Graph request execution authorizes access
from `t.engine` alone; it does not require a current authenticated account or a
matching Core graph scope.

Consequently:

- a signed-out service can continue reading or mutating the previous account's
  graph;
- a replacement account can access the old Engine during catalog discovery,
  graph selection, bootstrap, or E2EE recovery;
- worker graph lifecycle can remain open after Core publishes no selected graph;
  and
- headless worker clients remain exposed even if Application no longer renders
  the previous Timeline.

The worker also owns pending mutation Promises independently of Core. Closing an
Engine does not currently drain those entries, so an old-account continuation
can remain unresolved or later target a replacement Engine unless account
teardown and mutation completion share one scope contract.

Runner cancellation is incomplete for a WebSocket still connecting because
`Start_websocket` is registered only after the handshake succeeds. An old-account
connection can therefore finish after Core has cleared that account.

Relevant boundaries are `authenticate_new_account`, `sign_out`, graph
replacement and catalog omission in `logseq_sync/lib/pure_reducer/core.ml`, plus
Engine ownership, `pending_mutations`, detach, and Graph request execution in
`logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`.

## Proposal

Create one explicit account-boundary teardown transition and use it for:

- `Account_authenticated { user_id = None }`; and
- `Account_authenticated { user_id = Some replacement }` when the user differs
  from the currently restored or authenticated account.

Do not run teardown for same-account authentication reconciliation. That path
must preserve the warm selected graph, local Timeline, and current graph
generation.

Capture the previous account and graph scopes before clearing Core state. The
ordered boundary must:

1. advance account, graph, connection, and presentation ownership so late work
   becomes stale immediately;
2. cancel all previous-account HTTP, crypto, timer, WebSocket-connect, connected
   WebSocket, and in-memory key-handle work using the captured old scope;
3. delegate a strong worker detach for the previous managed session;
4. revoke worker access to the old Engine before any replacement-account Graph
   request can succeed;
5. complete every pending request owned by the detached Engine exactly once with
   a typed account/session-closed failure;
6. publish closed graph lifecycle and cleared Core state; and
7. only then request credentials or begin catalog work for the replacement
   account.

Strengthen worker detach from a bare graph-generation integer to either an
account-qualified `graph_scope` or a dedicated managed-session reset command.
The operation must be idempotent, close only the intended previous attachment,
and never let a stale teardown close a newer account's Engine.

Associate each pending mutation with the exact Engine instance and graph scope
that prepared it. Engine close must drain matching pending requests before a
replacement Engine is installed. A late Core completion for the detached scope
must be ignored and must never commit merely because `t.engine` contains some
new Engine.

As defense in depth, Graph request execution must require a currently admitted
managed attachment. The coordinator should verify that Engine instance,
`attached_scope`, graph lifecycle, and managed-session generation agree before
executing a read or preparing a mutation.

Register `Start_websocket` as cancellable before the handshake begins. If
account cancellation wins concurrently with successful connect, close the
returned socket and emit no `Websocket_opened` event.

Teardown revokes in-memory access but does not implicitly delete the local
mirror or durable outbox. Persistent mirror and secret retention/deletion are
separate product decisions; this fix must not substitute broad deletion for a
precise runtime authorization boundary.

Use the same teardown helper for sign-out and direct account replacement. Remove
the obsolete state-clearing paths that omit worker teardown rather than keeping
parallel compatibility behavior.

## Decision

Adopt a strong account-qualified `Reset_managed_account` worker command instead
of using `Detach_graph of graph_scope` as the account-boundary primitive.
Graph-only replacement can retain its scoped detach operation, but sign-out and
direct account replacement must reset every Engine attachment, pending local
operation, connection attempt, socket, timer, crypto operation, and in-memory key
owned by the previous managed account session.

Account reset is a control-plane transition and must be able to interrupt a
normal Serial request lane that is waiting on a mutation Promise. Interruption
still enters the coordinator lock and resolves the admitted operation through
the selected exactly-once completion contract; it does not concurrently mutate
Engine state or bypass serialization.

Any admitted mutation that has not crossed the atomic durable commit boundary is
rejected during reset. A mutation that already committed its projection and
outbox record remains successful and is not rolled back. The reset revokes the
old Engine capability before replacement-account catalog or graph work starts.
Physical close failure may be reported, but it must not restore access to the
old Engine.

Same-account authentication reconciliation does not emit
`Reset_managed_account` and continues to preserve the warm local-first graph.

## Alternatives considered

### Rely on Core generation fencing

Generation fencing prevents many late reducer events, but Graph requests do not
carry those generations and the old Engine remains directly accessible.

### Stop old-graph access only in Application

Presentation state is not an authorization boundary. Headless clients, queued
requests, tests, and future non-UI consumers would retain access.

### Wait for the replacement graph to attach

Replacement attach closes the previous Engine, but catalog discovery, selection,
bootstrap, and E2EE recovery can create an arbitrary interval before that event.
Access must end at the account boundary.

### Restart the entire worker service

A process-level restart would close the Engine but discard unrelated worker
state and turn an ordinary authentication transition into service lifecycle
management. The coordinator already owns a narrower teardown boundary.

### Keep generation-only detach

A graph-generation integer is weaker than the account boundary being enforced.
An account-qualified scope or managed-session identity prevents stale cleanup
from targeting a newer attachment.

### Remove pending mutation entries without resolving them

This prevents a late commit but leaves callers blocked forever. Every admitted
request needs exactly one terminal response.

## Acceptance criteria

- Signing out emits old-account cancellation and worker detach before later
  account or graph work begins.
- After sign-out the coordinator has no accessible Engine or attached scope and
  publishes a closed graph lifecycle.
- Every Graph request after sign-out and before a new attachment fails without
  reading or mutating the old graph.
- Direct replacement of user A by user B detaches A before requesting B's catalog
  token.
- User B cannot access A's graph during catalog discovery, selection, bootstrap,
  E2EE recovery, or graph-open failure.
- Same-account authentication emits no detach and preserves warm local-first
  restoration.
- An admitted old-account mutation is completed exactly once when its Engine is
  detached and cannot commit against a replacement Engine.
- Late HTTP, crypto, token, timer, WebSocket, authoritative, local-batch, and
  graph-attachment completions from the old scope perform no Engine operation.
- A canceled WebSocket handshake cannot remain connected or emit an old-account
  `Websocket_opened` event.
- Repeated sign-out and stale teardown events are idempotent.
- Engine close failure still revokes the coordinator's Engine capability and
  does not restore old-account access.
- The local mirror and durable outbox are retained unless a separate explicit
  deletion decision says otherwise.
- Tests cover sign-out, direct replacement, same-account reconciliation, pending
  mutation cancellation, late completions, close failure, and repeated teardown.
- The state-clearing-without-detach paths are removed without a fallback.

## Risks

- Constructing cancellation scope after generations advance can target the wrong
  work and leave old operations alive.
- An unscoped cancellation emitted after new work begins can cancel replacement
  account catalog discovery; old scope capture and effect ordering are critical.
- Pending requests must be associated with an Engine instance before close, or
  teardown can resolve work belonging to a newer attachment.
- Account commands queued behind an unresolved Serial mutation cannot revoke
  access promptly. This decision depends on exact mutation-failure completion.
- Engine close may fail after access is revoked. The stale Engine pointer must
  not be restored merely to report that error.
- Applying teardown to same-account reconciliation would regress offline warm
  startup and unnecessarily close Timeline.
- Teardown must not report failure for a mutation that already crossed its
  durable commit boundary; that outbox record remains valid for later
  same-account recovery.

## Consequences

- Sign-out and account replacement revoke the old Engine capability before any
  replacement-account discovery begins.
- Teardown is keyed by exact account and graph scopes, making repeated or stale
  reset effects idempotent without affecting a newer attachment.
- Pending mutations owned by the detached Engine receive one lifecycle failure;
  already committed mutations remain durable.
- Local mirror and outbox storage survive account teardown and remain available
  for a later same-account attachment.
- WebSocket connection establishment is cancellable from before the handshake,
  and a late socket is closed without publishing an old-scope open event.

## Questions

- None. The user selected `Reset_managed_account` and an interruptible
  control-plane path for account teardown.

## Implementation

Core captures the old account scope before advancing generations, cancels its
effects, rejects matching pending local batches, and delegates
`Reset_managed_account` before requesting replacement catalog work. Graph
teardown uses an exact `graph_scope` rather than generation-only detach.

The worker validates the current attached scope and physical Engine identity on
every graph operation. Reset and detach clear the capability before closing the
Engine, drain only matching pending mutations, and tolerate repeated stale
effects. The effect runner registers WebSocket cancellation before starting the
handshake and suppresses all callbacks after cancellation.

## Verification evidence

- Reducer contract tests pass for sign-out, direct account replacement, and
  same-account reconciliation ordering.
- Worker service tests pass with account teardown able to interrupt a blocked
  graph request while graph requests remain serialized.
- `dune build @all`, `dune runtest`, and `spec-dev-tool check --all` pass.
