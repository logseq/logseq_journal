# Rewrite Exact Pure Reducer Happy Path Cases

## Problem

`test_exact_pure_reducer_transition_cases` currently presents a 17-checkpoint by
60-event cross product as an exact reducer oracle. Its 1,020 rows are complete only
with respect to those two finite catalogs. They are not a proof that the selected
checkpoints are protocol-reachable, that an asynchronous completion owns a pending
operation, or that a representative payload exercises the meaningful branch of a
constructor.

Several rows consequently encode implementation behavior that is not logically
valid reducer behavior:

- `sync/current` and `sync/paused` are constructed by injecting an
  `Authoritative_batch_applied` event without first receiving a server message and
  completing the corresponding inspect/apply ownership chain;
- event variants named `current` often mean only that a graph or connection scope
  is numerically equal, not that the event belongs to the current pending operation;
- the catalog `Runner_completed/success` ticket is reused against an unrelated
  local-restore checkpoint whose pending request happens to have the same integer
  effect ID;
- publicly unchanged rows can still consume a private pending effect, replace the
  durable outbox projection, or clear a submission owner; and
- expected state and effect fixtures are sufficiently large and repetitive that a
  reviewer is likely to verify consistency with the implementation rather than
  independently verify the intended protocol semantics.

A passing matrix therefore proves determinism for the captured implementation, but
does not reliably prove correctness. It also makes the first trustworthy rewrite
unnecessarily expensive: every semantic correction would require reviewing many
unrelated cross-product rows.

## Proposal

Replace the cross-product test with one canonical, sequential happy-path trace.
The first trace contains exactly 20 required transition cases and covers:

1. cold authentication and remote catalog discovery;
2. selection and attachment of an existing unencrypted local mirror;
3. WebSocket startup and the opening authoritative pull;
4. transition to `Current`;
5. one plaintext local mutation;
6. durable outbox reservation before WebSocket submission;
7. the correlated `tx/batch/ok` acknowledgement; and
8. the authoritative confirmation pull that releases the submission owner.

This first rewrite is intentionally not exhaustive. It must not include a
checkpoint/event Cartesian product, stale or duplicate completions, failures,
background lifecycle events, graph switching, sign-out, shutdown, warm restore,
snapshot bootstrap, or E2EE recovery. Those behaviors require separate traces whose
ownership and expected semantics can be reviewed independently.

Rename the test to `test_pure_reducer_canonical_happy_path` and remove the obsolete
`test_exact_pure_reducer_transition_cases` function, scenario name, 1,020-row table,
and fixtures used only by that table. Do not retain an alias or compatibility path.
Retain focused tests that own properties outside this 20-step trace.

### Use one causally connected trace

Every case consumes the `next` state of the preceding successful case. An
asynchronous event may be constructed only from an instruction that was emitted and
exactly checked earlier in the same trace:

- a `Runner_completed` event must reuse the exact typed ticket emitted by its
  preceding `Run (Request ...)` instruction;
- a worker completion must match the exact operation, scope, precondition, outbox,
  pending message, and ownership generation emitted by the preceding worker
  instruction;
- a WebSocket event must use the exact connection scope emitted by
  `Start_websocket`; and
- authoritative acknowledgement and confirmation results must correspond to the
  exact server message and worker apply request that precede them.

Extracting a capability or typed ticket from a previously checked effect is allowed.
Using an event, ticket, scope, or completion copied from an independent fixture
trace is forbidden.

The trace uses one authenticated user, one catalog member, an existing unencrypted
mirror at checkpoint `t = 0`, one current WebSocket connection, and one plaintext
local mutation. The server acknowledges that mutation at `t = 1`, and the final pull
confirms the same mutation at `t = 1`.

### Define the 20 required cases

The expected results below are semantic requirements. Implementation output must
not be used to author or update them.

