# Same Process Duplicate Graph Open

## Problem

The macOS app can attempt to open the same managed graph twice during one startup.
The first open acquires the graph ownership primitive and then fails while opening or
projecting durable pending intents. Those late `build_engine` errors bypass partial
open cleanup, so no engine is returned but the ownership database transaction and
sentinel remain live.

The manager then performs a valid recovery open in the same process. That open fails
with `graphLocked`, and the application displays `The graph is owned by another
writer.` even though the only owner is the abandoned partial open. The failure
reproduces after a clean app restart; tracing confirms one runtime performs both open
attempts.

## Decision

Route every error after `Ownership.acquire` and SQLite connection creation through
the existing partial-open cleanup. In particular, failures to open, recover, or
project durable pending intents must close the storage connection and release graph
ownership before `Engine.open_` returns an error.

Keep `Ownership.acquire` strict. A second engine open, including one in the same
process, remains an error so independent writers cannot accidentally share a mutable
SQLite graph.

## Alternatives considered

### Permit reentrant ownership in one process

Rejected because process identity is not engine identity. Two engines in one process
would have independent in-memory projections, mutation caches, and close lifecycles
over the same mutable database.

### Treat `graphLocked` as startup success

Rejected because the failing open has no safe way to recover the existing engine,
and masking the error would also hide real contention.

### Deduplicate graph-open manager actions

Rejected because the second action is a valid recovery attempt and is not the source
of the leaked owner. Suppressing it would leave the graph unavailable while hiding
the partial-open cleanup defect.

## Acceptance criteria

- A synced graph that fails while opening durable pending intents returns
  `corruptStorage` and leaves no ownership sentinel.
- An immediate second open after that failure returns the same underlying error, not
  `graphLocked`.
- The macOS app no longer shows `The graph is owned by another writer.` for the
  reproduced obsolete-pending failure and holds no graph database or ownership
  descriptor after the failed open.
- A second independent engine or process still receives `graphLocked` while the first
  engine owns the graph.

## Consequences

- Partial cleanup must run exactly once and only on failed construction; a successfully
  returned engine retains ownership until `Engine.close`.
- Obsolete pending data remains unsupported and produces `corruptStorage`. This
  decision adds no migration or compatibility path; local-cache recovery is a
  separate concern.

## Questions

- None. The user requested the fix, and runtime tracing identifies the exact leaked
  partial-open boundary without requiring a product choice.
