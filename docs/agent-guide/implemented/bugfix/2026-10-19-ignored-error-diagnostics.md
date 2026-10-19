# Ignored Error Diagnostics

## Problem

main 49520f0 drops Worker Diagnostic outputs, advisory catalog-save errors, and several native/UI failures. An operation can stop making progress while Diagnostics contains no usable explanation. Raw exceptions cannot safely replace the missing report. The user authorized a separate minimal error-visibility fix and PR, explicitly excluding complex lifecycle, persistence, retry-policy and protocol-correlation changes.

## Decision

Use the existing Diagnostics groups and existing bounded UI error information to retain safe, scope-specific reports. Forward Worker Diagnostic outputs rather than discard them; retain ignored Sync advisory errors using existing state output; report current UI admission/decoding failures and asset failures. Use fixed operation/code/recovery messages for untrusted errors. Before OCaml Diagnostics is available, expose a minimal native host failure. Do not change protected spec or dune files. The zero-network-startup task owns startup state and its authorized core.mli changes; coordinate overlapping implementation hunks and do not edit its checkout.

Audit every existing suppression candidate against its caller and document handled, intentional cancellation/stale-scope, primary-error-preserving cleanup, deferred collection, and complex work requiring a separate task. Retain current retry and deletion semantics. No new persistent history system, request-ID protocol, real graph modification, device installation or Simulator use.

## Alternatives considered

### Convert every error into fatal

Rejected: cancellation, stale owners, advisory writes and individual attachment failures do not invalidate an entire graph. Existing terminal behavior remains owned by its reducer.

### Log raw exceptions or add a new persistent subsystem

Rejected: unsafe details may include credentials/content, and a new history system exceeds the user's narrowed scope. Existing in-memory Diagnostics is sufficient for this patch.

## Acceptance criteria

- Write necessary producer-to-Diagnostics and native-host boundary regressions first; observe meaningful RED before implementation and GREEN afterward.
- Current swallowed failures appear through existing Diagnostics with fixed code/operation/recovery and bounded storage. Stale scope and intentional cancellation do not pollute current issues.
- Reports never forward raw exception/server strings, private paths, tokens or graph content.
- Preserve queue, retry, deletion and startup policy. Do not modify protected spec/dune interfaces without a separately reviewed exact diff.
- Run appropriate isolated tests, request independent review, fix actionable findings, and create a separate unmerged PR.

## Risks

- Existing Diagnostic string lacks structured origin. Unknown producers receive a fixed safe fallback rather than exposing their text.
- Reports improve observability, not the known complex lifecycle/persistence defects. Do not claim those bugs fixed.
- Default switch lacks mldoc. Tests used the existing prepared switch read-only, with a shared lock, an external build directory and one job; no other checkout or pin was changed.

## Questions

- None for the authorized reporting-only scope. Any necessary protected-interface change will be proposed separately with its exact diff.

## Suppression disposition (baseline main 49520f0)

The repository-wide review followed callers through startup/account/restore, storage/migration/outbox, HTTP/WebSocket/E2EE, asset/capture/mutations, UI loading/navigation, Swift/C/runtime/pump, and queue cancellation/admission. The search index was a locator, not a defect classifier. This patch addresses visibility, not every underlying defect.

### Handled in this change

