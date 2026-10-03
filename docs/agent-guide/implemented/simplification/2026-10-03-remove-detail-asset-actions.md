# Remove Detail Asset Actions

## Problem

The Journal detail root exposes Replace file and Reuse existing attachment actions.
The user explicitly requested removing both functions and their related implementation:
“这2个功能可以删掉了，相关的东西都清理”. The dedicated picker, reference-read
requests, candidate enumeration and replacement state are unnecessary after that decision.

This change follows the independently verified UI update work at local commit
`57b62c65c5b52ed4d64b6d66ea3ae3f5d76e5975`. It removes capabilities, rather than
changing stored attachment relationships or treating these actions as a rendering bug.

## Removal scope

Remove the two controls from the OCaml media view and the legacy native media adapter.
Remove their dedicated runtime tickets, reference/candidate state, callbacks, event routes,
replacement picker props and Journal import wire fields. Keep the ordinary detail Attach
file request sequence under the name `asset_import_request`.

Preserve Capture and Append attachment selection, ordinary import/upload, thumbnails,
image gallery, preview, file leases, metadata pagination and retries. Preserve shared worker
and database APIs, including durable import replacement fields and set-asset-reference
operations: normal Journal imports will supply `replace_reference=None`. Do not alter
existing graph data, attachment files or remote relationships, protected spec files or Dune.

Use public mounted media-view absence tests and public normal-import decode tests first.
There is no pure reducer that owns whether media action controls render; the existing
public mount boundary is the narrowest production owner for that removal. The import
selection parser is public and needs no effect-runner or persistence duplicate coverage.
Delete only tests dedicated to the removed action flows; retain shared owner regressions.

## Decision

Remove both Journal controls and their dedicated implementation as explicitly requested.
Retain shared backend contracts, ordinary attachment flows and all saved relationships.
The change is isolated on `feat/remove-detail-asset-actions`, based on the independently
verified stage 1–3 commit. No remote submission or asset-data operation is part of it.

## Alternatives considered

### Hide the controls and retain the implementation

Not selected: it leaves dedicated events, candidate state and replacement adapters behind,
contrary to the explicit cleanup request.

### Remove shared asset storage and worker APIs

Not selected: these own durable import recovery and general asset-reference semantics.
The user requested removing two Journal controls, not deleting stored assets or references
or narrowing other callers' storage contracts.

## Acceptance criteria

- Detail and media views expose neither action nor the reuse candidate controls.
- No dedicated Journal replace/reuse events, runtime state, callbacks or native picker props remain.
- Ordinary native file selections decode without the removed replacement field and produce
  normal imports with `replace_reference=None`.
- Existing attachment, preview/gallery, lease/reset, draft/session and application owner
  tests remain green. Parent-coordinated native detail Attach and preview checks remain usable.
- Shared worker/storage APIs and their tests have no diff; no protected spec or Dune files change.
- The new decision and updated current-facing architecture descriptions validate.

## Risks

- Users lose Journal's ability to repoint an attachment to a new or existing asset through
  these two controls. Existing saved references continue to render normally.
- The Attach file request counter and shared image decoder have other consumers and must
  remain. Removing them as apparently related code would break ordinary attachments.
- Historical architecture notes include earlier feature delivery evidence. Record its removal
  and update current UI claims without erasing shared backend contracts or measurement history.

## Consequences

Journal no longer offers file replacement or existing-asset selection from block detail.
Ordinary detail Attach and Capture attachments continue to create normal asset imports;
existing referenced assets continue to display. Dedicated Journal state and candidate
reads are eliminated. Shared storage/worker reference and durable replacement APIs remain
for their general contracts and independent callers; no data migration or deletion occurs.

The internal media/import adapter signatures lose removed parameters. Native products must
be rebuilt together with their OCaml producer; there is no legacy-action compatibility path.
Earlier stage 1–3 measurements and commit remain independently reviewable.

## Questions

- Should both controls and their dedicated implementation be removed while preserving
  ordinary attachments and shared backend APIs? **Answered:** the user explicitly requested
  removing both functions and related code; the scoped proposal above follows that decision.

## Implementation record

- Removed OCaml and legacy Swift media action controls, candidate UI and the editable
  flag; removed dedicated reference/picker tickets, group state, worker callbacks and
  event routes. Runtime Query and Lease ownership, dedup, paging and reset remain.
- Removed Journal replacement picker props and native selection field. The public parser
  accepts ordinary selections without that field, and both direct and staged normal imports
  construct the shared worker request with `replace_reference=None`.
- Kept the ordinary detail Attach request sequence as `asset_import_request`. Kept Capture
  staged selection, imported previews, pending thumbnails and JournalMediaDecoder.
- Deleted only action-specific owner tests; retained shared lease/import/visibility/dedup
  cases. Existing Append readiness testing now waits for its actual Detail block node,
  because the deleted action label cannot serve as a loading marker.
- Public mounted media control absence and public import parser tests failed against
  the frozen implementation, then passed after removal. Focused semantics, routes,
  media-runtime and all 23 application-view tests pass. Swift syntax parsing passes;
  full `dune build @all` (including rebuilt native Swift) and `dune runtest`
  pass. Both original registered macOS regression groups also pass against
  public native dependencies. A separate final-source Release N50 Simulator run
  exercises native picker cancellation followed by Append editing/save, normal PNG import
  with `replace_reference=None`, thumbnail decode, Back and preserved Capture draft.
  All 70 compiled app source digests match the final source.
- The production file-image press opens the native Quick Look controller and its public
  dismissal closes it. The preview screenshot is blank: preview content remains unverified,
  with no matched old-source preview to establish whether this is a regression. Fixture
  worker completions and picker delegate selection are synthetic; external file gestures,
  persistence, sync and hardware rendering are outside this run.
- Updated the architecture's current UI claims while retaining shared atomic backend
  semantics and marking earlier removed-feature native evidence as historical.

Logs, source inventory and remaining-identifier checks are retained outside Git under
`implementation-evidence/remove-media-actions` and
`implementation-evidence/post-removal-native/RESULTS.md`. No performance improvement is claimed
for this removal; prior stage 1–3 measurements remain attached to their frozen source.
