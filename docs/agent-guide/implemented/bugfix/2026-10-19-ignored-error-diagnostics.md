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
- Background detail reconciliation retains its prior projection when time/projection rebuilding fails (`app/journal_graph_runtime.ml`, baseline 2970/2983), but must report the skipped refresh. The initial PR head 900326b only logged these errors; that was an observability gap. The follow-up below adds ordinary app response reporting and current-scope Worker enrichment/close/retirement reports without changing protected contracts or making the graph fatal.
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

Temporary-file cleanup after successful photo/import operations and false SQLite close results now receive fixed cleanup warnings. Idempotent removal of an already absent temporary file remains silent. These reports contain no URL/path, content or underlying exception text, and do not change the primary outcome, retry schedule, graph deletion or resource-ownership policy. Secondary cleanup under an already propagated primary error can still preserve that primary result; the new close warning also makes an unsuccessful temporary-handle release observable.


## PR96 producer-to-Diagnostics correction

The user correctly identified that the old/new line2970 `eprintf` at head900326b wrote only stderr. Neither that branch nor sibling2983 emitted a failure response, ledger occurrence or Diagnostic. A recovery word in a log did not schedule recovery. Do not describe that head as complete Diagnostics coverage.

- `Projection_unavailable` in the ordinary app runtime interface carries only the two fixed projection operation cases. The real calendar/projection producer emits it; Application records a bounded, deduplicated nonfatal issue with fixed reason, presentation stage, current graph generation and page/reopen recovery. The Diagnostics renderer and public pure reducer observation share `application_error_rows`; no test copies the rendering rules. Existing request ownership and reset fence late responses. Drafts and prior projections are retained.
- Mounted list outer JSON, row-action JSON and native widget decoding report through a dynamically bound Application handler around dispatch **and flush**. LUI queues callbacks until stabilization; binding only during dispatch loses the report. The callback is restored after each call, including exceptions/nesting, rather than retaining an application callback across sessions. LUI rejects unmounted events and changed callback registrations before invoking the decoder. The dormant generic event-handler helper uses the same path.
- UI reporting now creates a display-safe typed error directly from fixed text. The previous service-error wrapper replaced the reason with an unrelated generic Worker-unavailable message. Per-occurrence recovery preserves the specific available page/reopen action. Explicit account clear also clears the ledger.
- Current `readTagTitles` fallback, close-database failure, deletion durability confirmation failure, and pending local-retirement completion use existing `Core.Diagnostic` plus fixed service allowlist entries. Enrichment keeps the base record; deletion keeps replay receipts and the existing success/durability/retry policy. Reports require the current attached graph or the authorized current account/deletion owner. Owned picker detach advances graph generation before closing; its close report accepts the same account while no replacement graph is selected. Shutdown and superseded account/graph cleanup remain fenced.

### Complete disposition of added log-only boundaries

| Boundary | Disposition after correction |
| --- | --- |
| Runtime detail calendar/rebuild; view list/row/widget decode | Real producer to Application ledger and Diagnostics; no fatal transition. |
| Worker tag-title enrichment | Existing Diagnostic to Worker errors. No raw tag/title text. Current attached scope only. |
| Worker current close / deletion confirmation / finish | Existing Diagnostic to Worker errors, with current-owner fencing. Deeper lifecycle and deletion durability fixes remain separate. |
| Draft release and application disposal | Disposal retires `running` and `current_app` first; no live UI ledger remains. Fixed secondary cleanup logs only. |
| Worker abort-local-retirement and account/coordinator journal cleanup | Abort preserves the already propagated primary deletion error. Retired journal cleanup retains replay; fixed logs only, no scheduled retry claim. |
| Overlay/storage temporary SQLite close, ownership release/rollback, mirror collection | Secondary cleanup / retired ownership / temporary-handle reports; fixed logs only. A current Worker close failure additionally receives the Diagnostic above. |
| Sync staging/retired asset collection | Retired resource cleanup, with existing deferred collection. Fixed logs only; no current graph attribution or invented retry timer. |
| Swift temporary attachment/photo cleanup; credential revocation/legacy/binding cleanup | Original operation or local-clear policy is retained; current picker batch failures already reach UI/ledger. Fixed cleanup logs are not represented as Diagnostics. |
| Swift Runtime/C callback failures | Observable native failure/retry surface when OCaml UI cannot be reached. Safe logs are secondary to that surface. |
| Native props/encode/delivery replacements | Existing mounted revision-checked diagnostic envelope to Application ledger. Unmounted or superseded revision is ignored. The secondary diagnostic-delivery catch logs a fixed code if that report itself cannot be delivered. |

