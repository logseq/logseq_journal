# Journal Title Format Parity

## Problem

New journal pages created by this App use a hard-coded `YYYY-MM-DD` title.
`app/journal_graph_runtime.ml` formats the local journal day in `journal_title`
and passes it to `V2_create_journal_page` when Capture finds a missing page.
`logseq_overlay_db/lib/database.ml` writes that title to `block/title` and its
ASCII lowercase form to `block/name`. For September 19, 2026, both currently
contain `2026-09-19`.

This differs from Logseq's default and ignores the active graph's configured
journal title format. The requested change is to follow Logseq's format
resolution logic when creating journal pages.

### Upstream evidence

The upstream reference is pinned to the local checkout at `~/repos/logseq`,
commit `4a02952d95bba0d07e8b8ff371d1889dbf584e31` (merge of upstream PR 13331,
2026-09-22). All file/line references below are at that revision.

- `src/main/frontend/state.cljs:567`: `default-date-formatter` is
  `MMM do, yyyy`; `set-date-formatter!` stores a formatter per repository and
  `get-date-formatter` returns it, falling back to the default.
- `src/main/frontend/db/async.cljs`, `<get-date-formatter`: reads
  `:logseq.property.journal/title-format` from the `:logseq.class/Journal`
  entity, with `MMM do, yyyy` as the default.
- `src/main/frontend/handler/repo.cljs`, `restore-and-setup-repo!`: loads that
  formatter into repository-specific frontend state.
- `src/main/frontend/worker/pipeline.cljs`, `journal-title`: derives journal
  titles from journal day and the Journal class format through a shared date
  utility at transaction time.
- `deps/common/src/logseq/common/util/date_time.cljs:10,41-57`:
  `default-journal-title-formatter` is `MMM do, yyyy`; `int->journal-title`
  parses the `yyyyMMdd` day and unparses with the configured pattern, returning
  nil only when the formatter argument is nil.
- `deps/db/src/logseq/db/frontend/class.cljs:32`: the seeded
  `logseq.class/Journal` entity carries
  `:logseq.property.journal/title-format "MMM do, yyyy"` — new upstream graphs
  store the default as a property, so absence is the degenerate case.
- `deps/db/src/logseq/db/common/entity_plus.cljc`: also derives journal titles
  on reads. Matching all upstream read/display behavior is a broader scope than
  correcting this App's newly persisted journal titles.

#### Formatter token semantics

Upstream formats with the forked cljs-time library
(`com.andrewmcveigh/cljs-time` pinned to `logseq/cljs-time`
`5704fbf48d3478eedcf24d458c8964b3c2fd59a9` in `deps/common/deps.edn`),
`src/cljs_time/internal/parse.cljs` (`read-pattern`) and
`src/cljs_time/internal/unparse.cljs` (`lookup`, `unparse`):

- A pattern is tokenized into runs of identical ASCII letters (tokens),
  `'...'` quoted literals (`''` escapes a quote), and every other character
  passed through as literal text.
- Numeric tokens zero-pad to a minimum width then keep the rightmost digits
  up to a maximum: `d`/`dd` day-of-month (1-2/2-2), `M`/`MM` month number,
  `y`/`yy`/`yyyy` year (1-4/2-2/4-4; `yy` yields the two-digit year of the
  century), `x`/`xx`/`xxxx` ISO week-year, `w`/`ww` week of week-year,
  `D`/`DD`/`DDD` are *also* day-of-month (upstream maps `D` to the day getter,
  not day-of-year), `e` day-of-week number 1-7 (Sunday=7), time tokens
  `h`/`H`/`m`/`s`/`S` and meridiem `a`/`A` (journal days parse to UTC midnight,
  so `h`→12, `a`→am).
- `MMM`/`MMMM` emit English month names (short names are the first three
  characters); `E`/`EEE`/`EEEE` emit English weekday names (`Sat`,
  `Saturday`).
