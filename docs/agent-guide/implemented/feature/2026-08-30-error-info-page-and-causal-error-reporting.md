# Error Info Page and Logseq DB Worker Error Reporting

## Problem

The application has no complete surface for errors owned by the
`logseq-db-worker` domain. Worker failures currently reach the application
through several shapes:

- `Logseq_db_worker.Protocol.Failed` carries `Logseq_db_worker.Error.t`, but
  `Journal_graph_runtime` and `Application` often retain only `Error.message`;
- graph-open failures retain `Error.t` briefly and then become a flat
  `graph_error : string option`;
- feed, read, mutation, managed-sync coordination, and service-terminal failures
  can become `Feed_failed of string`, `Rejected of string`, `Failed of string`,
  or `Terminal of string` before application presentation;
- the worker error itself has a stable code, primary message, and flat details,
  but no causal chain for lower storage, snapshot, ownership, planner, codec, or
  operating-system failures; and
- capture SnackBars, graph replacement content, and sync overlays are transient
  contextual surfaces rather than a reviewable worker-error history.

The Timeline AppBar currently has no action indicating that a worker-domain
error has occurred. A later success or unrelated error can remove or replace the
only visible message, so the user cannot inspect all worker failures observed by
the running application.

A repository audit found that lower causes are frequently discarded inside the
domain:

| Worker-domain boundary | Current loss |
| --- | --- |
| Snapshot and graph location | Detailed catalog, inbox, path, manifest, publish, and native-location failures are mapped to generic `Graph_not_found` or `Corrupt_storage` messages. |
| Ownership | Stale-lock, identity-change, sentinel, and revalidation failures collapse into one ownership-recovery or terminal string. |
| SQLite storage and storage session | Typed begin, write, commit, checkpoint, close, corruption, staging, and persistence errors are converted to a single message, generic worker category, or fatal exception. |
| Query, read model, and outliner | Parser, selector, cursor, planner, and mutation failures may be replaced by stable public errors without retaining the lower diagnostic reason. |
| Worker Engine | Several mappings deliberately provide safe public summaries but discard the source error; fatal storage transitions also raise only a string. |
| Worker protocol and Bonsai service | Structured `Error.t` values are flattened when responses are adapted to graph-runtime responses or service outcomes. Managed coordinator failures may also originate below the worker adapter and arrive as strings. |
| Application boundary | `Open_failed` preserves `Error.t`, while `Feed_failed` and `Rejected` do not. `Application` ultimately stores independent strings and has no occurrence ledger. |

This exploration is intentionally limited to the `logseq-db-worker` domain. It
does not create a general application error center. Dart host, Apple host,
authentication, application-platform, pure sync transport, and UI-only failures
are out of scope unless a failure becomes the cause of a worker operation that
terminates with a `Logseq_db_worker.Error.t`.

“All worker-domain errors” means every actual `Logseq_db_worker.Error.t`
occurrence emitted by the shipped app runtime, including recoverable request
failures, graph-open failures, managed-worker failures, and terminal worker
failures. A syntactic `Result.Error` used internally as expected parser control
flow is not a separate page entry when it is fully handled before a worker
operation fails. If that rejection causes the operation to return a worker
error, the returned worker error is included and the rejected lower value is
retained as a cause.

## Proposal

### Make `Logseq_db_worker.Error.t` causally complete

Keep `Logseq_db_worker.Error.t` as the canonical domain error and extend it with
an ordered, bounded causal chain. The conceptual shape is:

```ocaml
type cause =
  { component : component
  ; operation : string
  ; code : string option
  ; message : string
  }

type causal_trace =
  { contexts : cause list
  ; origin : cause
  ; truncated : bool
  }

type t =
  { code : code
  ; message : string
  ; details : detail list
  ; trace : causal_trace
  }
```

`code`, `message`, and `details` remain the stable worker-domain classification
and concise primary summary. `trace.origin` is the immutable, sanitized actual
error produced at the lowest failing storage, snapshot, ownership, codec,
planner, or dependency operation. `trace.contexts` preserves every outer layer
that explains how that origin became the worker-domain failure.

Adopt one wrapping rule throughout the domain:

> A caller that maps or wraps a lower failure may add a public worker code,
> summary, and outer context, but it must preserve the lower trace byte-for-byte
> after sanitization. An upper-layer error message must never overwrite, replace,
> or masquerade as the actual origin error.

For example, the primary error may remain `corruptStorage: The graph storage is
corrupt or incomplete.` while the causal section records `Restore database`,
`Read storage root`, and a sanitized SQLite code/message. Ownership recovery may
retain its stable user guidance while naming the failed lock or sentinel
operation and the safe underlying filesystem reason.

