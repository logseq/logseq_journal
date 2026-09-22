# Native Unlock Retry Dispatch

## Problem

The native unlock presentation acceptance checks initial/error controls and
cancellation, but does not submit editor events after a failure. Successful
manual iPhone unlock does not establish that a corrected password reaches the
manager or that submitted input is cleared. The offline macOS host deliberately
blocks authentication and cannot establish real password verification.

## Decision

Extend the existing application presentation acceptance through public native
editor events and the existing service fixture. Verify empty submission, input
admission in initial and failed states, exact command payload, cleared input
after submission, a fresh corrected submission and cancellation without submit.
Use synthetic strings only. No production behavior change is planned.

Application owns editor event routing and submission. Journal_capture owns pure
editor revision admission, while the sync reducer owns password verification
effects. Neither public reducer alone executes Application's editor-to-service
dispatch. This is bounded presentation acceptance, not a bug reproduction or a
claim that injecting a failure snapshot reproduces cryptographic rejection.
Do not duplicate pure editor/crypto/transport tests or change ownership.

## Alternatives considered

### Count the visual preview as password retry acceptance

Rejected: its standard SwiftUI field and synthetic error do not execute the
production OCaml editor/session/command path.

## Acceptance criteria

- Existing initial/error, known/unknown graph and cancellation cases still pass.
- Native editor events produce exactly one expected password command per submit.
- Empty input produces no command; submitted input is cleared and retry admits
  a fresh value without reusing the old editor session.
- Run the application dispatch suite and formatting check; record the bounded
  result without claiming native focus, secure AX privacy or real E2EE success.
- Do not edit Dune, protected spec files, SDK code, or phone state.

## Risks

- Service snapshots are fixture inputs. This test does not execute remote
  authentication, crypto, AppKit/UIKit responders or actual password autofill.

## Questions

- None. Continued macOS acceptance is authorized, and all input is disposable.

## Consequences

The existing application dispatch suite passes all four initial/error and
known/unknown graph cases with the new native input, submission, clearing,
correction and cancellation checks. The empty-input case sends native keyboard
submission because the disabled button correctly has no Press binding. The
initial harness mistake is retained in the batch 49 report and is not a
production regression. No production code, Dune, spec, SDK or phone changes
were needed. Real E2EE verification and native secure-field privacy remain
separate acceptance requirements.
