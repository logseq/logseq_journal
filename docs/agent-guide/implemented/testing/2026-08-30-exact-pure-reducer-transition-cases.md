# Exact Pure Reducer Transition Cases

## Problem

The existing `test_step_reachable_state_event_matrix` crosses 17 reachable reducer
checkpoints with 60 representative event payloads. It proves that each of the 1,020
cells is total over the declared model, preserves the observable input, and replays
the same public state, admitted graph scope, and ordered instructions. It does not
state the expected transition for each cell.

Consequently, a deterministic but incorrect implementation can satisfy the matrix.
For example, a stale scoped event could consistently publish `Failed`, or a current
submission event could consistently omit its durable worker instruction. Focused
tests catch selected errors, but there is no complete, reviewable list with the
form:

```text
origin t + event = expected next t + expected ordered effect list
```

The more precise suite must remain useful as a specification rather than becoming a
snapshot that blindly blesses the implementation. It also must respect the public
abstraction of `Core.t`, the GADT-backed runner request/completion types, and the
fact that event payload domains are unbounded.

## Proposal

### Make `transition_case` the canonical one-step test model

Represent every declared cell with this core type:

```ocaml
type transition_case =
  { origin : checkpoint
  ; event : event_case
  ; expected_next : state_view
  ; expected_effects : effect_view list
  }
```

`checkpoint` owns a stable name, the publicly constructed `Core.t`, and its expected
observable view. `event_case` owns a stable name, the `Core.event`, and its event
constructor classification. Case names are therefore derived from
`checkpoint.name ^ " x " ^ event_case.name` rather than duplicated in every row.

Build every checkpoint through the public API and real event traces. Do not
construct private reducer records, use `Obj.magic`, or derive an expected result by
calling `Core.step` inside the expectation builder.

### Define a complete observable `state_view`

At minimum, `state_view` must contain every value currently observable through the
pure reducer contract:

```ocaml
type state_view =
  { state : Core.state
  ; admitted_graph_scope : Core.graph_scope option
  }
```

The expected view is static test data or a named static fixture. The actual view is
obtained from `Core.state` and `Core.admitted_graph_scope` after `Core.step`.

Keep this boundary limited to the existing public observations. Do not add a private-
state observer to `logseq_sync/spec/pure_reducer/core.mli`. Private bookkeeping such
as pending token/effect ownership, snapshot bootstrap phase, submission ownership,
queued authoritative work, and WebSocket liveness must be verified through emitted
effects and subsequent public probe events where relevant.

### Project instructions into stable semantic `effect_view` values

Define a closed test ADT that represents every `Core.instruction` constructor and
the meaningful payload needed to distinguish behavior:

```ocaml
type effect_view =
  | Run_request of runner_request_view
  | Start_websocket of websocket_request_view
  | Send_websocket of websocket_send_view
  | Close_websocket of connection_scope_view
  | Schedule_timer of timer_request_view
  | Cancel_effects of effect_scope_view
  | Delegate of worker_effect_view
  | Publish_state of state_view
  | Publish_token_request of token_request_view
  | Publish_bootstrap_progress of bootstrap_progress_view
  | Publish_graph_invalidation of invalidation_view
```

The projection from `Core.instruction` to `effect_view` must use exhaustive pattern
matches without wildcard catch-alls. GADT runner requests must retain request kind,
ticket ID, scope, and all security-safe semantic request fields. Worker effects must
retain operation identity, scope, action, checkpoint/outbox semantics, and ordering-
relevant payloads. Client/server messages must be represented by their typed ADTs or
an equally complete stable view, not only by constructor names.

Effect equality is ordered list equality. Sorting, deduplication, or treating effects
as a set is forbidden.

### Author a static, complete transition oracle

Reuse the existing checkpoint and event catalogs as the initial finite model. The
canonical value is:

```ocaml
val transition_cases : transition_case list
```

The list may be assembled with small authoring helpers. In particular, no-op cells
may use:

```ocaml
let unchanged origin event =
  { origin
  ; event
  ; expected_next = origin.expected_view
  ; expected_effects = []
  }
```

Helpers may accept explicit lists of origins and events to reduce repetition, but
they must expand to individual `transition_case` values. There must be no wildcard
or implicit default expectation for an uncovered cell.

Add a matrix audit before executing cases. It must prove that:

- the declared checkpoint names are unique;
- the declared event-case names are unique;
- each declared checkpoint/event pair has exactly one transition case;
- no transition case refers to an undeclared checkpoint or event;
- every constructible `Core.event` constructor has at least one event case; and
- every intentionally unconstructible constructor is named as an explicit gap.

The first model should continue to identify `Timer_elapsed` as unconstructible while
`timer_id` remains abstract and no reachable `Schedule_timer` instruction supplies
one. Unsafe construction is forbidden.

### Compare exact results and retain diagnostic quality

For every case, call `Core.step` once for the behavioral assertion and compare:

```text
view_state actual.next = case.expected_next
List.map view_instruction actual.effects = case.expected_effects
```

Retain a replay call as a reducer-purity assertion because the exact suite replaces
the current broad property matrix. Every failure must include the origin name, event-
case name, first differing state field or effect index, expected view, and actual
view.

Do not auto-update expected values during a normal test run. A developer-only
printer may emit candidate OCaml rows for initial authoring, but its output must be
reviewed and copied deliberately. It must not be a checked-in test mode that rewrites
or accepts the oracle automatically.

### Audit and remove duplicated tests in the same implementation

The exact matrix may replace an existing focused test only when a documented mapping
shows that the matrix contains the same origin, payload equivalence class, full next
view, ordered effects, and assertion intent.

Perform this per-test coverage audit in the same implementation that adds the exact
matrix. Remove `test_step_reachable_state_event_matrix` after its checkpoint/event
coverage and immutability/replay assertions are present in the exact suite. Remove a
focused test only after the audit proves that one or more exact cases are an equal or
stronger replacement. Record the disposition of every existing `test_*` in a compact
audit table: removed with replacement case IDs, or retained with the unique property
it continues to own.

Retain tests for APIs outside `Core.step`, including configuration validation, local
batch planning/encoding, authoritative batch decoding/planning, checksum, and cursor
continuity. Retain multi-step correlation, ordering, security, secret-absence, and
negative properties unless the replacement cases and probes express the complete
same property. Do not delete all other `Core` tests merely because the transition
oracle exists.

## Decision

Accept the typed exact transition oracle with a public-only observation boundary.
Use the existing `Core.state` and `Core.admitted_graph_scope` observations for
`state_view`; do not modify the pure reducer specification to expose private state.

Replace the current broad property matrix once the exact suite contains the same
checkpoint/event coverage and retains input-immutability and deterministic-replay
assertions. In the same implementation, audit every focused test and delete only
those with a documented equal-or-stronger exact-case replacement. Keep all unique
non-`step`, multi-step correlation, ordering, security, secret-absence, and negative
properties.

## Alternatives considered

### Keep only the current property matrix

The current matrix is compact and catches exceptions, mutation, and nondeterminism,
but it has no behavioral oracle and therefore cannot detect deterministic wrong
transitions.

### Check in generated golden text

A generated 1,020-row text snapshot is easy to create, but it is difficult to review
semantically and easy to refresh over a regression. Typed OCaml expectations provide
compiler assistance, reusable named views, and more precise diffs.

### Duplicate one standalone Alcotest function per cell

Standalone functions provide direct names but create excessive boilerplate and make
coverage completeness hard to verify. A typed list with a matrix audit provides the
same cell identity with a smaller authoring surface.

### Compare abstract `Core.t` with polymorphic equality

OCaml permits polymorphic comparison at many abstract types, but the public contract
does not promise that `Core.t` is structurally comparable or free of functional and
secret-bearing values. Such comparison would also produce poor failure diagnostics.

### Expose the complete private reducer record

Publishing the implementation record would make invalid states constructible and
couple contract tests to storage details. If private semantic state must be observed,
a narrow redacted view is preferable.

### Replace every focused test immediately

The transition table specifies selected one-step cells. It does not automatically
replace pure helper tests, end-to-end traces, cross-step correlation, or explicit
security properties. Immediate wholesale deletion would reduce meaningful coverage.

## Focused-test disposition audit

The following audit covers every `test_*` value that existed in
`core_contract.ml` before this decision was implemented, including the broad
reachable-state matrix introduced by the preceding testing decision.