Creating a direct worker validation error creates its worker code and message as
the origin. Wrapping an existing causal error only prepends a context; it cannot
edit the existing contexts or origin. Mapping a lower non-worker error must first
create an exact sanitized origin from that error's native code and message, then
add the worker classification around it. Tests must compare the retained origin,
not merely assert that some lower text appears in the final rendering.

Do not concatenate causes into the primary message. Structured traces are
needed for per-field bounds, redaction, protocol encoding, tests, and accessible
page rendering. Do not keep a string-only compatibility constructor or decoder
after the structured cutover.

The causal contract must be preserved by:

- `logseq_db_storage` errors consumed by the worker;
- snapshot, graph locator, ownership, backup, synced mirror, and synced snapshot
  parsing;
- query, read-model, outliner, mutation planning, storage session, and Engine
  execution;
- worker protocol request rejection and response encoding;
- managed worker coordination and the Bonsai worker service; and
- `Journal_graph_runtime` and `Application` adapters.

Domain-specific error variants may remain where callers need them for recovery
or branching. They must provide a lossless display-safe projection when they are
wrapped into `Logseq_db_worker.Error.t`.

### Preserve `Error.t` through the application boundary

Remove string-only worker-failure adapters. `Feed_failed`, `Rejected`, managed
service `Failed`, graph lifecycle failure, and worker `Terminal` outcomes should
carry `Logseq_db_worker.Error.t` plus their existing safe request metadata where
applicable. `Error.message` may be selected only at the final contextual-render
call site; it must not replace the structured value in state or transport.

Every worker-domain error occurrence received by the running application is
appended exactly once to an application-owned worker error ledger. The ledger
entry should contain:

- an application-minted occurrence sequence and identity;
- the complete `Logseq_db_worker.Error.t`;
- request ID, failure phase, and basis when supplied by `Protocol.Failed`;
- graph generation and graph ID when safely available;
- the worker operation or service outcome that published the error; and
- whether the associated worker problem remains active or has subsequently
  recovered.

The ledger retains every occurrence for the lifetime of the current runtime. It
is in-memory only, is not persisted across restart, and is cleared only when that
runtime is replaced or exits. It must not silently cap, deduplicate, truncate, or
drop occurrence entries within the runtime.

Equal errors from separate attempts remain separate entries. Propagation of one
error through Engine, protocol, graph runtime, and Application creates one entry,
not one entry per layer. The terminal application-visible worker adapter owns
publication; lower layers only wrap and return the same error.

The ledger is not a second worker protocol and does not participate in recovery
decisions. Typed codes continue to drive recovery before the error is projected
for presentation.

### Add the Error info page and conditional AppBar action

Add an **Error info** action to `Journal_header`'s Timeline AppBar. Use a
Material error-outline icon with the accessibility label `Error info` and a hint
such as `Review Logseq DB worker errors`.

The action is absent when the worker error ledger is empty and present after the
first worker-domain error occurrence. It must not reserve a placeholder toolbar
slot while hidden. The existing Account action remains available, with stable
semantic order in LTR and RTL layouts.

Pressing the action pushes a real navigator page named **Error info**. The page
has its own back action and a vertically scrollable newest-first list. Every
worker error entry shows:

- worker error code and primary message;
- request phase, operation, basis, graph scope, and structured details when
  available and safe;
- active or resolved status;
- occurrence order and a timestamp when a valid app calendar is available; and
- the complete outer-to-inner causal chain.

Repeated occurrences remain separate. Causes are visually nested and exposed in
accessible reading order. Use cards, spacing, and typography instead of repeated
separators; the page must contain no more than three dividers at every viewport
size. The page is read-only, performs no worker command or polling, and updates
live when another worker error arrives. Back restores the exact prior route
without retrying, clearing, or mutating worker state.

Existing contextual worker-error presentation remains useful. A capture or
mutation can still show concise failure feedback, a graph-open failure can still
replace Timeline, and a worker failure can still expose the relevant recovery
action. Those surfaces should reference the same structured occurrence and
render its primary message. Obsolete app-owned worker-error strings should be
removed instead of being synchronized with the ledger.

Error info supplements these contextual surfaces; it does not replace them.
Contextual UI remains responsible for immediate feedback and recovery, while
Error info remains responsible for reviewing every worker error occurrence and
its causal trace.

The existing Diagnostics page remains responsible for sync, startup, and graph
phases plus sync transition history. It must not gain a second worker error
history. Pure sync `last_error` values do not enter Error info unless they are
also the cause of an emitted worker-domain `Error.t`.

### Audit every worker-domain error path

The implementation audit should cover production code in:

- `logseq_db_worker/lib/` and `logseq_db_worker/lib/outliner/`;
- `logseq_db_worker/bonsai/`;
- `logseq_db_storage/lib/` where its errors are consumed by the worker;
- `logseq_db_types/lib/` where validation failures become worker errors;
- `app/journal_graph_runtime.*` and the worker-event handling in
  `app/application.ml`; and
- sync implementation paths only where the managed worker service converts a
  sync-owned failure into a worker-domain terminal or request error.

For every `Error _`, `catch`, exception conversion, `failwith`, `invalid_arg`,
generic mapper, and terminal string in that corpus, classify the site as:

- creating a worker-domain error occurrence;
- wrapping and propagating a lower cause;
- intentionally consuming expected internal control flow; or
- converting an invariant violation at one top-level worker boundary.

No operational failure may remain in a bare wildcard-consumption branch. Every
intentional non-reporting branch needs a focused test demonstrating that it does
not represent a failed worker operation.

CLI, fixture, benchmark, and test-process failures cannot appear in the running
app's page. When those entrypoints receive `Logseq_db_worker.Error.t`, their own
output should render the same code, message, details, and causes rather than
flattening the error. Test-only assertion failures and intentionally malformed
fixture results are not app ledger entries.

### Keep causes bounded and display-safe

No worker error or cause may contain authentication tokens, passwords, graph or
private keys, encrypted payloads, transaction payloads, datoms, block text,
signed URLs, raw HTTP bodies, complete home-directory paths, or unbounded
dependency values. Raw exception strings and stack traces are not automatically
display-safe.

Each lower boundary must project an allowlisted code and bounded sanitized
message before wrapping it. Error info displays only sanitized causes; raw
exception text and stack traces are not part of this page. Redaction happens at
the source, and Error info must not parse arbitrary strings to discover secrets.
The error protocol must define explicit limits for context depth, context count,
per-message bytes, total encoded error bytes, details, and list-valued details.
If a trace exceeds a bound, the error must preserve its actual sanitized origin,
retain the deepest useful contexts that fit, and set `truncated = true`. An outer
message must never replace the origin as a truncation strategy.

Changing `Logseq_db_worker.Error.t` and its protocol belongs to the worker
domain and should not require changes to OCaml files under `spec/`. If managed
worker integration reveals that a `logseq_sync/spec/**/*.mli` change or a Dune
change is required, implementation must stop and report the exact specification
issue for explicit approval. It must not use a string fallback or compatibility
path.

### Test boundary

Implementation should include:

- exhaustive construction, wrapping, JSON round-trip, byte-bound, truncation,
  and redaction tests for every `Logseq_db_worker.Error.code`;
- injected lower failures across snapshot, graph location, ownership, backup,
  synced mirror, SQLite, storage session, query, read model, outliner, mutation,
  Engine, protocol, managed coordination, and worker service paths;
- tests proving every mapped error retains its lowest display-safe cause;
- immutable-origin tests proving every wrapper leaves the actual sanitized
  lower code and message unchanged while adding only outer context;
- tests proving one propagated error creates one ledger entry while two equal
  worker failures create two entries;
- tests covering Open, Execute, managed request failure, graph lifecycle
  failure, and terminal worker failure metadata;
- AppBar tests proving the action has no slot before a worker error and is
  visible, ordered, accessible, and actionable afterward;
- navigation, back restoration, live update, narrow viewport, large text, RTL,
  newest-first order, nested causes, and maximum-divider tests;
- contextual UI tests proving existing worker recovery presentation renders the
  same structured occurrence's primary message;
- negative tests proving host, authentication, platform, UI-only, and pure sync
  errors do not enter the worker ledger unless they terminate a worker operation
  as `Logseq_db_worker.Error.t`; and
- source-boundary tests preventing string-only worker failure adapters, lossy
  `Error.message` storage, operational bare `Error _` consumption, duplicate
  histories, and compatibility decoders.

## Decision

Adopt the proposal with the following product decisions resolved by the user on
2026-08-30:

- retain every worker error occurrence only for the current runtime; do not
  persist the ledger across app restarts and do not drop entries while that
  runtime remains alive;
- keep existing contextual worker-error and recovery presentation, with Error
  info as a supplementary review surface; and
- display only sanitized causes. The actual sanitized origin error is immutable,
  and no upper-layer error message may overwrite or replace its code or message.

## Alternatives considered

### Collect every application and host error

This was the prior scope, but it is broader than the requested
`logseq-db-worker` domain. It would require host startup buffering, platform wire
changes, authentication policy, and a general application incident model that
are unrelated to making worker errors complete and reviewable.

### Add current worker strings to Diagnostics

Diagnostics has no worker error occurrence stream and is designed for lifecycle
state and sync transitions. Adding current strings would still lose transient
failures, structured details, repeated occurrences, and lower causes.

