# Retire estimated list geometry

## Problem

Native Journal, Favorites and Detail lists already own intrinsic row measurement,
but unused OCaml profiles, character-width estimates, exact extents and a Swift
sparse snapshot implementation still remain. Their tests enforce the obsolete
renderer contract. UI-16 and UI-26 require removal, not compatibility stubs.

## Decision

- Replace Journal_row's unused Item/preview/rail renderer with the existing native
  Journal row label composition extracted from Journal_timeline. Preserve source,
  child summaries, exact task status and timestamp ordering. Journal_row remains
  a useful active module without editing Dune's explicit module list.
- Remove numeric typography/geometry/date-scaling/measurement APIs from
  Journal_visual_tokens. Keep reading-density values and the four status palettes
  used by the native Picker; remove unused status-rail/destructive/opacity APIs.
- Remove current_window, synthetic_window, extent_geometry and heading_spacing
  from Journal_timeline_state. Keep loaded slots, visibility-driven demand,
  pagination, restoration, generation fencing, deletion cancellation and recovery
  budgets. Name internal prefetch/recovery constants for their active purpose.
- Delete JournalSparseGeometry.swift, JournalCollectionSnapshot.swift, their
  sparse-collection tests/benchmark and tool/test_swiftui_collection.py. They have
  no remaining production consumer. Native JournalListViewport tests remain.
- Retire only tests for the deleted renderer: estimated widths/line counts,
  exact extents, fixed geometry tokens, bounded 40-row windows, dashed status
  rails, custom fade/clipping, corrupt Item fallback and old Item activation.
  Preserve literal/long Unicode source and child content checks against the
  active native row. Retain header, native action, native event, warm-start,
  reading-density and status-color checks. Port anchor assertions from window
  offsets to the public first_visible_index/retained_slot interfaces. Retain
  10,000-row history, paging, mutation, generation, recovery and cancellation
  tests. Remove only obsolete geometry assertions from mixed domain tests.
- Retire the old OCaml geometry benchmark rather than presenting its results as
  native List performance evidence. Native device performance remains pending.

## Alternatives considered

### Keep unused APIs or an empty Journal_row module

Rejected. This preserves obsolete paths or an empty compatibility shell. The
active row label composition naturally belongs in Journal_row.

### Delete entire test files or modify Dune

Rejected. Test files contain active domain/native behavior and Dune edits are
not authorized. Retire only the obsolete cases and keep existing test targets.

## Acceptance criteria

- Production and tests have no consumers of removed geometry/window APIs.
- Native Journal row content and existing pagination/anchor/mutation behavior
  pass the retained tests. No new fallback, fixed height or width heuristic.
- dune build @all, dune runtest, native dispatch/List tests, Swift typecheck,
  unsigned iPhoneOS Release build and spec-dev-tool check --all pass.
- No Dune, protected spec OCaml or bonsai_flutter OCaml changes.
- Main standardization remains proposed until device/accessibility/performance
  acceptance is supported by actual evidence. Undo/Redo remains deferred.

## Consequences

- Test retirement must not erase assertions for still-supported domain behavior.
- Historical geometry performance numbers no longer describe the native List.
- Intrinsic text layout still needs iPhone verification at accessibility sizes.

## Questions

- May obsolete estimated rendering paths and their exclusive tests be removed?
  Answer: Yes. The active standardization decision explicitly replaces them with
  native intrinsic layout, and the user requires obsolete paths to be removed.
- May Dune or protected interfaces be changed to delete module entries?
  Answer: No. Use the active Journal row module and retain existing test targets.

## Verification findings

Running all standalone macOS regression files also exposed a stale expectation
in M05 reload after replacement session: it still expected no Append capture
after runtime replacement. The main standardization decision already requires
restoring retained text with a fresh editor session; Journal_routes.runtime_replaced
and the production draft owner already implement that rule. Update this one
expectation to the retained Pending draft text, while preserving its fresh-session
and stale-request assertions. No draft production code or ownership changes.

## Implementation record

Implemented and verified in batch 12 of the native SwiftUI standardization
ledger. All acceptance commands pass, including every standalone macOS
regression file and the unsigned iPhoneOS Release build. The retirement
inventory and source hashes distinguish deleted renderer tests from retained
domain/native tests. Device acceptance remains explicitly unfinished in the
parent decision. No Dune or protected OCaml files were edited.
