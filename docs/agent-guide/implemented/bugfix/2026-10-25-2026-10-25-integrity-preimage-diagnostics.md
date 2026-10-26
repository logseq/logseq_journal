# 2026 10 25 Integrity Preimage Diagnostics

## Problem

The phone reports accepted create-journal-page payload-mismatch (expected five
datoms, actual seven) after Web updates, reported sync catchup, an empty Timeline
and Capture. Counts do not identify the missing page fields or redundant
protected-value operations; later logical reads can be masked by the outbox.

## Decision

On published main bfd603e, add bounded structured console diagnostics at the
integrity failure's authoritative root_before, plus Capture page lookup/create
correlation and Worker Missing_page snapshot versions. Allow only UUIDs, dates,
scope/version tokens, finite attribute/type labels, counts and boolean flags.
Never print values, plaintext/ciphertext, exception strings, tokens or keys.
Keep existing errors and their 512-byte carriers intact. Do not modify sync,
retry, commit or validation decisions. No protected spec interface change is
needed. The initial investigation stayed local; later publication authorization is recorded below.

Implement the three private observation points without changing public interfaces
or synchronization decisions. The overlay database owns the immutable replay
preimage; pure reducers cannot inspect it. Temporary behavioral/privacy checks
therefore exercise the public Database boundary, with separate checks of the
actual Worker snapshot and Capture runtime correlation. No permanent CI test or
Dune change is needed for this local investigation.

During integration with the unified30-root Timeline, observe its current date catalog, exact-Today probe, depth-zero root queries and bounded child-preview queries. Preserve request UUID allocation and query arguments. Report the actual Feed completion flag and root counts from the new scanner; removed tree-slot budget fields and the deleted legacy Feed owner are not restored. The initial-interest flag reads the new initial_feed_spec owner. No additional graph read is issued for logging.

## Alternatives considered

### Ordinary post-failure get_pages

The optimistic Capture outbox may already synthesize a complete page, concealing
the authoritative preimage. Inspect the validator's existing preimage instead.

### Broad raw transaction or exception logging

Rejected because it can disclose graph content and credentials. A compact
allowlisted technical shape is sufficient to distinguish the hypotheses.

## Consequences

Five temporary behavioral/privacy checks, the existing Overlay synchronization
suite, Runtime locality suite and Worker integration check passed. The exact
source candidate built and ran in the authorized Simulator/Web test graph after
the user approved its data-preserving experimental installation. Both an existing
date-page update and a previously absent future date-page/reference control
displayed automatically before Capture; both subsequent Captures synchronized
successfully. The Captures targeted the existing current-day page and did not
exercise accepted create-journal-page failure. This does not establish the phone
root cause or full cross-ABI validation. Preserve that limitation and keep the
change local until publication is separately requested.

## Timeline correlation follow-up

The user subsequently prioritized the earlier equal-TX/empty-Timeline condition.
Three real Web/A135 controls on 6708 passed: foreground empty Today to a nonempty
remote root, cold catchup, and background/resume followed by ordinary refresh.
They do not reproduce the phone failure. The user authorized additional safe
diagnostics, not a speculative synchronization fix or another data-App install.

Add private bounded observation points for authoritative commit/checkpoint and
logical interests; Worker query/window versions; Runtime change-window, Feed
request/response ownership; Application Feed acceptance/discard reasons and row
store publication. Restrict samples to sixteen UUIDs, encode int64 generations as
strings, reject unexpected external version labels, and contain output failures.
Never log content, property values, exception strings, URL/query strings or crypto
material. Keep the existing state transitions, validation and public interfaces.

The App's existing current_graph_generation helper actually returns the selected
graph UUID. Record that UUID separately from account/graph/Worker counters rather
than mislabelling it as an incarnation counter. This naming observation does not
prove a stale-response bug: graph retirement also cancels request leases and
clears Runtime ownership. No business-rule correction is included here.

Temporary checks exercise public Overlay, Worker, Runtime and Application
boundaries. Deliberately withholding notifications or retiring a completed feed
is a mechanism/control experiment, not a reproduction of production loss.
Baseline behavior and failed-output behavior must remain equivalent. No permanent
CI tests, protected spec files or Dune files are changed. Build a separately
identified experimental candidate; report its exact inputs and compatibility
limits and obtain specific approval before any data-preserving A135 install.

## Acceptance criteria

- Write the privacy and evidence tests first and observe missing-log failures.
- Synthetic payload mismatch emits exact field presence/types, add/retract counts
  and protected same-value pair flags without body or private attribute leakage.
- Existing error, checkpoint and outbox preservation tests still pass.
- Final candidate builds with pinned dependency provenance; no sync algorithm fix.
- Actual Simulator/Web tests use only ocaml-sync-test and preserve other graphs.
  Report lock/auth/ABI/install blockers and actual coverage without claiming an
  unreproduced phone root cause or verified cross ABI.

## Risks

- Technical UUID/version correlation is intentionally logged, but no graph values.
- Logs may not recover a prior event; preserve outbox and wait for a safe retry.
- Simulator host restamping is experimental; install over an existing data App
  requires the separately scoped risk confirmation specified by the parent.

## Questions

- Diagnostic scope and actual test-graph writes were approved in the user's
  2026-10-25 instruction relayed by the parent; no implementation question remains.
- Phone build remains unknown; the selected baseline is verified main bfd603e.

## PR preparation

The user authorized an independent diagnostic PR on 2026-10-25. This change adds
observability and does not fix the reported Capture/integrity or stale Timeline
problem. Final checks pass: six temporary diagnostic/privacy/failed-output tests,
98 Overlay sync tests, 152 Runtime locality tests and 15 Worker integration tests.
The 6709 exact-source candidate completed real test-graph foreground and cold-start
Web/Simulator correlations with 972/972 and zero outbox; both ordinary paths
worked, so neither is evidence the phone defect is fixed. ABI remains unvalidated.
The subsequent conditional Feed/empty-state findings are a separate investigation;
no corresponding business repair is included in this diagnostic PR.
