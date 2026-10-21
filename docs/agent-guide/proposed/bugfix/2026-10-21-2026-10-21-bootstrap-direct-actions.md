# Direct explicit bootstrap actions

## Problem

On main 6a3695c, selecting a graph marked Not downloaded enters an expected local-mirror failure page and requires a second Download graph tap. After canceling authentication and closing the sheet, Sign in again opens another explanation sheet that requires Continue before the system browser. Both were reproduced on the isolated 1446 Simulator, with before screenshots 10/11 and 03/01 outside the repository.

## Proposal

Treat an explicit graph selection as permission to request download only if the local mirror inspection confirms absence. Keep automatic recent-graph restore local-only, wait for native permission and verified identity before network effects, retain key/password validation, cancellation and bounded failures. Launch native reauthentication once when the user chooses Sign in again, while retaining the initial explanation, visible busy/cancel/error UI and account preparation.

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