- `o` emits the English ordinal suffix of the *previous* token's value:
  `st`/`nd`/`rd` for 1/2/3/21/22/23/31 and `th` otherwise — so 11th, 12th,
  13th take `th`. `o` not preceded by a real token throws.
- `Z`/`ZZ` emit the timezone offset string (`Z` for the UTC-parsed journal
  day).
- `tf/formatter` does not validate eagerly; an unsupported token (for example
  `u`, `Q`, `MMMMM`, five or more `d`s, or a stray `o`) throws inside
  `unparse` when the title is produced — upstream fails the creating
  transaction.

`block/name` is the lowercase form of the title; the overlay already derives
it with `String.lowercase_ascii` in `logical_page_at`, so `"Sep 19th, 2026"`
yields `"sep 19th, 2026"` without further work.

## Proposal

Resolve the effective format from the active graph's Journal class property,
and use `MMM do, yyyy` when the property is absent. Keep graph-specific values
isolated across graph switches and refresh them when the relevant graph data
changes. Distinguish an absent property from a failed or incomplete read.

### Format read boundary (chosen)

Extend the existing graph-scoped read boundary `V2_graph_info` /
`V2_graph_info_outcome` / `Types.graph_info` with a
`journal_title_format : string option` field instead of adding a new metadata
channel or caching state:

- `logseq_overlay_db/lib/types.ml` and `logseq_overlay_db/spec/types.mli`:
  add `journal_title_format : string option` to `graph_info`.
- `logseq_overlay_db/lib/database.ml`, `graph_info`: populate it from
  `snapshot.authoritative_database` by looking up the `:logseq.class/Journal`
  entity (`Authoritative_store.entity_of_ident`) and reading
  `:logseq.property.journal/title-format` (`Authoritative_store.one` +
  `string_of_value`). This is served inside `with_snapshot_read`, so it is
  offline-capable, snapshot-consistent with the same graph that serves page
  reads, and graph-scoped by construction.
- `logseq_db_worker/contract/protocol.ml(i)`: add `journal_title_format` to
  `V2_graph_info_outcome` and its `"graphInfo"` JSON as `journalTitleFormat`.
  No Swift/Dart decoder consumes this message, so the wire change is safe.
- `logseq_db_worker/lib/effect_runner/effect_runner.ml`: pass the new field
  through in the `V2_graph_info` arm of `read_snapshot`.

### Capture moment (chosen)

Read the format at journal-page creation, not ahead of time and cached:

- In `app/journal_graph_runtime.ml`, the `V2_missing_page` + `Capture_page`
  continuation gains a new operation `Capture_format` carrying the capture
  continuation (command, page uuid, journal day). On that arm the runtime
  issues a `V2_graph_info` request; on `V2_graph_info_outcome` matched to
  `Capture_format` it emits `V2_create_journal_page` with
  `title = journal_title ~format journal_day`.
- `journal_title ~format journal_day` resolves `format` to the stored property
  string or `MMM do, yyyy` when `None`, and formats the local journal day
  already selected by `Journal_time.local_day command.creation_time`.
- A failed `V2_graph_info` read surfaces through `failure_output` as
  `Rejected` — an absent property (`None` → default) is distinct from a failed
  read, as required.
- Because the read is issued per creation from the authoritative snapshot, the
  criteria "graph switching, offline reopening, and an observed format update
  do not use a stale format" are satisfied by construction — no cached format
  exists to go stale, and the snapshot belongs to the active graph.

### Formatter

