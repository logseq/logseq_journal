# Simulator Runtime Identity Bridge

## Problem

PR95 currently blocks all real captures because the running App has no external
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
- 30 capture fixtures and 9 real Swift Unix-process tests pass. Independent review
  found and verified fixes for a slow-client/close stall and DispatchSource fd
  cancellation ordering. No real Simulator or graph has been operated.
- Full iOS Simulator App compilation, linking, target checking, icon packaging
  and signing verification pass with status built. The compile-only artifact was
  made before committing and is not itself accepted source-clean runtime evidence.
- Real synthetic capture remains pending the active owner releasing the device.

## Questions

- Resolved: parent explicitly authorized ordinary bridge implementation and local
  Unix IPC validation on 2026-10-18, including the normal approval flow.
- Resolved: the original host bind was refused by the default execution sandbox,
  not an approval reviewer. A supported escalated synthetic probe succeeded in
  peer PID, executable lookup, uid and nonce checks; no policy bypass occurred.
- Resolved: active status owner retains the real Simulator window; request for a
  later synthetic-device window has been sent, and fixtures may proceed meanwhile.
