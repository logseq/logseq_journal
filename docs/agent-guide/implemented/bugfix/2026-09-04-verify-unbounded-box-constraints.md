# Verify Unbounded Box Constraints

## Problem

The graph picker composes a minimum-height constrained row with an expanding
alignment inside a vertical scroll view.  The previous `bonsai_flutter`
protocol encoded omitted maximum box constraints as `Float.max_float`, which
Flutter treated as a bounded dimension.  The row therefore expanded to
approximately `1.797e308` logical pixels and centered its visible label far
outside the viewport even though the graph remained present and actionable in
the semantics tree.

The installed framework now represents omitted maxima explicitly and renders
them as `double.infinity`, but this repository still pins the older framework
revision and one structural test still expects a non-optional maximum width.

## Proposal

Pin both application packages to `bonsai_flutter` revision
`5101a51d980c53bf9aab1e9420321ea8a7d58f9b`, adapt structural assertions to the
new optional maximum-constraint representation, regenerate the mechanical
Flutter packages through `bonsai-flutter`, and verify the graph picker on
macOS.  The runtime verification must confirm that the graph row and label
have finite viewport-local geometry.

## Decision

Adopt `bonsai_flutter` revision
`5101a51d980c53bf9aab1e9420321ea8a7d58f9b` without adding an application-owned
height workaround.  Update the structural assertion for an explicitly bounded
time slot to require `Some expected_width`, while leaving the graph row's
minimum-only constraint unchanged so the framework fix remains exercised by
the real application.

## Alternatives considered

### Constrain the graph row in the application

Adding an exact application-owned height would hide the protocol defect and
would not protect other consumers that combine unbounded constraints with
expanding children.  The application should retain its minimum touch-target
constraint and rely on the framework to preserve Flutter's unbounded layout
semantics.

## Acceptance criteria

- Both OPAM package definitions pin the same updated framework revision.
- OCaml compilation and the complete repository test suite pass against the
  optional maximum-constraint API.
- The generated Flutter package uses `null` for an omitted maximum and maps it
  to `double.infinity` in the renderer.
- On macOS, the graph picker visibly renders an authorized graph row and the
  render tree reports finite row and label geometry inside the viewport.
- Flutter analysis and tests complete without errors.

## Risks

- The protocol wire encoding changed, so stale generated Flutter packages are
  incompatible with the updated OCaml native artifact.  The verification must
  rebuild the complete application through `bonsai-flutter` rather than using
  bare Flutter commands.

## Consequences

- Omitted maximum constraints now preserve Flutter's native unbounded layout
  semantics throughout the OCaml-to-Dart protocol.
- The application and generated Flutter renderer must be rebuilt together
  whenever this protocol revision changes.
- The graph picker remains content-sized and can continue to honor future
  typography or touch-target changes without duplicating a fixed row height.

## Questions

- None.

## Implementation

- Updated application, worker, and lock manifests to pin framework revision
  `5101a51d980c53bf9aab1e9420321ea8a7d58f9b`.
- Adapted the exact time-slot width assertion to the optional maximum-width
  representation.
- Rebuilt the mechanical Flutter packages through `bonsai-flutter`; no
  application-owned graph-row height workaround was added.

## Verification evidence

- `dune runtest` passes, including the source-boundary and journal semantics
  suites.
- Flutter package tests pass and `flutter analyze` reports no issues when run
  through `bonsai-flutter exec` from the `flutter/` package.
- A debug macOS build launches with the graph catalog visibly rendered and
  scrollable.
- The runtime render tree reports a 48 logical-pixel graph item, a 44
  logical-pixel content row, and a 22 logical-pixel label under an unbounded
  maximum-height constraint.  It contains no `double.maxFinite` geometry.
