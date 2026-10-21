# 2026 10 21 Existing Mirror Unlock Completion

## Problem

After sign-out retains an encrypted local mirror but deletes its unlock credentials,
sign-in can require an E2EE password to reopen that mirror. Application keeps the
submission pending until startup is Ready, but Ready requires Timeline's first
appearance acknowledgement. The pending password screen prevents that appearance.
The sync reducer has already attached the graph successfully.

## Decision

End the current password submission when the current manager scope reports a
successful attachment with local access available and first presentation pending.
Keep the Timeline acknowledgement and the existing error/cancellation handling.
Do not treat Local_available alone or command queue admission as unlock success.

The public sync reducer plus startup presentation reproduces the circular
dependency, but cannot execute Application's private pending-state transition.
Application has no public pure E2EE reducer event/state boundary. Exercise its
existing mounted hooks in application_view_test, the narrowest public boundary
owning the defect; do not add duplicate transport or persistence regressions.

## Alternatives considered

### Wait for Ready or clear on Local_available alone

Ready preserves the cycle. Local_available alone can already be advertised while
the password request is in progress. Removing first-presentation acknowledgement
would change startup and rendering ownership unnecessarily.

## Acceptance criteria

- A regression fails before the fix and passes after it when an existing mirror
  attaches successfully while the first presentation acknowledgement is pending.
- Manager/graph notification order does not prevent the password screen exiting.
- Local availability without attachment, wrong password, failure, and replaced
  scopes cannot be mistaken for successful attachment of the current graph.
- Timeline still sends its scoped first-appearance acknowledgement.
- Test the same sign-out/sign-in/unlock path on the existing isolated Simulator
  bundle without deleting graph/account data; user enters all real credentials.

## Consequences

- The new terminal condition must be scoped to the currently selected graph and
  successful attachment; stale completions remain fenced by the sync reducer.
- Host-restamped Simulator builds retain experimental ABI status and do not
  establish iPhoneOS ABI equivalence.
- Both mounted App regressions failed on the original pending-state logic and
  pass with the attachment completion condition. The full Application suite
  passes (144 cases), including existing wrong-password and admission failures;
  the pure sync core suite passes (87 cases), including late E2EE completion
  fencing and scoped first appearance acknowledgement. Independent source
  review found no issue. Real Simulator acceptance is performed separately
  with the user's own credential entry; these synthetic tests do not prove it.

## Questions

None. The user approved the minimal fix and Simulator test. No new PR, merge,
or release is authorized by this decision.
