# Centralize Safe Worker Error Cause Construction

## Problem

`Logseq_db_worker.Error.create_cause` is the strict constructor for one bounded,
display-safe causal entry. Production callers that receive a lower-layer string
cannot assume that the string satisfies that contract, so they currently repeat
the same two-attempt policy:

1. call `create_cause` with the lower message;
2. if validation rejects it, call `create_cause` again with a fixed safe message;
3. unwrap the second result because the fixed component, operation, code, and
   fallback message are intended to be valid.

That policy is duplicated in six production flows:

| Module and function | Lower boundary | Current fallback |
| --- | --- | --- |
| `app/application.ml`, `service_error` | unavailable Bonsai worker service | `Worker service reported a display-unsafe failure.` |
| `logseq_db_worker/lib/engine.ml`, `lower_cause` | snapshot, ownership, storage, and planner mappings | `The lower operation returned a display-unsafe failure.` |
| `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`, `graph_failure` | graph request without an available engine | `The graph service is unavailable.` |
| the same service module, `service_error` | worker service and coordinator failures | `Worker service reported a display-unsafe failure.` |
| the same service module, `mutation_failure` | managed mutation completion | `Managed sync reported a display-unsafe failure.` |
| `logseq_db_worker/cli/cli_command.ml`, `fatal_error_json` | top-level CLI failure | `The CLI received a display-unsafe fatal failure.` |

These flows contain twelve calls to `create_cause` and six copies of the same
branching and unwrapping machinery. The duplicated code is not domain policy:
each call site already supplies the component, operation, lower code, and exact
fallback message that express its policy. The repeated mechanism only enforces
the canonical `Error` validation contract.

The implemented causal-error decision requires every mapped lower failure to
retain its exact sanitized origin and requires unsafe values to be replaced at
their source. Leaving the retry mechanism distributed makes that invariant
harder to review and allows a future boundary to choose a different fallback
sequence accidentally.

`contextualize_error` in the Bonsai service is not part of this duplication. It
wraps an already validated `Error.t`, so its derived code and message are known
to satisfy the strict `create_cause` contract. JSON decoding is also excluded:
invalid external cause values must continue to return an error instead of being
silently replaced.

## Proposal

Add one public helper to `Logseq_db_worker.Error` that owns the existing
two-attempt construction mechanism. Its conceptual contract is:

```ocaml
val create_cause_or_fallback
  :  component:component
  -> operation:string
  -> code:string option
  -> message:string
  -> fallback_message:string
  -> cause
```

The exact name may change during proposal review, but the semantics must not:

- first call the existing strict `create_cause` with `message`;
- return that exact cause when validation succeeds;
- on any validation failure, call `create_cause` with the same component,
  operation, and code plus `fallback_message`;
- return the fallback cause when it validates; and
- preserve the current invariant-failure behavior when the caller-provided
  fallback itself is invalid.

Keep `create_cause` strict and keep `Error.of_yojson` on that strict path. The
new helper is for trusted production boundaries that deliberately project an
untrusted lower string into a known safe fallback; it is not a compatibility
decoder, redactor, truncator, or generic exception sanitizer.

Replace the six duplicated branches listed above with the helper while retaining
their exact current component, operation, code, primary worker error, lower
message preprocessing, and fallback message. In particular,
`Cli_command.bounded_message` remains before the helper, and each boundary keeps
its distinct fixed fallback copy.

Do not move domain-specific error classification into `Error`. `Engine` remains
the owner of snapshot, ownership, storage, and planner mappings; the managed
coordinator remains the owner of mutation-failure classification; and CLI,
service, and application layers retain their current top-level worker codes and
messages. This decision centralizes only the behavior-identical safe-cause
construction mechanism.

## Decision

Add `Logseq_db_worker.Error.create_cause_or_fallback` as the single public helper
for the existing two-attempt construction mechanism. The helper first delegates
to strict `create_cause`, discards a rejected lower message, and retries with the
caller-provided fallback while preserving component, operation, and optional
code. A rejected fallback continues to raise the existing invariant failure.

