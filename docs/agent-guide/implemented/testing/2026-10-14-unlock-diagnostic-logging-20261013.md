# Unlock Diagnostic Logging 20261013

## Problem

The user-led full-product Simulator reaches an E2EE busy page while startup diagnostics report Failed. Public synthetic events prove that password submission can be ignored without a prepared challenge, but the preceding live request/error is hidden.

## Proposal

Add opt-in, bounded stderr observations at the UI send/pending boundary, database worker dispatch, sync runner requests and native crypto stages. Use numeric operation/ticket/request IDs, fixed stage/category names, challenge readiness, pending transitions, duration and numeric Keychain OSStatus. Never emit identity, graph IDs, credentials, key material, plaintext or arbitrary error/network bodies. Preserve all business transitions and recovery behavior.

## Decision

The user's instruction to first add logs and confirm the reproduced case authorizes only sanitized observability and an in-place update of the dedicated Simulator. No E2EE behavior repair, phone update, PR publication, network repair, sign-out or data cleanup is included. The user handles credential entry.

## Alternatives considered

### Fix the synthetic mismatch first

Deferred because it would change the live failure before identifying its exact preceding stage.

### Print arbitrary exceptions or request bodies

Rejected because these may contain credentials, identity or graph data.

## Acceptance criteria

- Existing public worker/runner and native crypto boundaries emit finite stage/admission/outcome observations when opted in and none by default.
- Tests first fail for missing observations, then pass, including arbitrary sensitive marker exclusion and bounded output.
- A full product build on the dedicated Simulator preserves its existing login and graph storage. Preserve prior scene/evidence before updating.
- Report the actual logged live branch, or the exact missing human input/environment prerequisite. Do not claim synthetic evidence establishes the live root cause.

## Risks

- Logging is opt-in and capped per process; a cap can omit later observations and emits a single limit notice.
- The existing Simulator build uses verified host ARM64 OCaml/runtime inputs restamped for Simulator with genuine Simulator platform C, which is not a full iOS runtime ABI proof.
- Core business interfaces under spec and all Dune files remain unchanged. If required changes cannot fit that boundary, stop and report the precise proposed interface change.

## Questions

None. Logging scope and Simulator update are authorized in the session. Credential input remains with the user.

## Validation so far

Four existing public owner boundaries first failed because observations were missing. Native crypto then passed default-off, numeric ID correlation, actual KDF/AES stage, typed missing-key result, arbitrary secret-marker exclusion and 256-line cap checks. Actual Worker service tests and the 17-test runner suite pass. All 79 mounted Application tests pass. Full production OCaml was rebuilt in the task-owned external build directory. The prior busy screenshot was preserved. The user has now completed the logged Retry/password attempt, and read-only CUA diagnostics verified the resulting busy/Failed mismatch.

## Consequences

The complete cb0b76e product was installed in-place as Simulator1.5877.24 and launched with logging enabled. The previous busy screenshot was preserved. The actual startup logs correlate Core/Runner/native operation2: wrapped-key-copy OSStatus-25300 (Apple errSecItemNotFound), wrapped-key-unavailable, and Core During_local_restore with no advertised password challenge. Catalog operation3 succeeds. The actual page shows Unable to open graph / wrappedGraphKeyUnavailable / Retry. This does not establish that the prior busy UI had the identical preceding failure.

The user unlocked the Mac and personally performed Retry/password submission once. Actual runner operation5 Fetch_e2ee_graph_key fails after2066ms with effect-failed, and Core publishes During_e2ee with challenge_advertised=false. UI then sets pending=true and queues request5; the real Core logs decision=ignored/challenge_ready=false/op=none. No Unlock_private_key request or native private-key derivation begins. Read-only CUA confirms persistent Unlocking plus Sync Failed, Startup Failed and Graph Closed. This is a real full-product reproduction of the no-challenge password submission case, rather than an inference from a synthetic sequence. The underlying fetch cause remains unclassified: the current sanitized effect-failed category does not distinguish token, transport or response decoding. No password correctness conclusion is made. Recording remains active; no more human input is required to identify this branch. No credentials were read or entered, no data was deleted or signed out, and no graph was switched. simctl relocated the data container UUID during its in-place install; nine files remain and the persisted account/graph were restored automatically. No claim of a complete data backup is made. Phone and PR72 remain unchanged. Each component caps its process output at256lines plus one limit notice.

UI request IDs span queue admission/delivery. Core effect IDs span runner/native execution. Correlating a UI submission with the next Core password event relies on serial submission chronology; the protected Core event ABI is unchanged.

The live proof and screenshots are retained in the task external evidence directory: unlock-logging/live-sanitized.log, submitted-busy.png, submitted-diagnostics.png and diagnosis-summary.json. This evidence supports repairing challenge-specific recovery and semantic submission feedback in a separately authorized change. It does not justify deleting a graph or conclude that unavailable outbox diagnostics mean an empty outbox.
