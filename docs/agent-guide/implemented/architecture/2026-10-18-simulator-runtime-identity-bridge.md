# Simulator Runtime Identity Bridge

## Problem

The initial PR95 preflight blocked all real captures without an external runtime
identity observer. Build provenance and synthetic capture tests cannot replace a
fresh Worker graph observation bound to the foreground native process.

## Decision

Add a Simulator-only, explicitly enabled same-user Unix socket observer. It returns
only a fresh nonce-bound identity, with no graph body, credentials, database or
catalog reads. Use Darwin peer credentials and proc_pidpath to authenticate the
running executable against the fresh installed container before trusting a reply.
No TCP listener, entitlement or system-permission change is part of this design.

Journal_startup.Acceptance owns pure readiness/transition identity checks using the
existing Presentation and Worker graph types. Application joins a fresh correlated
Get_graph_state response to its current selected/ready presentation. A read-only
Journal_bridge callback and C trampoline deliver this on the native main thread.
Swift Runtime samples only after backend apply and mounted-root/foreground checks,
with a native display-turn barrier and unchanged transition stamp. A temporary
socket answers bounded requests only when JOURNAL_ACCEPTANCE=1 in a Simulator build.
The tool validates OS peer PID/uid, executable path/hash, then nonce/schema/identity;
its existing before/after capture checks remain mandatory.

Files: app/journal_startup.ml/.mli, app/application.ml, app/journal_bridge.ml/.mli,
app/journal_lui_bridge.c, swift/JournalRuntime.swift, swift/JournalRuntimeHost.swift,
new swift/JournalAcceptanceIdentity.swift, tool/capture_acceptance.py, formal tests,
acceptance guides and CI. No spec/*.mli, Dune or external repository changes.

## Alternatives considered

### Caller-provided actual identity or response JSON

Rejected: neither proves the running foreground App. Persisted catalog, database
reads and user-created actual constants are not observations.

### HTTP listener or new entitlements

Rejected: unnecessary exposure/permission scope. If the App cannot use the local
socket under its existing Simulator environment, stop and report that boundary.

## Acceptance criteria

- Write failing pure-owner, native transport and CLI tests before implementation.
- Authenticate same-user process/executable and fresh nonce; reject absent bridge,
  stale response, wrong process, unmounted/background/loading and transitions.
- Production device and default builds do not enable the endpoint.
- Coordinate synthetic Simulator window before any build install/runtime test;
  never operate original graph, iPhone47 or another owner's device concurrently.
- Independent review and exact-head CI; clearly retain real-runtime blocker until
  a supported synthetic App success path has actually been verified.

## Consequences

- Simulator App sandbox access to a short private /tmp socket is still unverified.
- Display synchronization must not accept an old mounted graph after a transition.
- Host IPC tests need supported execution-sandbox approval; no settings are changed.

## Verification so far

- Default sandbox: `python3 /external/task/ipc_probe.py` fails at AF_UNIX bind
  with PermissionError/EPERM; no reviewer had rejected an escalation. A normal
  supported require_escalated retry passed peer PID/image/uid/nonce verification.
  No network port, system configuration or entitlement changed.
- Pure startup identity tests failed on a blocked stub, then passed. An additional
  graph-error-state/epoch regression failed before its fix.
- Native producer compilation and Swift/C/OCaml callback tests pass using the
  coordinated prepared switch and immutable resolution records with jobs=1.
- 31 capture fixtures and 9 real Swift Unix-process tests pass. Independent review
  found and verified fixes for a slow-client/close stall and DispatchSource fd
  cancellation ordering. No App install/launch, graph change or screenshot was
  performed; only approved read-only Simulator/container metadata was inspected.
- Full iOS Simulator App compilation, linking, target checking, icon packaging
  and signing verification pass with status built, including a clean committed
  source build. These artifacts have not been installed or accepted as runtime
  screenshot evidence.
- The existing link-only stub symbol test caught a missing identity callback;
  the stub now returns unavailable and the original failing test passes.
- A regression reproduced acceptance of staged Swift/plist/entitlements with an
  otherwise matching committed source map. Those separate builder inputs must now
  match the checkout byte for byte; all three mismatches fail closed.
- The owner released the synthetic Simulator window. Approved read-only inventory
  and fresh installed-container checks succeeded in this execution environment.
  Its old visible component fixture is not a mounted Journal Worker graph, and
  externally generated graph IDs have never been installed there. The owner
  confirmed no independent expected ordinary-App synthetic graph UUID exists.
  Adding or switching graphs is outside this task's scope, so actual App socket,
  displayed-frame and successful capture integration remain blocked. No device
  permission rejection or missing implementation is claimed as this blocker.

## Questions

- Resolved: parent explicitly authorized ordinary bridge implementation and local
  Unix IPC validation on 2026-10-18, including the normal approval flow.
- Resolved: the original host bind was refused by the default execution sandbox,
  not an approval reviewer. A supported escalated synthetic probe succeeded in
  peer PID, executable lookup, uid and nonce checks; no policy bypass occurred.
- Resolved: the synthetic-device window is released. A coordinated ordinary-App
  synthetic graph with an independent expected UUID is still needed for the real
  integration gate; the original graph and iPhone47 must remain untouched.