Use the helper in the six identified Application, Engine, Bonsai worker service,
managed coordinator, and CLI flows. Keep their domain classification, public
errors, lower-message preprocessing, and distinct fallback copy local. Keep
direct strict construction in error creation, validated contextual wrapping,
and JSON decoding.

## Alternatives considered

### Keep the repeated branches local

This keeps the strict constructor surface minimal, but six real production call
sites already need the identical retry mechanism. The repetition obscures the
causal-error invariant and requires every new lower boundary to reproduce it.

### Use one global fallback message

A global message would shorten call sites further, but it would change existing
diagnostic output and erase useful boundary identity. Caller-provided fallback
messages preserve observable behavior while still centralizing the mechanism.

### Sanitize or truncate arbitrary lower strings automatically

Automatic transformation would introduce new redaction semantics and could
retain secrets that the current allowlist rejects. The existing all-or-fallback
behavior is deliberate and must remain unchanged.

### Make `create_cause` itself infallible

JSON decoding and validation tests rely on strict rejection of malformed,
oversized, or display-unsafe causes. Replacing the strict constructor would
weaken the protocol trust boundary and change supported error behavior.

### Centralize complete worker-error classification

The six callers use different public codes, primary messages, lower components,
operations, and fallback copy. Moving those decisions into one generic error
factory would relocate domain policy and make the helper harder to understand;
only the common retry mechanism should move.

## Acceptance criteria

- `Logseq_db_worker.Error` exposes one documented helper for constructing a
  cause from a lower message with a caller-provided safe fallback.
- A valid lower message returns a cause identical to direct `create_cause`
  construction.
- An empty, oversized, or prohibited lower message returns the cause built from
  the exact caller-provided fallback while preserving component, operation, and
  optional code.
- An invalid fallback retains the current invariant-failure behavior rather than
  returning a partially valid cause.
- `create_cause`, `create_with_origin`, `wrap`, and `of_yojson` retain their
  strict validation and wire behavior.
- The six production flows in Application, Engine, the Bonsai worker service,
  and CLI use the shared helper and contain no local retry copy.
- `Cli_command.bounded_message` and all six current fallback strings remain
  unchanged.
- Domain-specific worker error codes, primary messages, details, causal origins,
  contexts, protocol JSON, application ledger entries, and rendered Error info
  content remain unchanged for both safe and unsafe lower messages.
- Focused tests cover successful lower-message construction, fallback for each
  rejected message class, exact metadata preservation, invalid fallback
  behavior, and strict JSON rejection.
- `dune exec logseq_db_worker/test/test_protocol.exe`,
  `dune exec logseq_db_worker/test/test_cli.exe`,
  `dune exec logseq_db_worker/test/test_bonsai_service.exe`,
  `dune exec test/application_view_test.exe`, `dune build @all`,
  `dune runtest`, `git diff --check`, and `spec-dev-tool check --all` pass.

## Risks

- A helper name that suggests sanitization could invite callers to pass raw
  secrets. Its documentation must state that invalid input is discarded rather
  than transformed and that the caller owns the safe fallback.
- Making the helper public adds one supported API symbol. This is justified by
  production consumers in separate installed libraries, but it should remain
  narrowly scoped to cause construction rather than grow into a generic error
  factory.
- Changing exception behavior for an invalid fallback would alter an existing
  invariant boundary. Tests must pin the current behavior.
- Broadly replacing all `create_cause` calls would be incorrect. Already
  validated wrapping and strict decoder paths must stay explicit.

## Consequences

Safe lower-message projection now has one implementation and one tested fallback
sequence. The six production boundaries retain their existing metadata and
observable error output while no longer duplicating validation branching and
invariant unwrapping.

`create_cause` and JSON decoding remain strict trust boundaries. Future callers
that deliberately accept an untrusted lower string must supply an explicit safe
fallback and opt into the new helper; no automatic sanitization, truncation, or
global fallback policy is introduced.

## Questions

- None.
