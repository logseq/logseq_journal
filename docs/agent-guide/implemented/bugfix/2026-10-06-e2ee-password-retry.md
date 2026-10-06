# E2EE password retry recovery

## Problem

Codex review P1 https://github.com/logseq/logseq_journal/pull/49#discussion_r4191174193 identifies a real mismatch: failed private-key unlock clears the encrypted challenge and leaves password admission disabled in the production pure reducer. Application displays a retry editor but the subsequent password event is ignored, leaving the new pending UI stuck. The existing synthetic Application fixture cannot prove production crypto recovery.

## Decision

Reproduce through public Core events and runner completions, then restore retry admission for a failed private-key unlock using the already fetched encrypted challenge. Preserve account/graph fencing, password bytes, protocol and credential-store policy. Retain the approved After layout. Regression coverage belongs exclusively to the public pure reducer for this defect; do not duplicate it in effect runner or UI. The related P2 queue-admission finding is separately tracked, outside this P1 correction.

## Alternatives considered

### Restart from Application

A queued recovery/password sequence races asynchronous key fetching and moves reducer-owned recovery into the UI. Preserve the production owner's explicit awaiting-password transition instead.

## Acceptance criteria

- Public events reproduce wrong-password failure followed by ignored corrected input on the current head, before implementation.
- Corrected input emits one Unlock_private_key request with exact bytes and existing encrypted package, then resumes graph-key unlock and snapshot bootstrap on successful completions.
- Repeated failures remain retryable; duplicate submission and stale completion remain inert. Graph picker/account changes discard the old challenge.
- Applicable tests/build pass and the same formal PR49 is updated and final exact-head CI followed.

## Risks

- Only encrypted challenge strings remain available after this failure; no password, unlocked key or new persistent credential is retained.
- Generic network/key-fetch failures keep existing recovery semantics. Real remote graph/Keychain acceptance remains untested.

## Questions

- None. User explicitly authorized resolving every Codex review P1 on PR49 and pushing the correction.

## Validation

The new public pure reducer test follows account/catalog/selection, cache miss, online recovery, encrypted key/package fetches, first password and an actual matching failed runner completion. Baseline fails because corrected input emits zero Unlock_private_key requests instead of one. After restoring the encrypted challenge and awaiting flag, all 42 pure core cases pass, including exact retry bytes, repeated failures, duplicate/stale completion admission, successful graph-key unwrap/bootstrap continuation and graph-picker/account fences. No duplicated defect regression is added to Application/effect runner/UI.

## Consequences

On private-key unlock failure, only the encrypted private-key package, encrypted graph-key material and already admitted scope survive for retry; no submitted password or unlocked key is retained. A retry clears prior error/failure, leaves awaiting state and emits one unlock request. Existing picker/account resets and successful graph-key completion discard the challenge. Generic key-fetch failures keep existing behavior. P2 discussion_r4191174188 concerns Application worker-lane admission, is a separate owner and remains unresolved in this P1-only correction.

## Final verification

Cached `dune build @all app/native_embed.exe.o` and `dune runtest --force` succeeded. The latter reports 21 Alcotest suites and 563 cases, including Application 59 and sync 151. The final new case follows duplicate/stale event next-state before accepting the subsequent failure completion, ensuring the pending request remains usable. UI/Swift source and the accepted Library version 1 After are unchanged. Gitignored RED, GREEN and full-test logs are in docs/test-reports/e2ee-password-ui/p1-*.log. The existing sqlite3 native-link warning and unrelated repository-wide decision validation defect remain.
