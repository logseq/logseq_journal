# Expanded Status List

## Problem

The status sheet displays a collapsed iOS menu inside a mostly empty large sheet. Users must open a second menu before seeing available statuses.

## Decision

Implement user-selected design A using existing public OCaml LUI list-item, row, icon, text, card and scroll components. Show Backlog, Todo, Doing, In review, Done, Canceled and Clear directly, retain exact current status and a non-color selected marker, and keep the existing Large sheet and close action. The user approved A on 2026-10-16 through the parent task delegation. No Swift, protected spec, Dune, lock or dependency changes are authorized.

## Alternatives considered

### Two-column tiles and grouped rows

These were presented as B and C in the design comparison; the user selected A. Picker Inline is ignored by the Journal adapter and renders as an iOS menu, so it cannot display this list.

## Acceptance criteria

- All seven existing actions are directly reachable; no nested status menu, invented option, custom status editor or Save step.
- Clicking a different status immediately submits and closes; the current status is a no-op; Close and interactive dismissal do not submit.
- Existing write/pending guards and failure feedback remain intact; rapid duplicate operations cannot submit twice.
- Current No_status, Now, Waiting and Later are represented honestly without inventing selectable values.
- Native scrolling and intrinsic text support larger accessibility sizes; selected state is expressed in text and semantics as well as color.
- Public owner/mounted tests pass, and a coordinated independent synthetic Simulator validates the actual UI with screenshots.

## Risks

- Public LUI appearance differs from static design pixels. Prefer supported native layout over custom Swift styling.
- Status modal state is private inside Application and absent from Root_navigation's pure public boundary; reproduce through Application's existing public bridge/Worker fixture and real node events as the narrowest exposed owner boundary.
- The existing host-object compatibility Simulator build is not verified full iOS OCaml cross-compilation; report the provenance limits.

## Consequences

- The status sheet uses only existing public OCaml LUI nodes; the fixed option set and command/reducer are unchanged. No product Swift, spec, Dune, lock or pin edits.
- Ten new mounted tests demonstrated RED on the menu implementation, then passed; full Application 111 and runtime 132 tests pass. Semantics, source boundary and formatting checks pass.
- Final independent synthetic Simulator screenshots confirm all default-size choices, maximum accessibility-size scrolling and Clear, current no-op, and controlled failure retention. Probe-object build run-eky2_8x0 uses the existing synthetic host shell and experimental host ARM64 compatibility object; cross_abi_validated=false. This does not establish production iOS OCaml ABI acceptance.
- Actual native review exposed overlapping direct card children; a single column child fixes the supported layout. Native selected styling is retained.

## Questions

None. Design A and local implementation/testing were approved first. After PR81 merged, the user additionally authorized publishing a formal PR and independent exact-head review. Merge and phone operations remain excluded.