| ID | Origin and event | Required logical result |
| --- | --- | --- |
| `HP01` | `initial/offline` + `Account_authenticated (Some user_id)` | Start a new authenticated account generation, clear graph-specific ownership, enter catalog-loading `Connecting`, then emit ordered `Publish_state` and `Token_requested Catalog_discovery`. |
| `HP02` | catalog-token pending + the correlated `Token_provided` | Consume that token request exactly once, retain the public catalog-loading view, and emit exactly one typed `Fetch_catalog` runner request for the same account generation. |
| `HP03` | catalog-fetch pending + the correlated successful `Runner_completed` | Consume the exact fetch ticket, install the returned catalog, enter `Offline` awaiting selection, publish that state, and request persistence of the catalog cache. |
| `HP04` | catalog awaiting selection + `Graph_selected` for the declared catalog member | Admit one new graph generation, retain the selected catalog member, mark bootstrap pending, and emit `Inspect_mirror`, the new public state, and selected-catalog persistence in the required order. |
| `HP05` | selected graph awaiting mirror inspection + a matching `Mirror_available` result | Accept only the inspection for the admitted graph scope, retain the public selected/bootstrapping view, and emit exactly one `Attach_graph` worker instruction for the returned open request. |
| `HP06` | graph attachment pending + matching `Graph_attached` | Accept the attached checkpoint and durable outbox, clear bootstrap flags, enter `Connecting` with `applied_server_t = 0`, publish the state, and request a `Websocket_connect` token. |
| `HP07` | WebSocket-token pending + the correlated `Token_provided` | Consume that token request, retain the public connecting view, increment the connection generation once, and emit exactly one `Start_websocket` instruction containing the admitted graph and supplied token. |
| `HP08` | WebSocket starting + matching `Websocket_opened` | Mark the emitted connection live, enter `Pulling`, then emit ordered `Publish_state` and `Send_websocket (Pull { since = Some 0 })`. |
| `HP09` | opening pull pending + matching `Websocket_message (Pull_ok at t = 0)` | Do not claim `Current` yet. Reserve the authoritative batch owner and emit exactly one `Inspect_authoritative_batch` worker instruction for this connection, presentation, and lifecycle generation. |
| `HP10` | opening authoritative inspection pending + matching `Authoritative_batch_inspected` | Preserve the active authoritative owner and emit exactly one `Apply_authoritative_batch` request carrying the worker precondition, checkpoint, outbox, and `Pull_duplicate` activity. |
| `HP11` | opening authoritative apply pending + matching `Authoritative_batch_applied` | Consume the active authoritative owner, enter `Current` at `t = 0`, retain the worker-authoritative outbox, and publish the resulting state without opening a submission unless queued work exists. |
| `HP12` | `Current` + one valid plaintext `Local_batch_prepared` | Plan the mutation against the admitted graph without crypto, retain reducer sync state, and emit exactly one `Complete_local_batch (Commit ...)` containing the stable operation/admission identity and a queued durable outbox record. |
| `HP13` | local-batch completion pending + matching `Local_batch_committed` | Adopt the exact durable queued outbox returned by the worker, reserve one submission owner before sending, and emit exactly one `Commit_outbox_transition` from `Queued` to `Submitted`; emit no WebSocket send yet. |
| `HP14` | outbox reservation pending + matching `Outbox_transition_committed` | Require the exact scope, replacement outbox, and non-`None` pending message emitted by `HP13`; move the owner from reserving to dispatched, enter `Submitting`, then emit ordered `Send_websocket (Tx_batch ...)` and `Publish_state`. |
| `HP15` | dispatched submission + matching `Websocket_message (Tx_batch_ok at t = 1)` | Correlate the acknowledgement only with the current dispatched owner, move that owner to acknowledgement application, and emit exactly one authoritative inspection for the typed acknowledgement batch. |
| `HP16` | acknowledgement inspection pending + matching `Authoritative_batch_inspected` | Mark only the owned mutation record `Accepted 1`, preserve its semantic identity, and emit exactly one authoritative apply request with `Pull_required` activity and the exact worker precondition. |
| `HP17` | acknowledgement apply pending + matching `Authoritative_batch_applied` | Move the submission owner to awaiting confirmation at `t = 1`, enter `Pulling`, publish the state, and send exactly one `Pull { since = Some 0 }`; do not release or resubmit the mutation yet. |
| `HP18` | confirmation pull pending + matching `Websocket_message (Pull_ok at t = 1)` | Reserve a new authoritative batch owner for the confirmation response and emit exactly one authoritative inspection. The response must identify the acknowledged mutation at the authoritative cursor. |
| `HP19` | confirmation inspection pending + matching `Authoritative_batch_inspected` | Reconcile the accepted record against the authoritative response, preserve the worker precondition, and emit exactly one authoritative apply request with `Pull_applied` activity and the correctly rebuilt outbox/projection. |
| `HP20` | confirmation apply pending + matching `Authoritative_batch_applied` | Advance to `Current` at `t = 1`, remove the authoritatively confirmed outbox record, release the submission owner, publish the state, publish any worker-supplied graph invalidation after the state, and emit no duplicate submission. |

