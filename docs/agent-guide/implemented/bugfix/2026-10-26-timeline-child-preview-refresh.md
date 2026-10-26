# Timeline Child Preview Refresh

## Problem

In the normal native/Web C2 acceptance sequence, editing an existing child reaches the current local transaction and appears in Detail, while Timeline retains the old child text even after returning from Detail. Timeline stores child summaries in the parent entry; a child point update currently replaces only matching top-level UUIDs. The same gap exists in baseline source; the live change-window/completion history was not recorded, so this does not claim a replay or establish PR introduction.

## Decision

Refresh an already-retained child summary from the production projected child point model when child UUID, parent UUID and page agree. Copy source and asset file type; do not add a fourth preview or load a subtree. Reuse the existing replace_block path, persistent slot update and anchor preservation. Authoritative structural page replacement remains responsible for child membership, ordering, removal and filling a preview after deletion/movement. No Worker/API, protected spec, Dune, native or graph changes.

## Alternatives considered

### Reload the entire retained page for every child title edit

This adds unnecessary root and preview reads for a non-structural edit. The existing projected point model already contains both displayed fields.

### Add a separate parent-dependency cache

Duplicating ownership and cache invalidation is unnecessary for updating a child already present in a bounded parent summary.

## Acceptance criteria

- Production projection and the public pure Timeline owner reproduce seven behavioral RED cases: visible text, asset type/clear, same-day/older-day retained suffix, repeated edits/parent refresh, and hidden-parent restoration. Five bounded-selection, foreign ownership and authoritative structural controls remain green; all twelve pass after correction. Evidence and temporary source snapshots stay outside the repository.
- Refresh source and asset metadata in visible and retained-suffix previews without changing the three-child selection, root UUIDs, order, counts, continuations or scroll anchor.
- Ignore non-preview children and foreign parent/page points. Verify normal authoritative move/delete reconciliation removes or refills membership; the point update must not introduce a child under the wrong parent.
- Verify parent root updates preserve the refreshed summaries, repeated child updates converge, and hidden-day restoration does not restore stale child text.
- Run appropriate targeted and full final-source regression; retain evidence outside the repository. Native acceptance remains with the existing owner.

## Consequences

- A point update cannot establish a new bounded child selection after a structural change. That remains the authoritative page reconciliation path; this fix must not guess missing members.
- The preserved native failure is not operated on by this task. Pure-owner tests do not constitute native/server E2E acceptance.

## Questions

- None. The user approved the minimal preview fix and regression coverage. A later explicit approval permits commit/push to the existing PR117 after verification; no merge, release or GUI/graph operation is authorized here.
