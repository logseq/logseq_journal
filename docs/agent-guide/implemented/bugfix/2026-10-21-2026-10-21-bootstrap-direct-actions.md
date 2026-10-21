# Direct explicit bootstrap actions

## Problem

On main 6a3695c, selecting a graph marked Not downloaded enters an expected local-mirror failure page and requires a second Download graph tap. After canceling authentication and closing the sheet, Sign in again opens another explanation sheet that requires Continue before the system browser. Both were reproduced on the isolated 1446 Simulator, with before screenshots 10/11 and 03/01 outside the repository.

## Decision

Track an explicit graph selection until local mirror inspection confirms absence, then request scoped native online permission before continuing download. Keep automatic recent-graph restore local-only, wait for native permission and verified identity before network effects, retain key/password validation, cancellation and bounded failures. Launch native reauthentication once when the user chooses Sign in again, while retaining the initial explanation, visible busy/cancel/error UI and account preparation.

The user explicitly authorized these two narrow fixes, before/after screenshots and a ready PR. Repeated Retry controls, title overlap and unrelated UX are excluded. No spec or Dune edit is planned.

## Alternatives considered

### Automatically retry every local failure

Would conflate missing data, corrupt storage and missing keys, and weaken explicit network admission. Only confirmed absent mirrors after user graph selection qualify.

### Permit networking for every graph selection

Would make cached graph switches network-dependent before Timeline. Preserve the existing local path for available mirrors.

## Acceptance criteria

- A selected missing mirror requests scoped online permission without the error/Download intermediate page; it performs no remote request before identity confirmation.
- Automatic restore, available local mirrors, missing local keys and arbitrary failures retain existing protections and do not auto-retry.
- Cancellation, stale completions and switching selections cannot continue the retired download.
- Sign in again starts authentication with one action and retains cancel, return, error retry and account preparation.
- Same-baseline synthetic Simulator evidence records before/after clicks; successful production login/download remains unverified without user action.
- Independent review and final-head CI/comments are checked before handoff; create a ready PR, do not merge or deploy.

## Risks

- Permission can race graph-generation changes; the pure owner must retain and consume only current explicit selection intent. Native automatic authentication must run only for an explicit retry presentation, once per presentation, without restarting after cancel or view recomputation. Experimental host-restamp retains cross_abi_validated=false.

## Questions

None. The user has authorized the concrete scope and the existing host-restamp test route.

## Consequences

The pure core retains a graph-scope selection intent only for explicit selection,
consumes it on current mirror absence, and waits for native permission and
verified identity before key recovery or snapshot effects. Automatic recent-graph
restore and missing-key handling keep their local-only behavior. Cancellation
clears the intent, stale scope completions cannot revive it, and real failures
remain bounded with explicit Retry. The picker labels the action Download and open.

An explicit Sign in again presentation starts authentication once. The initial
presentation still explains the secure sign-in flow; busy Cancel, Close, native
cancellation and visible errors remain. A failed attempt waits for manual retry.
No authentication, encryption, account-preparation or storage guard is bypassed.

Four regressions extend the existing public pure-core suite, with expected RED
failures before the change and 84 core cases passing afterward. The Swift owner
model suite passes. The native presentation defect cannot originate at the pure
OCaml boundary; its actual SwiftUI retry assertion failed on the baseline and
passed on the fixed synthetic host. Independent review found no definite issue.

Same-condition UI evidence on the existing isolated iOS 26.1 Simulator shows
both actions reduced from two clicks to one. Cancel/Close/retry, synthetic
network failures, existing local graphs, restart, background return, picker
cancel and missing-key protection passed. A six-page before/after report was
delivered separately through Library; all screenshots contain synthetic data.
Fresh native objects were produced for the modified source before building the
experimental Simulator host; cross_abi_validated remains false. Real server
login/download success, password unlock, network restoration and download
interruption recovery remain unverified. Repeated Retry controls and title
layout are outside this decision.
