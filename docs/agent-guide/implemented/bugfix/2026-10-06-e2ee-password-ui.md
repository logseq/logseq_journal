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
- Scoped implementation and actual comparison saved to Library; publication follows explicit user authorization.

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

## Button sizing follow-up

After viewing the delivered comparison, the user requested adjusting Unlock graph button size. The prior regular native button was visually shallow with a leading label. Use the existing LUI primary button's large native control size, centered label and 44-point minimum touch target; keep its field-aligned width and intrinsic Dynamic Type height. No password or submission behavior changes.

The public Application E2EE case passed again (0.135s). The same iPhone 13 Simulator verified default text/software keyboard, touch submission, disabled loading, accessibility3, and native scrolling with the keyboard visible. The adjusted default control is about 50 points high; its large-text label remains complete without a fixed height. Actual screenshots updated the After panel while retaining the original baseline. The same Library file was replaced successfully as version 1, preserving libfile_d9bf40e90568819185d8e6ca96b897cf.

## Final pre-PR verification

The user accepted Library version 1 After and explicitly requested a PR after testing on 2026-10-06. Current origin/main remains b2261b1. All 29 Swift hashes in the accepted Simulator build match current sources; Application matches its built source. The existing cached native build (`dune build @all app/native_embed.exe.o`) and full `dune runtest --force` both completed successfully on the final button-adjusted source, including 59 Application cases. The native linker retained its preexisting sqlite3 text-stub warning. No additional UI rebuild, graph/account access or credential operation was needed. Push only the task branch, open one Draft PR and follow CI for its exact head; do not merge.
