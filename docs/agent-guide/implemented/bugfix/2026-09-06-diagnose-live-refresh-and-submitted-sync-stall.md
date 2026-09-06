# Diagnose Live Refresh And Submitted Sync Stall

## Problem
The macOS audit reproduced two sync failures: incoming authoritative changes do not refresh the timeline, and a submitted deletion blocks later writes across restarts. Existing observations establish the symptoms but not their exact causes.

## Proposal
Reproduce both failures against the current worktree. Use isolated, temporary OCaml probes to exercise actual worker and reducer code. Temporarily add bounded local diagnostic logging to the app's existing worker/sync boundary if runtime evidence is necessary. Log event kinds, cursors, phases, and sanitized errors only; never log credentials, keys, or transaction bodies. Preserve and restore the exact original source files after tracing. Record reproduction steps, causal evidence, control cases, and remaining uncertainty. Do not implement fixes in this investigation.

## Decision
Use the recorded live traces and executable diagnostic probes as the basis for separate corrective work. Treat the two established defects as distinct: projection cursor retention, and durable submission recovery. Preserve the historical acknowledgement uncertainty instead of attributing an unobserved network or lifecycle event to the first incident.

## Alternatives considered
### Infer causes from the earlier report

The symptoms alone cannot distinguish transport failure, protocol rejection, outbox state handling, and lost projection notifications. Executable probes and runtime evidence are required.

## Acceptance criteria
- Demonstrate the live-refresh failure with a repeatable event sequence and identify the code path that loses the update.
- Demonstrate the submitted-write stall and identify why acknowledgement or subsequent recovery cannot complete.
- Correlate each cause with real macOS evidence and include a control or counterfactual that distinguishes it from adjacent failures.
- Restore temporary instrumentation and leave existing source, spec, and dune edits intact.
- Validate the investigation document with spec-dev-tool.

## Risks
- Restarting the app can change the live sync state; snapshot the outbox and record times before doing so.
- Instrumentation can affect timing; deterministic probes must independently validate the causal mechanism.
- The existing queue contains only audit markers, but unrelated graph data must remain untouched.

## Consequences
The investigation is complete and reviewable, but neither production defect is fixed. The original pending queue and an isolated interrupted-submission fixture remain available for later validation. A future change must establish correct cursor boundary behavior and a defined recovery outcome for submitted batches; passing the existing suite alone is insufficient because it missed these sequences.

## Questions
None. The user requested detailed reproduction and root-cause investigation of these two sync issues. Fix implementation is outside this decision.

## Investigation outcome
Completed the investigation without implementing production fixes. M01 was reproduced through actual worker helpers: an acknowledged cursor is removed from the retained list, so later pulls return no windows and repeated acknowledgements discard unseen changes. M02 was reproduced in the original macOS mirror and in a disposable live client interrupted after submission: the server applied the deletion, but restart lost the in-memory owner and failed while applying the authoritative pull. Live-owner and overlay acceptance controls succeeded.

The original incident's first acknowledgement was not traced, so its exact initial interruption or unprocessed-response trigger remains unknown. The persistent recovery defect and a sufficient trigger are established independently. Later writes can also be rejected against the stale cursor rather than remaining queued.

Full reproduction steps, source locations, evidence, controls, and limitations are recorded in `docs/test-reports/2026-09-06-sync-root-cause-investigation.md`. Portable local probes are in `docs/test-reports/reproductions/`. Temporary source instrumentation and the support-directory override were restored byte-for-byte; the normal app was rebuilt and relaunched. Build, tests, formatting, and diagnostic probes passed. The original pending queue remains preserved. This decision's implemented status records completion of the diagnostic workflow, not correction of either defect.