`Save_catalog` success completions are not required in the first 20 cases because
they do not advance this reducer trace and their one-shot completion behavior remains
owned by focused runner-completion tests. The exact catalog-save requests emitted by
`HP03` and `HP04` are still checked as ordered effects.

### Derive expectations independently from implementation output

Before implementing each case, add a short English rationale adjacent to the case or
in a compact table in the test source that identifies:

1. the decision or public contract authorizing the transition;
2. the pending owner that makes the event current;
3. the fields that must remain unchanged;
4. the fields that are permitted to change; and
5. the exact ordered effects and why each effect is required.

Expected `state_view` and `effect_view` values must be static test data. Do not call
`Core.step`, project actual effects, print golden output, or copy a failing actual
value to produce an expectation. When the existing implementation disagrees with a
logically reviewed expectation, keep the expectation and treat the disagreement as a
reducer defect.

For steps whose important result is private ownership rather than a public-state
change, the immediately following case is the required public probe. For example:

- `HP09` is proven to reserve the correct authoritative owner because only the
  matching `HP10` inspection may produce the expected apply instruction;
- `HP13` is proven to reserve the exact submission owner because only the matching
  `HP14` durable completion may send the batch;
- `HP15` is proven to bind the acknowledgement to that owner because `HP16` may
  accept only the owned mutation; and
- `HP17` is proven to retain confirmation ownership because `HP20` must release it
  only after the `t = 1` pull is inspected and applied.

The test must check every step before using its `next` value or extracting a payload
from its effects. A failure in an earlier step must identify that step rather than
allowing a later extraction failure to obscure the incorrect transition.

### Keep the initial suite deliberately narrow

Later work may add separate, reviewable traces for:

- warm local restore and same-account reconciliation;
- absent mirror snapshot bootstrap;
- encrypted mirror and E2EE password recovery;
- stale, duplicate, wrong-owner, and wrong-generation completions;
- catalog refresh and graph removal;
- background/foreground lifecycle fencing;
- graph replacement, sign-out, shutdown, and cancellation ordering; and
- failure, conflict, retry, uncertain-submission, and semantic-replan paths.

Those traces must not be added to the first rewrite merely to increase constructor
or matrix coverage.

## Decision

Replace `test_exact_pure_reducer_transition_cases` with the single sequential
`test_pure_reducer_canonical_happy_path` trace defined above. The trace contains
exactly `HP01` through `HP20`, derives asynchronous completions only from already
checked instructions in the same trace, and uses static public-state and ordered-
effect expectations with adjacent semantic rationales.

Remove the obsolete checkpoint/event Cartesian product, its matrix-only fixtures,
its scenario name, and its compatibility surface. Keep the existing focused pure-
reducer tests for behavior outside this deliberately narrow happy path.

## Alternatives considered

### Retain the 1,020-row matrix and correct suspicious cells

This preserves nominal pair coverage but requires deciding the meaning of impossible
or ownerless event combinations before the canonical path is trustworthy. It also
retains large generated-looking fixtures that encourage snapshot approval.

### Generate the expected trace from `Core.step`