### Concatenate lower causes into `Error.message`

This keeps signatures small but destroys the distinction between stable primary
copy and diagnostic causes. It cannot enforce per-cause bounds or redaction,
round-trip structure, render accessible nesting, or prove that a mapper retained
the original cause.

### Record every internal `Result.Error` as a page entry

Many internal errors are intermediate representations of one failed operation,
and some are expected parser/control-flow branches. Recording each layer would
duplicate one failure several times. The page records every emitted worker
domain error occurrence once and retains intermediate failures in its causal
chain.

### Keep only the latest worker error

This is simpler but does not satisfy the requirement to display all observed
worker errors. Later success or another failure would erase useful diagnostic
history.

## Acceptance criteria

- Every `Logseq_db_worker.Error.t` occurrence emitted to the shipped application
  by worker open, request, managed coordination, lifecycle, or terminal paths is
  appended exactly once to the canonical worker error ledger.
- Separate equal failures remain separate entries; propagation through multiple
  layers never duplicates one occurrence.
- Every entry retains worker code, primary message, structured details, safe
  request/scope metadata, and the complete bounded display-safe causal trace,
  including the immutable actual origin error.
- Every worker-domain mapper retains the lower cause while adding its own
  context; no generic or upper-layer summary changes or destroys the origin code
  or message.
- All existing worker codes and all identified snapshot, ownership, storage,
  planner, Engine, protocol, and service failure paths have deterministic
  injected-failure coverage.
- Expected internal control flow is not recorded as a separate occurrence, but
  any resulting worker operation failure includes that lower rejection as a
  cause.
- The Timeline AppBar has no Error info action or reserved slot while the ledger
  is empty and exposes the accessible action after the first worker error.
- Error info is a dedicated, read-only, live-updating navigator page that lists
  every retained worker occurrence newest first and restores the prior route on
  back.
- The ledger retains all occurrences until the current runtime exits or is
  replaced, does not persist them across restart, and never drops or deduplicates
  them within that runtime.
- The page renders complete nested causes and uses no more than three dividers.
- Existing contextual worker recovery UI renders the same structured occurrence
  instead of maintaining an unrelated worker-error string; Error info supplements
  rather than replaces contextual feedback and recovery.
- Host, authentication, application-platform, UI-only, and pure sync failures
  are excluded unless they materialize as the cause of a worker-domain error.
- Worker error values and protocol envelopes obey explicit bounds and contain
  none of the prohibited secret or content fields.
- CLI and tool consumers render structured worker causes to their own output but
  do not attempt to publish into an unavailable app page.
- String-only worker failure fields, protocol paths, adapters, aliases, and
  fallback decoders are removed without compatibility layers.
- No OCaml file under `spec/` or Dune file is modified without explicit approval.

## Consequences

- Worker errors now have one structured, bounded, display-safe representation
  from their lowest cause through protocol and application presentation.
- The application retains an in-memory occurrence ledger for the current
  runtime and exposes Error info only after a worker error has been observed.
- Existing contextual failure surfaces share the ledger occurrence while pure
  sync, host, authentication, platform, and UI-only errors remain outside the
  page unless they terminate a worker operation.
- Protocol consumers must provide causal traces; legacy string-only error
  payloads and adapters are intentionally unsupported.
- Runtime memory use grows with the number of worker error occurrences until
  the runtime exits or is replaced, as required by the complete-history policy.

## Risks

- Extending the worker protocol changes every producer and consumer of
  `Logseq_db_worker.Error.t`; one missed string-only adapter would silently
  recreate the causal-loss problem.
- Publishing at multiple layers can duplicate one worker occurrence. Publishing
  only at the final adapter requires asynchronous terminal paths to have an
  equally explicit owner.
- Low-level usefulness and privacy are in tension. Over-redaction recreates
  generic errors, while under-redaction can expose graph content, credentials,
  identifiers, or local filesystem identity.
- Context bounds can omit outer diagnostic steps during a long wrapper chain.
  The truncation policy must always retain the actual sanitized origin and report
  truncation deterministically.
- Retaining every occurrence until the runtime exits can grow memory usage during
  a persistent retry loop. This is an accepted consequence of the selected
  current-runtime completeness requirement.
- Existing contextual UI currently depends on independent strings. Removing
  them requires careful correlation between active worker failures and
  historical occurrences without introducing a temporary compatibility source.
- Some managed-worker failures originate in sync implementation. If the current
  boundary cannot construct a worker error with a complete cause without
  changing protected sync specifications, implementation must stop rather than
  flattening the error.

## Questions

- None. Runtime retention, supplementary contextual presentation, and
  sanitized immutable-origin reporting are resolved in the Decision section.
