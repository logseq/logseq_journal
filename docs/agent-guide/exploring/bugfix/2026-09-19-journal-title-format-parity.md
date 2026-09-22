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

The requested reference is
[Logseq state.cljs](https://github.com/logseq/logseq/blob/master/src/main/frontend/state.cljs),
inspected on September 19, 2026. Its current `default-date-formatter` is
`MMM do, yyyy`. `set-date-formatter!` stores a formatter per repository, using
that default when none is supplied; `get-date-formatter` retrieves the current
repository's formatter or returns the default. It does not itself read the
Journal class property. The `master` URL is moving; pin the implementation
reference before proceeding with a formal proposal.

Supporting inspection of the local upstream checkout at
`/Users/rcmerci/gh-repos/logseq` found:

- `src/main/frontend/db/async.cljs`, `<get-date-formatter`: reads
  `:logseq.property.journal/title-format` from `:logseq.class/Journal`, with
  `MMM do, yyyy` as the default.
- `src/main/frontend/handler/repo.cljs`, `restore-and-setup-repo!`: loads that
  formatter into repository-specific frontend state.
- `src/main/frontend/worker/pipeline.cljs`, `journal-title`: derives journal
  titles from journal day and the Journal class format through a shared date utility.
- `deps/db/src/logseq/db/common/entity_plus.cljc`: also derives journal titles
  on reads. Matching all upstream read/display behavior is a broader scope than
  correcting this App's newly persisted journal titles.

The supporting local checkout is evidence to investigate, not a claim that all
those files were verified at the same remote master revision.

## Proposal

Resolve the effective format from the active graph's Journal class property,
and use `MMM do, yyyy` when the property is absent. Keep graph-specific values
isolated across graph switches and refresh them when the relevant graph data
changes. Distinguish an absent property from a failed or incomplete read.

Format the local calendar day already selected by the Capture creation flow.
With the default, September 19, 2026 should produce `Sep 19th, 2026` as
`block/title` and `sep 19th, 2026` as `block/name` through the current name
derivation. With `yyyy-MM-dd` configured, both should contain `2026-09-19`.
Verify upstream formatter token semantics and name normalization before finalizing
the implementation; native date pattern strings cannot be assumed equivalent,
particularly for ordinal days such as `do`.

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

The current overlay `graph_info` record in `logseq_overlay_db/lib/types.ml`
does not expose the journal format. Determine the narrow public read and change
notification boundary needed to supply it, including offline startup and remote
configuration updates. Identify the production owner of the resolved format
and the moment a creation command captures it so retries remain deterministic.

Before implementation, review the relevant overlay and Worker `.mli` contracts.
If the required read/change boundary is unavailable or unreasonable, stop and
report the exact spec changes and rationale. This document does not authorize
editing OCaml files under `spec/`, dune files, or bonsai_flutter OCaml sources.

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

- Logseq and native date formatter token semantics may differ. Establish the
  supported upstream format behavior, including literals and invalid formats,
  before choosing a formatter implementation; do not silently use the old format.
- Format reads and updates require a public graph-scoped ownership boundary;
  current metadata alone does not establish that boundary.
- Reading a format before a configuration update and retrying a creation after
  it requires explicit command snapshot semantics.
- Newly created journals can coexist with older stored ISO-style titles. No
  historical migration or derived display parity is included, as confirmed by
  the user.

## Questions

- Resolved on September 19, 2026: change only newly created journal pages'
  persisted title/name; no compatibility handling for existing journals.
- Resolved on September 19, 2026: UI date presentation remains `YYYY.MM.DD`
  (for example, `2026.09.19`), even when the stored title/name format changes.
- No user scope questions remain. Technical investigation still needs to
  establish formatter semantics and the public graph metadata ownership boundary.

Keep this document exploring until the formatter and public metadata boundaries
are understood. No implementation is
authorized by this exploration.