| Existing test | Disposition |
| --- | --- |
| `test_config_validation_is_pure_and_bounded` | Retained: validates `limits` and `config`, not `Core.step`. |
| `test_step_is_immutable_and_replayable` | Removed: every exact case now checks input immutability and deterministic replay; `initial/offline x Account_authenticated/sign-in` also checks the former behavioral assertion exactly. |
| `test_stale_and_duplicate_token_events_are_rejected` | Retained: owns multi-step account-generation correlation and one-shot token consumption. |
| `test_runner_completion_is_scoped_and_consumed_once` | Retained: owns multi-step GADT ticket consumption and duplicate completion rejection. |
| `test_lifecycle_generation_fences_stale_events` | Removed: `lifecycle/backgrounded x Foreground_changed/stale` is an equal replacement, and every checkpoint also has the stale lifecycle payload. |
| `test_shutdown_is_idempotent` | Removed: `lifecycle/closed x Shutdown/requested` and `lifecycle/closed x Account_authenticated/sign-in` jointly cover idempotence and post-close event rejection with exact effects. |
| `test_local_batch_planning_separates_crypto_from_policy` | Retained: validates the non-`step` local planning/encoding API and plaintext absence. |
| `test_post_admission_planning_failure_emits_terminal_worker_effect` | Retained: owns a pathological unsupported-Datascript planning payload not represented by the matrix event. |
| `test_post_admission_encryption_failure_emits_terminal_worker_effect` | Retained: owns a multi-step correlated crypto failure and terminal worker rejection. |
| `test_graph_selection_delegates_mirror_authority` | Retained: owns a multi-step selection trace and complete worker-authority request semantics. |
| `test_selected_graph_survives_picker_and_codec_restart` | Retained: owns catalog codec round-trip and restart behavior. |
| `test_absent_stale_and_malformed_cached_selections_fail_closed` | Retained: owns malformed/stale cache negative payload classes. |
| `test_catalog_refresh_preserves_admitted_selection` | Retained: owns multi-step refresh and admitted-selection preservation. |
| `test_catalog_refresh_removes_unadmitted_selection` | Retained: owns the remote-removal correlation across a refresh trace. |
| `test_catalog_save_failure_keeps_selected_graph_usable` | Retained: owns the completion-failure payload and later graph usability. |
| `test_same_account_reconciliation_preserves_warm_restore` | Retained: owns warm-restore correlation across authentication, presentation, and catalog refresh. |
| `test_warm_graph_attachment_defers_websocket_until_timeline` | Retained: owns the multi-step presentation barrier. |
| `test_account_replacement_cancels_and_detaches_before_new_catalog_work` | Retained: owns cross-effect cancellation/detach/token ordering. |
| `test_sign_out_cancels_and_detaches_the_managed_attachment` | Retained: owns exact managed-account teardown scope. |
| `test_auth_before_cache_load_waits_for_local_timeline` | Retained: owns early-auth/cache-load ordering across multiple steps. |
| `test_snapshot_activation_reinspects_worker_mirror` | Retained: owns snapshot-to-mirror correlation. |
| `test_encrypted_snapshot_activation_carries_decryption_capability` | Retained: owns graph-key capability propagation. |
| `test_unencrypted_startup_matrix` | Retained: owns multiple complete startup routes, not one-step cells. |
| `test_encrypted_bootstrap_routes_wait_for_a_scoped_key` | Retained: owns encrypted route correlation and scoped-key gating. |
| `test_encrypted_recovery_resumes_and_coalesces_snapshot_bootstrap` | Retained: owns recovery coalescing across multiple completions. |
| `test_cache_deletion_rejects_stale_and_wrong_scope_key_completions` | Retained: owns stale and wrong-scope key security properties. |
| `test_encrypted_bootstrap_recovers_a_missing_cached_key` | Retained: owns the explicit user-approved recovery trace. |
| `test_encrypted_warm_mirror_waits_for_a_scoped_graph_key` | Retained: owns warm encrypted mirror gating. |
| `test_encrypted_authoritative_pull_decrypts_before_worker_apply` | Retained: owns decrypt-before-apply ordering and capability propagation. |
| `test_authoritative_decryption_failure_is_fail_closed` | Retained: owns the decryption failure negative path. |
| `test_authoritative_pull_is_pure_and_advances_checkpoint` | Retained: validates non-`step` authoritative planning and checksum/checkpoint semantics. |
| `test_authoritative_pull_rejects_cursor_gaps` | Retained: validates non-`step` cursor continuity. |
| `test_authoritative_pull_accepts_transit_list_collection` | Retained: validates authoritative Transit decoding. |
| `test_authoritative_pull_rejects_empty_or_non_array_operations` | Retained: validates malformed authoritative transaction payloads. |
| `test_duplicate_pull_skips_authoritative_transaction_bodies` | Retained: owns duplicate-pull planning semantics. |
| `test_duplicate_pull_never_replays_stored_transport_transactions` | Retained: owns durable outbox transport non-replay. |
| `test_duplicate_pull_still_rejects_future_transaction_cursor` | Retained: owns the future-cursor negative case. |
| `test_typed_websocket_messages_reach_policy_without_raw_json` | Retained: owns typed protocol ingress and raw-JSON absence. |
| `test_submission_owner_is_reserved_before_durable_transition` | Retained: owns multi-step submission ownership and later-mutation queueing. |
| `test_acknowledgement_without_submission_owner_is_ignored` | Retained: owns the negative acknowledgement-correlation property. |
| `test_submission_waits_for_durable_outbox_transition` | Retained: owns durable-CAS-before-send ordering. |
| `test_e2ee_recovery_keeps_password_out_of_core_state` | Retained: owns secret absence across the complete recovery trace. |
| `test_step_reachable_state_event_matrix` | Removed: the exact suite keeps the same 17 checkpoints and 60 event cases, then adds exact next-state/effect assertions while retaining totality, immutability, and replay checks. |