Implement the upstream token semantics (recorded above under "Formatter token
semantics") in `app/journal_graph_runtime.ml`, covering the full cljs-time
token set (`d`/`D`, `M`, `y`, `x`, `w`, `e`, `E`, `h`/`H`/`m`/`s`/`S`, `a`/`A`,
`Z`, `o`, quoted literals). An empty pattern yields an empty title. Where
upstream would throw mid-transaction on an unsupported token, this App instead
falls back to `MMM do, yyyy` for that creation — recorded here as a deliberate
divergence so a corrupt configured format cannot wedge the capture path. This
is a resolution fallback, not a legacy-format branch.

### UI presentation

No change. `Journal_calendar.present_journal_day` owns the `YYYY.MM.DD`
presentation; `journal_timeline.ml` renders `day_presentation` and only falls
back to `page.title` when the presentation is `None` (a test-fixture-only
path). Stored `block/title`/`block/name` therefore cannot alter the displayed
date, satisfying the presentation criterion without touching UI code.

Format the local calendar day already selected by the Capture creation flow.
With the default, September 19, 2026 should produce `Sep 19th, 2026` as
`block/title` and `sep 19th, 2026` as `block/name` through the current name
derivation. With `yyyy-MM-dd` configured, both should contain `2026-09-19`.

Storage formatting and UI date formatting have separate requirements. The user
confirmed that journal dates in the UI must retain the current `YYYY.MM.DD`
presentation, such as `2026.09.19`, for both new and existing journals. Changing
`block/title`, `block/name`, or the graph's journal title format must not change
that date presentation. Preserve the UI date formatting path independently of
the stored title/name; do not replace the displayed date with the formatted
Logseq title or parse it from that title.

Remove the hard-coded title generation path. Do not add a legacy-format branch,
file-graph config fallback, migration, or automatic rewrite of stored pages.
The required upstream default is part of format resolution, not a compatibility
fallback. Preserve journal-day identity and existing-page reuse.

This exploration covers new page creation and the graph metadata needed by it.
The user confirmed on September 19, 2026 that only newly created journal pages'
`block/title` and `block/name` should change. Existing journals require no
compatibility handling, migration, or display-format adaptation.
It does not propose a format editor, timeline typography changes, or automatic
renaming. Any later UI work must comply with `docs/ux-guidelines.md` and use
native components.

### Ownership and contract investigation

Resolved. The production state owner is `Journal_graph_runtime` (the pure
reducer behind `submit`/`receive`); the defect reproduces there by driving a
`Capture` command through synthetic `V2_missing_page` and
`V2_graph_info_outcome` completions and asserting on the emitted
`V2_create_journal_page` title. Regression tests therefore belong in
`test/journal_graph_runtime_locality_test.ml` only — an injected format value
in the graph-info outcome is a legitimate input, not an already-wrong result.
No effect-runner, persistence, transport, integration, E2E, or UI duplicates.

The required `.mli` edits are `logseq_overlay_db/spec/types.mli` (the
`graph_info` record) and `logseq_db_worker/contract/protocol.mli` (the
`V2_graph_info_outcome` record). No new modules and no dune declarations are
needed: the formatter lives inside `journal_graph_runtime.ml`, which is already
in `app/dune`'s explicit module list.

Implementation is authorized, including the necessary `.mli` files under
`spec/` and dune declarations.

## Decision

Implement the proposal exactly: `graph_info` / `V2_graph_info_outcome` carry
`journal_title_format : string option`; the `V2_missing_page` + `Capture_page`
continuation issues a `V2_graph_info` read under the new `Capture_format`
operation and emits `V2_create_journal_page` with the resolved title on its
outcome. `Journal_title` in `app/journal_graph_runtime.ml` reimplements the
pinned cljs-time token semantics, including the substring clamp that keeps a
padded value shorter than the token's maximum width whole. Unsupported tokens
or invalid patterns fall back to `MMM do, yyyy` for that creation instead of
failing the transaction.

## Alternatives considered

### Change only the fixed default

Replacing `YYYY-MM-DD` with an English ordinal date would fix the default
example but still ignore configured graph formats, so it does not meet the request.

### Use platform date preferences

System locale or Swift date preferences do not represent the graph's Logseq
format and can give different results on different devices.

### Rename all existing journals

This broadens creation-time parity into historical data mutation and conflicts
with the repository's no-migration direction. It is not proposed.

## Acceptance criteria

- A missing format produces `Sep 19th, 2026` / `sep 19th, 2026` for a new
  September 19, 2026 journal's title/name.
- A configured format is used for new journals; cover at least `yyyy-MM-dd`
  and an upstream-supported format with weekday and ordinal tokens.
- The UI date remains `2026.09.19` for September 19, 2026, including when a new
  journal stores `Sep 19th, 2026` / `sep 19th, 2026` or uses a custom graph
  format. New and existing journals retain the current `YYYY.MM.DD` date
  presentation independently of stored title/name and graph format changes.
- Default ordinal behavior covers 1st, 2nd, 3rd, 11th, 12th, 13th, 21st,
  22nd, 23rd, and 31st, with month/year boundaries and leap day.
- Graph switching, offline reopening, and an observed format update do not use
  another graph's or an obsolete format for a subsequent new creation.
- Existing-page reuse and local journal-day selection remain correct; neither
  retries nor formatting changes cause a duplicate page or change its identity.
- Apply the resolved format only when creating a new journal page. Do not
  rewrite existing titles/names or add legacy compatibility and display adaptation.
- Before adding regression tests, identify the production state owner and
  attempt reproduction through public pure reducer events, completions, state,
  and effects. If that boundary reproduces the defect, add only pure reducer
  regression tests. Otherwise document the missing ownership boundary and test
  only the narrowest executing layer. Do not inject an already-wrong title as
  the supposed reproduction, bypass `.mli` interfaces, copy production logic,
  or duplicate regression coverage across layers.

## Risks

- Formatter semantics were verified against the pinned cljs-time fork and are
  reimplemented in OCaml; divergence risk remains for exotic tokens, mitigated
  by covering the full token set and falling back to the upstream default on
  unsupported tokens rather than silently using the old format.
- The chosen boundary reuses `V2_graph_info`, which already carries the public
  graph-scoped read; the added field is snapshot-consistent and offline-capable.
- Reading the format inside the creation continuation gives each emitted
  `V2_create_journal_page` an explicit snapshot of the format, so a retry of
  the same mutation stays deterministic even after a configuration update.
- Newly created journals can coexist with older stored ISO-style titles. No
  historical migration or derived display parity is included, as confirmed by
  the user.

## Consequences

Every new journal page persists its title in the active graph's configured
format, defaulting to `MMM do, yyyy` — `Sep 19th, 2026`/`sep 19th, 2026` for
September 19, 2026 — while existing pages and the `YYYY.MM.DD` UI presentation
are untouched. Journal-page creation now issues one extra graph-info read per
creation, which keeps the resolved format snapshot-consistent with the same
graph and immune to staleness across graph switches, offline reopening, and
format updates. A malformed configured format degrades to the default rather
than blocking capture; that divergence from upstream (which throws
mid-transaction) is deliberate.

## Validation outcome

- `test/journal_graph_runtime_locality_test.ml`, group
  `journal title format`: five public-reducer cases pass — default format,
  configured `yyyy-MM-dd` and `EEEE, MMM do, yyyy`, invalid-format fallback,
  failed-read rejection, and the ordinal/boundary matrix (1st/2nd/3rd/11th/
  12th/13th/21st/22nd/23rd/31st plus month, year, and 2028-02-29 leap day).
- `dune build` clean; full `dune runtest` green except the pre-existing
  `source_boundary_test` expectation of a local bonsai-swiftui release tarball
  path, which fails identically on the base commit.
- The graphInfo fixture now carries `journalTitleFormat`, keeping the protocol
  round-trip catalog exhaustive.

## Questions

- Resolved on September 19, 2026: change only newly created journal pages'
  persisted title/name; no compatibility handling for existing journals.
- Resolved on September 19, 2026: UI date presentation remains `YYYY.MM.DD`
  (for example, `2026.09.19`), even when the stored title/name format changes.
- Resolved September 22, 2026: formatter token semantics are established from
  the pinned cljs-time fork (see "Formatter token semantics"), and the public
  graph metadata boundary is `V2_graph_info` extended with
  `journal_title_format` (see "Format read boundary (chosen)").
- No user scope or technical questions remain.
