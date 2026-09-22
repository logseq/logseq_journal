# Native authentication probe

`python3 tool/build_authentication_probe.py` builds a disposable arm64 iPhone
Simulator application and prints its path and source hashes. Install that app
on an iOS 26 or later Simulator. It uses the production
`JournalAuthenticationView` and `JournalAuthentication` with a local API that
never accesses an account or the network. The sheet uses the production form
sizing, large detent, navigation container and Close placement.

Launch `org.logseq.journal.authentication-probe` with `--scenario code`,
`--scenario email`, `--scenario new-password` or `--scenario methods`.
Optional `--large-text`, `--dark` and `--rtl` arguments select presentation
conditions in the probe only. Relaunch between scenarios to reset its state.

Use only dummy values, for example username `probe` and password `sample`.
Any nonempty credentials advance to the selected challenge. In the code
scenario, `123456` completes; other responses produce a retryable local error.
Other scenarios complete with any nonempty response or a selected method.
Forgot password exercises the existing reset-code and new-password fields.

Inspect these native behaviors through the Simulator UI:

- Username starts focused; Next moves to the secure password field and Go
  submits. Busy state disables duplicate submission.
- The code challenge focuses its code field, retains an incorrect code for
  correction, displays the failure, and accepts a corrected code.
- Email setup offers an email keyboard; new-password challenges conceal text
  and carry new-password content semantics. Custom responses remain ordinary
  text. Method selection uses the native Picker.
- Close and swipe dismissal return to Authentication closed. Completion returns
  to Authentication completed. Neither sends any real authentication request.
- With the keyboard visible, large text, dark appearance and RTL, inspect
  readable messages and reachable fields, submission and dismissal. Repeat in
  portrait and landscape. Record actual observed results and screenshots.

This probe is visual acceptance infrastructure, not a duplicate authentication
state regression suite. `tool/test_swiftui_authentication.py` exercises the
presentation owner's commands, retry, cancellation and stale completions. The
probe does not validate Amplify service behavior, full-app graph lifecycle,
physical-device performance or automatic delivery of real verification codes.

## Reset focus regression

`reset-focus.cua.js` runs in the CUA JavaScript session, using only the documented
native application API. Build and launch the probe with `--scenario methods`.
Enter dummy credentials, submit, choose Back to sign in, then Forgot password?.
Run the script while the retained username is populated on Reset your password.
It requires the keyboard Go action to open code entry, Next to focus the secure
new-password field, and Go to return to sign in. It enters only local test data.

The production owner of this defect is JournalAuthenticationView's FocusState
and view lifecycle. The public JournalAuthentication actions and completions
already pass the reset command sequence, but have no native responder or return
key state; they cannot reproduce a stale keyboard targeting a retired view.
The regression therefore runs at the actual native view boundary. It does not
duplicate command, persistence or transport tests, bypass an interface, or
inject an incorrect provider result. The same CUA check failed before the focus
change (Next remained visible on the reset request) and passed afterward.


## Native XCTest accessibility acceptance

The standardization report's `batch16-authentication-acceptance.swift` and
`batch16-authentication-project.rb` are a replayable, disposable Xcode UI runner.
Copy them into a temporary directory as `DeviceAcceptance.swift` and `create.rb`,
run the Ruby generator with the xcodeproj gem, then run its DeviceAcceptance
scheme against the booted iPhone 13 Simulator after building/installing the probe.
No application target, production project or Dune change is required.

The runner audits contrast, hit regions, descriptions and clipping on the real
view, exercises a local incorrect-code response, a full sheet-dismissal drag,
and large dark RTL scrolling and Close across rotation. Only disabled-control
contrast findings are exempt; enabled-content findings are retained. Native
color/lifecycle rendering is outside the pure authentication command owner's
state/effect boundary, so these checks do not duplicate that regression suite.
The light contrast regression fails before the semantic-color fix and passes
after it. Landscape contrast findings remain inconclusive: some exported crops
do not contain the target text, and sampled Close/Back colors contradict their
reported failure. Preserve the report's evidence and do not label the complete
matrix passing merely because the focused light regression passes.
