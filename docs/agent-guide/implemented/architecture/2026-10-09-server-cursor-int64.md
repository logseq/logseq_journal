# Server Cursor Int64

## Problem

Authoritative server transaction progress is represented by unrelated integers and
versioned strings. The string comparison rejects normally ordered pull batches
across decimal digit boundaries, and repeated conversions do not enforce numeric
range or non-negativity consistently. The server JSON number representation also
requires an explicit JavaScript safe-integer bound.

## Decision

Own one abstract, non-negative int64 cursor in logseq_db_types.Server_cursor,
the existing common dependency of storage and overlay. Expose the identical
abstract type through logseq_overlay_db.Server_cursor and Types.Server_cursor.
The overlay spec signature keeps the zero/of_int64/to_int64/equal/compare API,
with type identity tied to the common abstract type, never to public int64.

Migrate authoritative progress in protocol, reducer, worker, snapshot/checkpoint,
overlay and persistence to this type. Convert to/from int64 only in I/O codecs
and checked interval arithmetic. JSON numbers must be in [0, 9007199254740991].
Preserve existing numeric versioned cursor tokens only inside legacy persistence
codecs. Do not migrate local changefeed cursors, Datascript transaction entity IDs,
submission counts/ordinals, graph or lifecycle generations.

The only currently identified necessary Dune change is in
logseq_overlay_db/spec/dune:

    (modules server_cursor types database)
    (virtual_modules server_cursor types database)

Both shared types and the overlay implementation discover the new implementation
modules through their existing standard module selection. No new package or
storage-to-overlay dependency is needed. Further necessary Dune changes require
separate explicit permission.


Adopt the existing common db_types dependency as the owner of the abstract
non-negative int64 cursor and expose the identical type through overlay.
The user authorized the migration and exactly the two spec Dune module-list
changes above. Other Dune files remain unchanged.

## Alternatives considered

### Define the type only in overlay

Storage already sits below the overlay implementation, so using an overlay-owned
cursor in the storage checkpoint API introduces a package implementation cycle.

### Keep storage and protocol as raw int64

This permits unconstrained values outside I/O and fails the requested shared
progress identity. Only codec boundaries should expose raw numeric values.

### Retain VERSIONED_TOKEN and change its comparator

This keeps unrelated token factories and malformed numeric states constructible,
and does not unify protocol/checkpoint progress or protect numeric ranges.

## Acceptance criteria

- Normal public reducer pull batches crossing 9 to 10 and 99 to 100 are admitted;
  duplicates and reverse order are rejected.
- Cursor construction rejects negatives; I/O rejects overflow and values beyond
  the server's JSON safe-integer range without silent narrowing.
- SQLite checkpoints and existing outbox/receipt tokens recover the same progress.
- Direct production consumers share the same abstract type, with no public raw
  integer/string constructors bypassing of_int64 validation.
- Relevant tests, all direct consumer builds, independent diff review and exact
  PR head CI complete; no merge or deployment is performed.

## Risks

- Legacy persistence syntax remains a compatibility boundary rather than a public
  domain constructor; malformed legacy numeric values will be rejected explicitly.
- Non-negative int64 is a broader domain than the JavaScript wire can represent;
  wire codecs must impose the additional upper bound.
- Existing arithmetic that adds ordinals must reject int64 overflow rather than
  wrap; full domain values must not pass through OCaml int conversions.
- This change does not address the independent WebSocket reconnect finding.

## Consequences

Authoritative progress now has one abstract identity across storage, overlay,
protocol, reducer and worker; negative values cannot enter domain state.
Legacy numeric token bytes remain unchanged at the persistence boundary, and
wire encoders/decoders impose the server's JavaScript safe-integer ceiling.
Checked interval arithmetic rejects an overflowing submission before freezing or
persisting it, including an independent suffix after a definitive rejection.
The native UI consumers build without changing their cursor display semantics.

The HTTP snapshot baseline retains its existing 64 MiB response budget, shared
between its transport request and decoder. WebSocket response decoding retains
its independent 262,144-byte budget. A public Core.step bootstrap regression uses
ordinary cursor values and a valid larger HTTP pull response; decimal-boundary
bug regressions remain exclusively at that public reducer boundary.

The migration does not run live account or Simulator acceptance. Repository-wide
decision validation still reports three pre-existing unrelated document errors;
this decision is independently validated.

## Questions

- May logseq_overlay_db/spec/dune add server_cursor to its modules and
  virtual_modules lists as shown above? AGENTS.md prohibits Dune edits unless
  explicitly requested. The user explicitly approved exactly these two lines on
  2026-10-09; no other Dune modification is authorized.