Unchanged primitive Codable encode guards in the attachment picker encode only strings/integers/arrays of those fixed structs. Their encoding failure is not a demonstrated current producer defect; this follow-up does not add a new schema, permission flow or wire correlation mechanism. User cancellation, stale scopes and already propagated primary errors remain distinct from current failures. The external audit table records each concrete file/caller; it is not checked into the repository as temporary review evidence.

### Regression ownership and limits

The new pure composition reproduces both projection failures through `Runtime.submit/receive`, a missing calendar or a failing host clock, and normal Worker responses; it then consumes actual responses through `Root_navigation.step` and the real Diagnostics row projection. It asserts safe operation/reason/stage/scope/recovery, active dedup, account clear, retained draft, healthy/no-issue, reset/no-issue and duplicate/no-issue. No already fabricated error is injected. Mounted view decode ownership is outside that pure boundary, so the narrow existing synthetic Application fixture exercises real list/row/page-widget decoding and rendered Diagnostics.

The retirement regression uses a synthetic temporary mirror: after preparation, the receipt directory is made readable but unwritable. The real canonical rename completes and confirmation rewrite fails; the test asserts canonical removal, another graph remaining open, false/replayable receipt retained and the fixed Diagnostic. This reproduces physical IO at the narrow public Worker boundary, without a real graph or App installation.

`Database.get_pages` returns errors only for a closed owner or released snapshot at this enrichment point; malformed page records become missing pages. The public runner exposes no deterministic callback between the base read and enrichment. No fake corrupted-page test is claimed as producer coverage. Current enrichment and close reports are statically traced with their scope fences; deterministic physical enrichment/close fault coverage remains a test limitation.

The local follow-up environment could not locate `spec-dev-tool` in PATH, common install locations or exact-name Spotlight search. Its help command was attempted; the existing decision format and sections were preserved. Historical head900326b validation is not represented as fresh validation of this correction.


### Follow-up validation

The final correction passes all-target and native-embed object builds. Relevant local regressions pass: Application132, Worker runner26, Sync147, Overlay storage63, and the Worker service suite. RED evidence includes the exact calendar2970 and sibling time producer, list/row decode, a page-chrome decoder selected by actual ownership, and caught retirement-confirmation filesystem failure. Restoring the page decoder to its prior `eprintf` behavior makes the same rendered-Diagnostics test fail; restoring reporting makes it pass. Healthy, reset, duplicate and cancellation coverage stays green. Independent read-only review found no blocking issue in the correction; final Git commit review and remote exact-head CI are recorded in the PR.

## Merge follow-up review (2026-10-19)

Subsequent GitHub findings were independently confirmed after the earlier exact-head review. Feed failures now record diagnostics only after the current request generation is accepted. Native stop failure keeps cleanup retryable and the host only creates a replacement after successful cleanup. Fixed secondary warning output is non-throwing, preserving committed deletion results and later resource release when stderr is unavailable. These corrections keep existing protected interfaces and Dune files unchanged.

The isolated correction `988fc5049900a7000e0f9ccd6a4d0a79f279f3f8` observed meaningful RED then GREEN: Application 134, Overlay storage 64 and native Runtime 11 scenarios. A fresh independent review found no blocking issue. Native Runtime checks compile production Swift with a controlled C/backend capability fixture; they are not Host UI, real remote service or iPhone acceptance. Full macOS Swift typechecking hits the unchanged JournalChrome iOS-only API; no iOS typecheck or device acceptance is claimed from that command. Final combined build/CI and strict iphoneos provenance remain separate merge/install requirements.
