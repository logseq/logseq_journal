# Snapshot admission failure feedback

## Problem

The downloaded graph snapshot is schema 65.29, below admission's minimum 65.33.
Snapshot activation rejects it before decryption, but the worker publishes only a
Diagnostic that the LUI service ignores. Startup remains Bootstrapping indefinitely.
The loading route and Diagnostics do not tell the user why opening stopped.

## Decision

Retain actual/minimum versions in the existing Unsupported_schema error at its
admission owner. Preserve a fixed, content-free rejection message through snapshot
preparation. Route the failed worker completion through the existing scoped
Snapshot_activation_failed event. Use the existing startup Failed page and render
the current snapshot error in Diagnostics. Do not migrate, delete, lower admission
requirements, change cloud data, or promise recovery. No spec/ or Dune edits. Cold-bootstrap Retry reselects its current graph when no
sync view exists; new graph selection clears obsolete failure facts.

The user explicitly approved the actual/minimum payload in lib/admission.mli.
No other protected interface or build definitions changed.

## Alternatives considered

### Timeout detection

A timeout guesses at the cause after production already returned a deterministic
error. Propagate that completion instead. Do not duplicate version constants in UI
or parse private snapshot metadata outside the admission owner for presentation.

## Acceptance criteria

- Current activation failure exits Bootstrapping and publishes the exact safe error.
- The loading route displays actual and minimum schema versions supplied by admission.
- Diagnostics exposes the current failure when diagnostic groups are empty.
- Success, explicit retry, duplicate completions, graph switches and late completions
  preserve ownership and do not restore an obsolete failure.
- Tests are RED before implementation and GREEN afterward. Identify each production
  owner first; use public pure worker events/completions for its propagation defect.
  Admission message retention requires the public snapshot-preparation boundary;
  Diagnostics visibility requires the existing application presentation boundary.
- Simulator acceptance uses an isolated synthetic graph/application and retains the
  original Invest installation, process, snapshot and evidence unchanged.

## Risks

- Generic parse/SQLite errors may contain paths or data: expose only owner-authored,
  fixed error messages and numeric schema metadata, never arbitrary parser strings.
- Experimental Simulator native restamping is not full cross-ABI validation.
- This UI repair does not make schema 65.29 compatible or verify iPhone recovery.

## Consequences

- A rejected snapshot produces a visible terminal error instead of indefinite
  loading. Diagnostics includes its safe current reason even with empty groups.
- Parser/SQLite exception text is discarded at snapshot import; AES failure and
  decrypted Transit parse errors also use fixed text at the E2EE decoder boundary.
  Independent review identified this additional privacy boundary; its two real
  public-runner regressions failed before sanitization and passed afterward.
  Version rejection
  is formatted from numeric metadata owned by admission.
- Retry repeats the opening attempt and may fail again with the same compatibility
  error. It does not upgrade data. Choosing another graph clears the obsolete error.
- Complete native build and tests passed: 882 Alcotest cases and 87 custom checks.
  Initial transport tests could not bind loopback ports inside the shell sandbox;
  the full suite passed after the local-port run received approval.
- Two actual Simulator XCTest scenarios passed (19.433 seconds, zero failures):
  error/retry/Diagnostics and switching to a supported schema snapshot. Their
  acceptance uses synthetic authentication/transport with production DB/Core/Runner
  and Application. It does not exercise cloud sync or prove iPhone recovery.
- The probe is an experimental host-restamped ARM64 object with
  cross_abi_validated=false; it is not full iOS cross-compilation acceptance.