## Acceptance criteria

- The exact suite is organized around the declared `transition_case` record.
- Every declared checkpoint/event cell expands to exactly one case, with duplicate,
  missing, and extra cases rejected before behavioral assertions run.
- Every expected next view and ordered effect view is static, reviewed test data and
  is not derived from the actual transition under test.
- `state_view` covers the selected reducer observation boundary completely.
- `effect_view` exhaustively projects every instruction, runner request, worker
  effect, output, and ordering-relevant payload used by the cases.
- A changed state field, missing/extra/reordered effect, wrong effect payload, thrown
  exception, input mutation, or nondeterministic replay fails with the exact cell
  name and a useful structural diff.
- The suite keeps the explicit `Timer_elapsed` construction gap unless the public
  contract supplies a legitimate timer ID.
- Every removed focused test has a documented one-to-one or stronger replacement;
  non-`step`, multi-step, and security tests remain unless equivalently covered.
- The same implementation includes a disposition for every pre-existing
  `core_contract.ml` test and removes every test proven redundant by the exact
  transition cases.
- The existing broad property matrix is removed after the exact suite preserves its
  declared cells and purity assertions.
- No production reducer implementation or Dune file is changed solely to support
  the public-observation version of the test.
- `dune build @all`, `dune runtest`, `ocamlformat --check` for changed OCaml files,
  and `spec-dev-tool check --all` pass.

## Risks

- A large exact oracle can freeze accidental implementation behavior. Each expected
  transition must be reviewed against the specification and focused tests rather
  than accepted because it matches current output.
- Intentional reducer changes may update many cases, increasing review cost. Named
  views and explicit grouping should reduce repetition without hiding coverage.
- Public `state_view` cannot prove private bookkeeping directly. Behavioral probe
  events cover only the private distinctions that change later public behavior.
- Stable effect views require deliberate normalization. Over-normalization can hide
  regressions, while representation-level fields can make tests unnecessarily
  brittle.
- The same implementation must carry temporary duplication while the coverage audit
  is in progress. The final result removes proven duplicates without deleting a
  unique safety property.

## Consequences

- `logseq_sync/spec/pure_reducer/core.mli` remains unchanged, and exactness is defined
  at the existing public contract boundary.
- The exact transition suite becomes the single matrix for totality, expected next
  state, ordered effects, input immutability, and deterministic replay.
- `test_step_reachable_state_event_matrix` is retired rather than maintained in
  parallel.
- The implementation scope includes a complete audit of existing focused tests and
  deletion of every test whose full assertion intent is subsumed.
- Tests for unique helper APIs, multi-step protocols, ordering, correlation,
  security, secret absence, and negative properties remain in `core_contract.ml`.
- Private reducer changes that preserve public state, admitted scope, emitted
  effects, and all public probe behavior intentionally do not fail this suite.

## Questions

None. The user selected the public-only `state_view`, replacement of the broad
property matrix, and completion of the focused-test audit and deletion in the same
implementation.