- `logseq_db_worker/lib/pure_reducer/core.ml` effect failures already emit `Diagnostic`; `lui/logseq_db_worker_lui_service.ml` previously discarded it. Fixed producer codes now become bounded (16, deduplicated by operation) Worker errors alongside existing Sync groups. Scope generation changes clear them. Unknown Diagnostic text maps to a fixed fallback; raw producer strings never become UI text.
- Sync `Save_catalog_kind` advisory failure (`logseq_sync/lib/pure_reducer/core.ml`, baseline 2574) retains its open graph and publishes a fixed Sync error. `effect_runner.ml` checks `close_out`, so flush errors reach that existing completion; no new persistence/atomic-write protocol.
- Application manager admission refusals, current platform failure, capture decode/partial selection failure, accepted detail/favorites failures, and projection failures enter the existing ledger/Diagnostics. The ledger is capped at 32 and cleared on account/graph owner changes. Active-only dedup allows a new occurrence after resolution. Diagnostics displays Active/Resolved. Picker errors are recorded only after request/owner admission.
- Exhausted asset download and upload failure notices join Diagnostics only for the current account/graph generations. Current retain/release/preview/metadata errors and retry-timer failures use fixed reports. Upload staging cleanup reports only while its generation is current; old-scope cleanup and database close receive fixed logs rather than being attributed to a newer graph.
- Native startup rejection, initial patch failure/missing root, later patch/pump/event failure reach a safe host recovery surface. Failed init disposes a published app context and stops its Worker; the native rejection path calls bridge stop. C exception logging no longer formats arbitrary exception text.
- Mounted extension decode/delivery failures reuse the existing event envelope. Reporting is deferred out of SwiftUI body evaluation and rechecks node revision at delivery. Unmounted/changed nodes are ignored. No fingerprint, schema, wire version, or request-ID change.
- Account revoke/legacy retirement/background binding cleanup, committed retirement/GC and coordinator-journal cleanup failures receive fixed codes in logs. They retain their existing local-clear/deferred-collection policy; no retry timer is claimed.

### Reasonable ignores retained

- Old account/graph generations, retired tickets/sockets/native nodes and duplicate completions are rejected by their existing owners. Late owned resources continue through reclamation; rejection is not a new current issue.
- User cancellation, disabled native interaction, promise `try_resolve=false` after an existing completion, and deliberate cancellation of superseded work do not create a current failure.
- `Reconcile_authenticated_user` with data-queue Full is already staged through Latest control before data reservation, so it is not a lost command.
- Worker Apply_local/Apply_metadata `Error -> ()` branches only skip a success notification; immediately afterward `finish ticket result` delivers the same failure. WebSocket connect `Error -> ()` only skips retaining a handle; the result is still classified and completed.
- HTTP bounded token reacquisition, WebSocket recoverable reconnect and pull no-progress paths actually schedule their existing timers/effects. Permanent auth/protocol errors remain manual recovery. E2EE invalid/missing cached key paths fall back to existing fetch/unlock flows; no key/password is reported.
- Picker load/copy failures contribute to the existing partial-batch error; successful picks and drafts remain available. Photos failures already have local feedback. Primitive JSON encoders operate on valid fixed/string/integer Codable payloads; event serialization failure returned by JournalLUIEvents now reaches the runtime host.
- Secondary close/rollback/remove failures while a primary error is already propagated do not replace that error. Debug-only log writes do not recurse into application diagnostics. Optional UUID parsing of an invalid presentation interest and asset settings input preserves existing rejection/fallback semantics.
- Storage root-index metadata decoding has a supported legacy fallback; it does not itself prove corruption. CLI/benchmark fixture cleanup is outside the running application error flow.

### Explicit follow-up, not fixed here

- Inspect/attach/inspect-sync failure completion and bootstrap restart/termination are owned by the separate zero-network-startup task. This branch surfaces its existing Diagnostic but does not manufacture a terminal event or change its protected interface.
- Pump batch loss/reentrancy state after an exception, graph fatal-vs-busy lifecycle classification, and deletion receipt/fsync certainty need separate product/state-machine fixes. The native host/log report does not repair those invariants.
- Native platform response correlation is still by tag; short malformed envelopes now publish fixed decodePlatformResponse/decodePlatformFailure Diagnostics. Resolving their original continuation without a recoverable tag, and same-tag overlapping requests, still require a separately reviewed protocol or single-flight decision. Platform callback exceptions now return a local C/Swift admission status and display a fixed native-session host failure; this is not a wire correlation or request-ID change. Pump batch-loss remains a separate invariant, but pump exceptions are visible through the same host recovery surface.
- Background detail reconciliation can retain its prior projection when time/projection rebuilding fails (`app/journal_graph_runtime.ml`, baseline 2970/2983). Tag-title enrichment (`effect_runner.ml`, baseline 950) degrades to missing labels. Those nonblocking fallback boundaries now log fixed, content-free operation/stage/recovery warnings. A structured per-projection issue would require a separate reporting contract; these warnings do not make the graph fatal.
- Existing Sync last_error/legacy display-safe contracts are not replaced wholesale. No persistent diagnostic history, exact per-operation resolution engine, or restart-persistent issue storage is introduced. Some cleanup diagnostics are logs because their causal scope is retired; in-memory issues end with the session/scope.

