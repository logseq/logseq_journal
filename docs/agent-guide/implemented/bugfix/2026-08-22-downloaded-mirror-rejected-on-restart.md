# Downloaded Mirror Rejected on Restart

## Problem

A newly downloaded synced mirror opened successfully, persisted catalog status
ready, passed PRAGMA integrity_check, and contained active sync metadata. After
terminating the App and launching it again, the same mirror failed immediately with:

    The graph storage is corrupt or incomplete.

The previous process had exited, but its db-worker.lock sentinel remained. The
sentinel named dead PID 60756. The new process successfully acquired the SQLite
owner primitive, proving no live writer held the graph, but
Ownership.acquire.inspect_existing returns Ambiguous_stale_lock for every
non-native target with a dead-PID sentinel. Engine.ownership_error maps that state
to the generic corrupt-storage message.

Moving only the stale sentinel to a recoverable temporary backup and pressing the
App's Retry action allowed the new process to create its own lock and open the
unchanged mirror. No SQLite repair or snapshot redownload was required. This proves
the graph was not corrupt.

The policy also makes every crash or forced macOS termination permanently block a
synced mirror until external file intervention. A graceful close path alone cannot
make crash recovery reliable.

## Decision

Reclaim a valid dead-PID synced-target sentinel after exclusive ownership has been
proven by the SQLite owner primitive. Validate the sentinel repository identity and
protocol before unlinking it, and fail closed for a live PID, malformed sentinel,
owner database conflict, changed graph directory identity, or unlink failure.

Also make normal App termination close the native runtime and release ownership so
clean exits do not leave stale sentinels. Crash recovery must remain independently
supported.

Do not report a stale ownership sentinel as storage corruption. If recovery cannot
be proven safe, surface the concrete ownership/recovery error and offer the
existing explicit local-cache reset action. Reset deletes or rebuilds the local
mirror and downloads a fresh snapshot; it must not be presented as ownership
recovery or silently discard local state.

### Implementation outcome

`Ownership.acquire` now reclaims a structurally valid synced/native sentinel only
after the recorded PID is dead and the graph directory device/inode identity has
been revalidated while the SQLite ownership primitive is held. Snapshot targets,
malformed sentinels, live PIDs, identity changes, and unlink failures still fail
closed. Ambiguous recovery has its own `ownershipRecovery` error and explicitly
directs the user to reset only the local mirror.

Unit tests cover repeated dead-PID recovery, malformed/live sentinels, and the
snapshot-target boundary. macOS testing also confirmed that a `SIGKILL` leaves the
sentinel, the next launch replaces it with a new owner, and the database and
pending-intent checksums remain unchanged. Cooperative `Cmd-Q` now closes graph
ownership before termination and removes the sentinel.

## Alternatives considered

### Keep stale synced locks permanently ambiguous

Rejected because the SQLite owner primitive already establishes exclusive process
ownership, while permanent refusal makes normal crash recovery impossible.

### Delete every stale sentinel without owner-database validation

Rejected because PID reuse, network filesystems, or a changed graph directory could
allow two writers.

### Depend only on graceful shutdown

Rejected because process crashes, power loss, debugger termination, and OS kills do
not execute cleanup callbacks.

### Add a separate ownership-recovery action for unverifiable sentinels

Rejected because a user action cannot establish that another writer is absent.
When ownership cannot be proven automatically, the App must fail closed, report
the concrete error, and offer only the existing explicit local-cache reset path.

## Acceptance criteria

- A clean macOS quit removes the current synced graph sentinel.
- A process crash followed by restart reclaims a valid dead-PID sentinel only after
  exclusive SQLite owner acquisition and opens the integrity-valid mirror.
- A live owner remains rejected as graphLocked.
- Malformed, mismatched, or otherwise unverifiable sentinels remain rejected with a
  specific ownership/recovery error rather than corruptStorage, and the UI offers
  the existing explicit local-cache reset action.
- Local-cache reset clearly states that it deletes or rebuilds the local mirror and
  downloads a fresh snapshot before requiring confirmation.
- Repeated launch/quit and forced-termination cycles preserve mirror contents,
  pending intents, sync cursor, and checksum.

## Consequences

- Valid dead-PID native and synced ownership records are recoverable without
  deleting mirror contents.
- Snapshot ownership and every ambiguous identity remain fail-closed.
- Normal termination cooperatively closes the graph; forced termination relies on
  the same validated stale-owner recovery during the next launch.

## Risks

- PID liveness alone is vulnerable to PID reuse; reclamation must be coupled to the
  SQLite owner primitive and graph identity checks.
- Cleanup ordering must not unlink a successor process's sentinel.
- Local-cache reset can discard pending local intents, so the error and confirmation
  UI must describe that consequence precisely.

## Questions

- None. An unverifiable stale synced sentinel reports the concrete error and offers
  the existing explicit local-cache reset action.
