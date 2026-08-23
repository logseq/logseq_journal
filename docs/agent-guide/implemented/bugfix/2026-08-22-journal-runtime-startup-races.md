# Journal Runtime Startup Races

## Problem

The production host starts account restoration while its generated Flutter root is
still preparing the application payload. `JournalAccountGate` independently starts a
second restoration during mount, so concurrent results can overwrite a user's graph
selection and leave the bootstrap waiting for a state transition that already
happened.

After the payload eventually completes, `JournalRestartableRuntimeHost` retains the
first `initialRuntime` widget it saw. Because that widget is the generated host's
loading indicator, the prepared `BonsaiFlutterRoot` never replaces it. The snapshot
can download successfully while the application displays a permanent spinner and
never creates the local SQLite mirror.

## Decision

Make the runtime bootstrap the sole owner of initial account restoration. The account
gate renders shell state and exposes explicit retry actions, but performs no restore
side effect during widget mount or replacement.

While no managed graph restart has begun, update `JournalRestartableRuntimeHost` from
new `initialRuntime` values received from its parent. Once a restart begins, keep
replacement ownership inside the restartable host so unrelated parent rebuilds cannot
reintroduce a stale runtime.

## Alternatives considered

### Serialize duplicate restoration calls

Rejected because the gate has no ownership reason to restore authentication. Adding a
mutex would retain two competing lifecycle owners and would not fix the stale initial
runtime widget.

### Recreate the restartable host with a key

Rejected because destroying the host would also destroy its graph restart
subscription and managed replacement state. Updating the initial runtime only before
the first managed restart expresses the actual ownership transition.

## Acceptance criteria

- Mounting or replacing `JournalAccountGate` does not call `restore()`.
- A parent update from a loading widget to a prepared runtime replaces the displayed
  initial runtime.
- Managed graph restarts still unmount a stale runtime until the replacement is ready.
- A real encrypted graph snapshot downloads, boots the native runtime, and creates an
  integrity-valid SQLite mirror on macOS.

## Consequences

- Standalone account-gate callers must restore shell state before mounting the gate;
  the production adapter already owns this lifecycle.
- Incorrectly resetting initial-runtime ownership during a managed restart could
  reveal a stale graph, so tests must cover both startup and replacement paths.

## Questions

- None.
