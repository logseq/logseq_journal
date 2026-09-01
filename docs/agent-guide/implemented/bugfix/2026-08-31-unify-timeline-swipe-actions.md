# Unify Timeline Swipe Actions

## Problem

Timeline swipe actions use two conflicting visual systems. The logical-start task status
actions render as transparent actions containing rounded cards with horizontal icon/label
content, while the logical-end Delete action renders as a full-bleed rectangular action
with vertical icon/label content. The Delete feedback is also not guaranteed to occupy the
full action bounds, so its content can appear above the visual center. Finally, task status
actions do not reuse the status-category colors shown by the block row's status rail.

## Proposal

Render every timeline swipe action as a full-bleed, square-cornered action with vertically
stacked icon and label content centered in the complete action bounds. Keep Delete on the
existing destructive palette. Give each quick task status action the same background color
as the corresponding block-row status category; use a neutral status-action color for
No status, because that state intentionally has no row rail. Preserve action ordering,
semantics, enablement, swipe direction, and mutation behavior.

## Decision

Adopt the proposed full-bleed swipe-action presentation. Status actions use shared visual
tokens that resolve Todo, Doing, and Done through the same category colors as row status
rails, while No status uses an opaque neutral slate. All swipe actions use white foreground
content, square corners, vertical icon/label stacking, and centered content. Delete retains
its destructive palette and boundary dividers.

## Alternatives considered

### Alternative

Restyle Delete to match the existing status cards. This was not selected because the user
explicitly identified the existing Delete action as the visual reference, and full-bleed
actions use the available narrow swipe targets more clearly than four inset cards.

## Acceptance criteria

- Delete icon and label are centered together horizontally and vertically in the full action.
- Status actions use the same full-bleed, square-cornered, vertically stacked layout as Delete.
- Todo, Doing, and Done status-action backgrounds equal their block-row status rail colors.
- No status uses an explicit neutral action color and remains visually distinct.
- All action labels/icons remain legible and existing interaction and accessibility behavior
  remains unchanged.

## Risks

- A full-bleed palette uses more saturated color than the previous neutral cards. White
  foreground content is required for predictable contrast, and golden references must be
  regenerated to record the intentional visual change.

## Questions

- None. The user's screenshots and requested Delete-based styling establish the intended
  direction; No status uses a neutral slate color because it has no rail.

## Consequences

- Task status actions no longer use transparent backgrounds, inset padding, or nested cards.
- The obsolete transparent swipe-action token is removed.
- The real-runtime golden records the centered Delete feedback, and runtime tests enforce
  status color mapping and centered action geometry.
- A debug-profile build on a physical iPhone was operated by device integration tests and
  observed in QuickTime Player, confirming centered status and Delete feedback in dark mode.
- Swipe interaction, mutation routing, semantics, and enablement remain unchanged.