This is fast but circular. It can prove deterministic replay, not correctness, and
would reproduce the defect being removed.

### Keep the matrix and add a separate happy-path test

The invalid matrix would continue to act as a conflicting behavioral specification.
The obsolete path should be removed rather than retained as a compatibility oracle.

### Start with all successful startup variants

Warm restore, absent mirrors, snapshot activation, and E2EE recovery are each valid
happy paths, but they introduce distinct pending owners and security invariants. They
should be reviewed as independent traces after the minimal unencrypted existing-
mirror path is correct.

### Use one standalone Alcotest function per transition

Standalone tests isolate failures but duplicate trace construction and make ownership
between adjacent steps harder to see. One sequential test with named, individually
checked steps preserves causality while retaining precise diagnostics.

## Acceptance criteria

- The rewritten suite contains exactly the 20 required `HP01` through `HP20` cases
  and no checkpoint/event Cartesian product.
- Every asynchronous completion is derived from a previously emitted and already
  checked instruction in the same trace.
- Every origin is the checked `next` value of its predecessor; no happy-path
  checkpoint is created by injecting an ownerless completion.
- Every expected public state and ordered effect list is static and has an adjacent
  semantic rationale independent of current implementation output.
- `HP11` reaches `Current` only after the opening server message, worker inspection,
  and worker apply have all completed in order.
- `HP14` proves durable outbox reservation precedes the first transaction send.
- `HP15` through `HP20` prove that acknowledgement and confirmation apply only to the
  single owned mutation and release it only at the authoritative cursor.
- No case described as unchanged can consume or alter private ownership without an
  immediate subsequent probe proving the intended private transition.
- The old 1,020-row transition table and fixtures used only by it are removed, with
  no compatibility alias or snapshot updater.
- Focused tests outside this canonical trace remain present.
- Failure diagnostics name the `HPxx` step and report the first state field or effect
  index that differs.
- Each step is replayed from the same immutable origin, and replay produces the same
  public next state and ordered effects.
- `dune exec logseq_sync/test/test_sync.exe -- test '^pure core$'` passes.
- `dune build @all`, `dune runtest`, `git diff --check`, and
  `spec-dev-tool check --all` pass.

## Risks

- Removing the matrix intentionally reduces broad totality coverage until separate
  negative traces are added. The focused reducer tests remain the safety net during
  that interval.
- A sequential trace can produce cascading failures. Checking and naming every step
  before constructing the next step is required to keep the first defect visible.
- Extracting a completion payload from an actual effect can accidentally bless that
  effect. The test must compare the complete semantic effect against static expected
  data before extraction.
- The worker-owned authoritative precondition is opaque. Fixtures must preserve the
  exact value supplied by the worker boundary without making Core interpret it.
- The final confirmation pull interacts with semantic outbox replanning. The test
  must use the worker-authoritative rebuilt result rather than assuming that Core can
  derive durable worker state.
- Deferring stale and failure cases means the first rewrite is a canonical happy-path
  contract, not an exhaustive reducer specification; its name and documentation must
  not claim exhaustiveness.

## Consequences

- The suite now provides a reviewable causal contract for cold authentication,
  existing-mirror attachment, opening pull, plaintext mutation submission,
  acknowledgement, and authoritative confirmation.
- Durable outbox reservation, acknowledgement ownership, and confirmation release
  are checked in protocol order rather than inferred from unrelated fixtures.
- Broad constructor-pair coverage is intentionally reduced; stale, failure,
  lifecycle, restore, bootstrap, E2EE, and replacement behavior remains owned by
  focused tests and may gain separate causal traces later.
- The canonical trace fails at the first named `HPxx` state field or effect index and
  checks immutable-origin replay at every step.

## Questions

- None. The user confirmed exactly 20 state-advancing and ownership-advancing cases,
  with successful `Save_catalog` completions deferred from the first rewrite, and
  confirmed renaming the test to `test_pure_reducer_canonical_happy_path` while
  removing the misleading `exact` name without a compatibility alias.
