# Typography Scale Review

## Problem

The application currently mixes an application-owned journal scale, inherited
Material 3 roles, and local literal styles. The visible journal scale is:

| Role | Current size / line height | Current weight |
| --- | --- | --- |
| Journal header title | `22/28` | Bold (`700`) |
| Journal header subtitle | `15/20` | Medium (`500`) |
| Journal entry source | `15/20` | Normal (`400`) |
| Day heading, supporting line, and child preview | `14/20` | Normal (`400`) |
| Timestamp | `13/18` | Normal (`400`) |

The theme also leaves `bodyLarge`, `labelLarge`, and other roles at Flutter's
Material 3 defaults. Text fields therefore use `16/24 Normal`, while buttons
intend to use `14/20 Medium`. However, the generic `styled_text` helper creates
an explicit Normal weight even when no weight is requested, so button labels
can override the inherited Medium weight with Normal. Dialog, detail, message,
and manager titles also bypass the journal tokens with local `20`, `22`, and
`24` Bold literals, several without an explicit line height.

The current journal body is a defensible density-oriented scale: it is one step
larger than Material 3 `bodyMedium` (`14/20`) and matches the default iOS
Subhead metrics (`15/20`). It is nevertheless smaller than Material 3
`bodyLarge` (`16/24`) and the default iOS Body metrics (`17/22`). The result is
compact and scannable, but the primary reading content does not have as much
visual priority as it could, while some chrome is heavier than necessary.

The `11/16 Medium` disclosure text token is obsolete: disclosure is rendered
as a Material icon, and no text consumes this token.

Sources reviewed:

- Flutter Material 3 `TextTheme` scale:
  <https://api.flutter.dev/flutter/material/TextTheme-class.html>
- Flutter platform typography behavior:
  <https://api.flutter.dev/flutter/material/Typography/Typography.material2021.html>
- Apple typography guidance and iOS Dynamic Type metrics:
  <https://developer.apple.com/design/human-interface-guidelines/typography>
- Apple accessibility guidance:
  <https://developer.apple.com/design/human-interface-guidelines/accessibility/>
- W3C text-resize guidance:
  <https://www.w3.org/WAI/WCAG21/Understanding/resize-text>

## Decision

Adopt three application-owned typography presets so users can choose between
feed density and reading comfort. Balanced is the default. The Settings surface,
selection behavior, and persistence contract are defined separately in
[`2026-08-25-typography-preset-settings.md`](2026-08-25-typography-preset-settings.md).

| Role | A — Dense | B — Balanced | C — Comfortable |
| --- | --- | --- | --- |
| Journal header title | `22/28 SemiBold` | `22/28 SemiBold` | `24/32 SemiBold` |
| Journal header subtitle | `15/20 Medium` | `15/20 Medium` | `16/22 Medium` |
| Journal entry source | `15/20 Normal` | `16/22 Normal` | `17/24 Normal` |
| Day heading, supporting line, and child preview | `14/20 Normal` | `14/20 Normal` | `15/22 Normal` |
| Timestamp | `13/18 Normal` | `13/18 Normal` | `14/20 Normal` |
| Button and FAB labels | `14/20 Medium` | `14/20 Medium` | `15/20 Medium` |
| Text field input | `16/24 Normal` | `16/24 Normal` | `16/24 Normal` |
| Dialog and route title | `20/26 SemiBold` | `20/26 SemiBold` | `22/28 SemiBold` |
| Manager title | `24/32 SemiBold` | `24/32 SemiBold` | `28/34 SemiBold` |

Dense preserves the current journal body density while still softening large
application-owned headings and restoring Medium control labels. Balanced raises
only the primary journal content: its `16/22` entry role is tighter than strict
Material `16/24`, so it improves reading priority without giving away as much
vertical space. Comfortable raises the complete reading hierarchy for users who
prefer larger text over visible row count. Text field input remains the Material
`16/24 Normal` role in all three presets because the presets vary journal reading
density rather than general form-control metrics.

Implementation must define every application-owned role in one preset-dependent
typography contract, derive dependent header and row extents from that same
preset, remove local title literals and the unused disclosure text token, and
ensure unspecified text does not force Normal over a component's inherited role.
Preset changes are atomic; users cannot mix individual role sizes or weights.

The Capture composer currently owns a fixed `15/19.5` input style in
`bonsai_flutter`. Matching it to the selected journal-entry role would require a
public style parameter and remains outside an application-only implementation.

## Alternatives considered

### One fixed balanced scale

Use only the Balanced metrics for every user. This is the smallest coherent
improvement and avoids runtime-dependent layout extents and preset-specific
goldens. It was not selected because Dense and Comfortable represent legitimate
accessibility and information-density preferences that users should be able to
compare in the real interface.

### Strict Material 3 roles

Use the published Material 3 roles directly: `22/28 Normal` titleLarge,
`16/24 Medium` titleMedium, `16/24 Normal` bodyLarge, `14/20 Normal`
bodyMedium, `12/16 Medium` labelMedium, and `14/20 Medium` labelLarge.

This is the most systematic option and minimizes custom metrics. It was not
selected as a fourth preset because `12/16` timestamps are smaller than the
current accessible metadata treatment, `22/28 Normal` makes the page context
too weak in the current sparse journal layout, and `16/24` gives away more
vertical density than Balanced `16/22` without a demonstrated reading benefit
for short entries.

## Acceptance criteria

- Every visible application-owned text role has one documented size, line
  height, and weight in each preset.
- Dense, Balanced, and Comfortable use the metrics documented above exactly,
  and Balanced is the default.
- Journal, dialog, detail, manager, button, FAB, list, and input text use the
  active preset instead of local size or weight literals.
- Button labels render Medium when the component role is Medium.
- The obsolete disclosure text token is removed.
- `390 x 844` goldens cover the same representative journal fixture under all
  three presets and confirm that the header remains the strongest text, entry
  source is the primary reading content, and metadata is visibly quieter.
- Widths `320`, `390`, `744`, and `1200` remain usable at text scales `1.0`,
  `1.3`, `2.0`, and `3.2`, without clipped header text or lost row content.
- Light, dark, and high-contrast appearances retain small-text contrast.

## Consequences

- Dense, Balanced, and Comfortable are one atomic application typography
  contract, with Balanced selected for missing or invalid preferences.
- Journal headers, entries, supporting text, timestamps, buttons, dialogs,
  routes, manager surfaces, lists, and form input resolve through documented
  roles instead of local font literals.
- Header and sparse-list extents change with the active reading preset while
  text-field input remains fixed at `16/24 Normal`.
- The obsolete disclosure text token is removed; disclosure remains a Material
  icon with geometry owned by the row contract.
- The Capture composer retains its framework-owned input style until a public
  composer typography contract is published upstream.

## Risks

- Balanced and Comfortable expand multi-line rows and change sparse-list extent
  and golden expectations; changing presets must preserve the logical scroll
  anchor while those extents change.
- SemiBold (`600`) may be synthesized when only Regular and Bold faces are
  available; device rendering must be reviewed on iOS and macOS.
- The application cannot make the fixed Capture composer typography exactly
  match Balanced or Comfortable through its current public API.
- Three runtime-selectable scales increase golden and responsive-layout
  coverage compared with one fixed application scale.
- The application presets do not exactly reproduce both Material 3 and Apple
  Dynamic Type role metrics.

## Questions

None. The user selected Dense, Balanced, and Comfortable as runtime presets,
with Balanced as the default, on 2026-08-25. Strict Material 3 is not included.