## Validation and review

- Meaningful RED was observed before the initial catalog reducer, Worker-to-service, application admission/native-envelope and native Runtime changes. Additional review regression demonstrated failed init left `root_node=1` and native rejection omitted bridge stop before the fixes.
- Public-owner boundaries: catalog failure is tested at Sync reducer; Worker Diagnostic loss requires the service adapter because its pure reducer already emits it; admission/native-hook/init failures belong to mounted Application; native admission/renderer failures require the production Runtime with isolated capabilities. No duplicate E2E or real graph/device operations.
- OCaml regression suites: Sync 147, Worker reducer 18, Worker runner 25, Overlay storage 63, Application 125 after the added init and short-platform-envelope tests; service suite also passed. The affected service, Worker-runner and Application suites were rerun after review fixes.
- Headless production Swift Runtime tests cover success/rejection/invalid initial patch, pump failure, all three platform callback failures and both late response/failure after Runtime stop. Exact stage codes are asserted. Actual production C/OCaml bridge tests cover raised platform callbacks and pump exceptions as well as binary delivery, success status and safe exception logging. Native platform service/recovery/threading/cold-start tests passed. Full production Swift source typecheck passed using the pinned existing backend modules; it is not an App/Simulator acceptance build.
- The original Cognito fixture failed before assertions: `SecKeyCreateRandomKey` returned nil (`Security` -50), confirmed with independent parameter probes. In-memory PKCS#1 import and signing worked in the same sandbox. The runner now generates a fresh 2048-bit synthetic key in its private temporary directory and imports it into memory. All seven Cognito groups pass with production RSA verification unchanged; no Keychain/session/permission change, static production key, or signature-verification bypass was introduced.
- Independent read-only review found stale picker/asset scope, synchronous native render reporting, failed-init cleanup and resolved-error dedup issues; all were corrected before PR. No protected spec or dune changes.

## Consequences

Previously discarded errors now have a safe visible report or a fixed secondary-cleanup log. Memory remains bounded and scope transitions clear old issues. This does not establish persistent history or fix the explicitly deferred product invariants. Cognito synthetic-RSA validation now passes with the isolated issuer-key fixture; existing unrelated decision-document validation errors remain unchanged.

## PR96 follow-up

The initial draft was head 895bea0. Follow-up review required lowest-level visibility even where a full product invariant is deferred. The three platform callback C entries now return their existing call's success status; Swift Runtime shows fixed `runtime.platformEvent/platformResponse/platformFailure.failed` recovery messages on rejection. An asynchronous reply is discarded after its Runtime stops. LJP bytes, tags and request correlation are unchanged. Actual pump/C exceptions remain observable even though the deeper lost-batch recovery design is not changed.

Additional retained presentation and collection fallbacks now emit fixed warnings instead of silently swallowing current failures. Staged-preview cache initialization errors retain their typed failure through the existing asset completion rather than becoming successful missing-file results; a physical path-obstruction regression fails on 895bea0 and passes on this change. Ownership close/rollback failures now log fixed secondary codes without changing their result or release policy. Optional invalid input, stale completions, user cancellation and already-propagated primary errors retain their documented treatment. The native boundary regressions assert that arbitrary fixture exception text never escapes stderr.
