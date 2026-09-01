# Use Timelapse Doing Status Icon

## Problem

The Doing task-status action uses `incomplete_circle`, but the selected visual
language should use Flutter's `timelapse` glyph for active work.

## Proposal

Replace only the Doing status icon with Flutter `Icons.timelapse`. Keep the
No status, Todo, and Done icons, plus all status behavior, semantics, colors,
and layout unchanged. Replace the now-unused `Incomplete_circle` catalog role
instead of retaining an obsolete alias.

## Decision

Adopt `Timelapse` as the sole Material icon catalog role used by Doing.

## Alternatives considered

### Keep `incomplete_circle`

This retains the previous mapping but conflicts with the user's explicit icon
selection.

## Acceptance criteria

- Doing renders Flutter `Icons.timelapse` at U+E660.
- No status, Todo, and Done retain their existing icon mappings.
- Status behavior, semantics, colors, and layout remain unchanged.
- Focused and related tests pass.

## Risks

- `timelapse` emphasizes ongoing activity rather than numeric completion, which
  is intentional for the Doing state.

## Consequences

- The four-icon set becomes `remove_circle_outline`,
  `radio_button_unchecked`, `timelapse`, and `check_circle_outline`.
- `Incomplete_circle` is removed from the application catalog because it has
  no remaining consumer.

## Implementation evidence

The RED test rendered Doing as U+F051E (`incomplete_circle`) and failed against
the required U+E660. After replacing the catalog role and timeline mapping, the
focused rendered-icon test, full OCaml test suite, Material icon artifact
verification, generated-host check, Flutter test suite, and real-runtime
centered swipe-action test pass.

## Questions

- None. The user supplied the exact replacement icon.
