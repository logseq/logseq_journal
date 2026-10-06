# E2EE password input UI

## Problem

The existing encrypted graph password flow repeats instructions, lacks a stable submission state, and drops relevant native field options in the adapter. Mobile users need clear context and reliable Return/retry behavior.

## Decision

Capture the actual baseline on an isolated Simulator, then improve the native password layout and submission admission in Application. Use disposable synthetic worker states at the public mounted Application boundary. Reuse existing build caches, preserve password bytes, protocol, keychain and account policies.

## Alternatives considered

### Shared runtime changes

Avoid modifying LUI or protected Dune/spec files. Use existing native Journal layout capabilities and SwiftUI controls.

## Acceptance criteria

- Actual same-device baseline and after screenshots without personal data or password contents.
- Empty and whitespace submissions rejected; password bytes preserved; repeated pending submission rejected.
- Error/retry and cancel/reopen are user reachable; keyboard and large text remain readable.
- Local commit only, and final comparison saved to Library when supported.

## Risks

- Synthetic Application UI states do not prove successful remote encrypted graph unlock.
- Runtime field reveal support may be unsuitable; do not add credential retention.

## Questions

- None. The delegated user request authorizes this scope and isolated Simulator operations.

## Implementation outcome

Implemented native SwiftUI password sections with one explanation, explicit primary/secondary actions, error and pending feedback, accessible labels, Go submission, and native large-text scrolling. Application rejects blank and duplicate pending submissions, clears the submitted draft, and preserves all original password bytes. Existing encryption, credential stores, security policy, protected Dune/spec and LUI source remain unchanged. No reveal toggle is added because the existing secure-field adapter does not provide a stable reveal capability.

## Validation

The public mounted Application test failed on baseline pending-state admission and passed after the change. The full Application suite passed 59/59 before final presentation refinements; the E2EE case passed again after all final changes. Existing wrapped-key crypto coverage passed. A separate generated, memory-only RSA/PBKDF2/AES-GCM fixture exercised production private-key password unlock, graph-key unwrap and wrong-password rejection.

Actual iPhone 13 / iOS 26.1 Simulator screenshots use the production Application entry with an isolated synthetic service, identical light theme/default text/empty field/software-keyboard conditions. CUA verified Return, loading/duplicate protection, retry, cancel/reopen and accessibility3 native scrolling. Final Change graph text is readable at accessibility3. Gitignored evidence is in docs/test-reports/e2ee-password-ui/. The final comparison was saved to Library as libfile_d9bf40e90568819185d8e6ca96b897cf using the current official upload/xattr helper.

## Consequences

No live account, remote encrypted graph, production Keychain, physical iPhone or VoiceOver speech was tested. Diagnostics opens, but Simulator CUA drag returned noWindowsAvailable, so swipe dismissal remains unverified. The synthetic 30-second pending delay is screenshot control, not performance evidence. Repository-wide formatting and decision checks report preexisting failures outside this task; the new decision and task diff validate.
