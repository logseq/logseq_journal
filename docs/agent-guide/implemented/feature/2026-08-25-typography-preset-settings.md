# Typography Preset Settings

## Problem

The typography review defines three useful application scales, but the
application currently has one compile-time typography value. A user cannot
compare the scales in the real interface or choose the balance of feed density
and reading comfort that suits them.

The application also has no Settings screen. The only user-facing management
surface is the Account dialog, which contains graph and session actions. The
route model owns Timeline and Detail only, while Account and confirmation
dialogs are composed as modal pages from application state.

The public `bonsai_flutter` Material surface does not expose Flutter's
`SegmentedButton`. It does expose `ChoiceChip`, `FilterChip`, ordinary buttons,
and a vertically rendered `Radio_group`. A horizontal group can therefore be
built application-side from three mutually exclusive `ChoiceChip` controls
without changing `bonsai_flutter`.

The application has no device-local preference storage contract. Keeping a
selected preset only in OCaml application state is straightforward, but it
resets when the runtime or application restarts. Persistent settings would need
an explicit host-owned preference capability; the graph database is not an
appropriate store for a device presentation preference.

This exploration depends on the role definitions in
[`2026-08-25-typography-scale-review.md`](2026-08-25-typography-scale-review.md).

## Decision

Add a Settings action to the Account dialog and open a dedicated Settings modal
page. The first section is Typography and contains one equal-width horizontal
choice group:

| Control | Visible label | Meaning |
| --- | --- | --- |
| A | `A Dense` | Preserve maximum journal feed density. |
| B | `B Balanced` | Increase primary reading text while preserving compact metadata. |
| C | `C Comfortable` | Prefer larger reading text over visible row count. |

Use three Material `ChoiceChip` controls in one row. Exactly one preset is
selected. Selecting another chip applies the preset immediately; selecting the
already-active chip is a no-op, so the group can never have zero selections.
Each chip exposes its full visible label and selected state to accessibility
services. Do not approximate a connected segmented outline with custom borders.

The settings modal contains a short explanation, the choice group, the selected
preset's metrics, and a Close action. It adds no divider. Changing a preset
updates the settings surface and the application behind it immediately; closing
Settings does not require an Apply action.

The three presets are:

| Role | A — Dense | B — Balanced | C — Comfortable |
| --- | --- | --- | --- |
| Journal header title | `22/28 SemiBold` | `22/28 SemiBold` | `24/32 SemiBold` |
| Journal header subtitle | `15/20 Medium` | `15/20 Medium` | `16/22 Medium` |
| Journal entry source | `15/20 Normal` | `16/22 Normal` | `17/24 Normal` |
| Supporting and child text | `14/20 Normal` | `14/20 Normal` | `15/22 Normal` |
| Timestamp | `13/18 Normal` | `13/18 Normal` | `14/20 Normal` |
| Button and FAB label | `14/20 Medium` | `14/20 Medium` | `15/20 Medium` |
| Dialog and route title | `20/26 SemiBold` | `20/26 SemiBold` | `22/28 SemiBold` |
| Manager title | `24/32 SemiBold` | `24/32 SemiBold` | `28/34 SemiBold` |

Preset B is the selected default for new installations. All application-owned
roles change as one atomic preset; users cannot mix individual role sizes or
weights.

The runtime already supports a reactive `App.View` theme and emits theme-only
updates independently. The application must make typography and extent tokens
preset-dependent, pass the selected preset into the application theme, and
derive journal row and header extents from the same preset. Local title literals
must not remain outside the preset contract.

Represent the active modal with one explicit modal state rather than adding
another independent Boolean beside `account_menu_open`. Account, Settings, and
cache-reset confirmation must remain mutually exclusive. Opening Settings from
Account replaces Account; Close returns directly to the Timeline or Detail page
that was beneath the modal.

Persist one stable value (`dense`, `balanced`, or `comfortable`) as a
device-local, app-wide preference shared across graphs. Missing or invalid
values select `balanced`; do not add aliases or migrations for obsolete values.
Load the stored value before displaying typography-sensitive application
content so a stored A or C selection does not visibly flash through B during
startup.

### Persistence backend options

#### Native Apple UserDefaults through the existing host channel

Store the enum string in `UserDefaults.standard` on iOS and macOS. Extend the
existing application-platform envelope with bounded get- and set-preference
requests. `JournalApplicationPlatform` forwards those requests through the
existing `logseq_journal/platform` MethodChannel to the native host.

This is the selected backend. Apple documents `UserDefaults` as the
device-local persistent store for small interface and behavior settings. It
matches the current Apple-only host, adds no package dependency, is available
before graph selection, and remains independent from graph reset, sync, and
authentication state.

Source: <https://developer.apple.com/documentation/foundation/settings>

#### Flutter shared_preferences

Add the official `shared_preferences` package and use
`SharedPreferencesAsync` in `JournalApplicationPlatform`. On iOS and macOS the
package also stores values in `NSUserDefaults`.

This is the best option if Android, Windows, Linux, or web support is imminent.
It avoids duplicate Swift handlers, but adds a direct Flutter dependency and
another plugin-owned protocol layer for one Apple preference. The package also
documents that writes are asynchronous and must not be treated as critical
durable storage, which is acceptable for typography but offers no advantage for
the current platform scope.

Source: <https://pub.dev/documentation/shared_preferences/latest/>

#### Application Support JSON file

Write one bounded, versioned `settings.json` under an application-owned
subdirectory of the existing Application Support root. Use a private temporary
file, flush, atomic rename, and a directory sync, following the repository's
existing sync-catalog cache pattern.

This has no new dependency and keeps the file format explicit. It is suitable
if settings will soon become a structured application document. For one enum it
adds unnecessary file validation, atomic-write, corruption, and startup-I/O
code compared with `UserDefaults`.

#### Separate application settings SQLite database

Create an app-wide database under Application Support, separate from every
Logseq graph mirror and snapshot. This provides transactions and typed future
settings but introduces schema ownership, connection lifecycle, and recovery
policy for one scalar value. It is not recommended until settings require
multi-record queries or transactional updates.

The existing Logseq graph `db.sqlite`, sync-catalog JSON, runtime startup
configuration, and Keychain are not valid backends. They are respectively
graph-owned, account/catalog-owned, input-only, or intended for secrets.

## Alternatives considered

### Material Radio group

Use the maintained `Ui.Material.Radio_group` with A, B, and C labels.

This provides native mutual-exclusion semantics, but the current renderer lays
the radios out vertically. It consumes substantially more space and does not
match the requested group-button presentation.

### Three ordinary buttons

Render the active option as Filled tonal and the other two as Outlined buttons.

This can create equal-width controls, but selection semantics and visual state
must be layered onto generic push buttons. `ChoiceChip` already represents a
single-selection choice and is the clearer maintained primitive.

### Custom segmented control

Build a connected outline, corner radii, pressed states, and selection fill from
generic containers and buttons.

This was not selected because it would duplicate Material interaction and
accessibility behavior. The current public API has no `SegmentedButton`, and the
application should not create a compatibility implementation.

### Put the controls directly in Account

Add the A/B/C group inside the existing Account dialog.

This is shorter to implement, but it mixes presentation preferences with graph
switching, cache reset, and sign-out actions. A Settings entry establishes a
clear home for future presentation preferences without enlarging the Account
action dialog.

### Session-only selection

Keep the selected preset only in application state and reset it to the default
after every application or runtime restart.

This needs no host capability and is suitable for an evaluation build. It is
not the preferred product behavior because a user-visible setting normally
survives restart, but it remains the bounded fallback if persistent device
preferences are intentionally out of scope.

## Acceptance criteria

- Account contains one accessible Settings action.
- Settings opens as one modal surface without adding a Settings route to
  `Journal_routes` or stacking two active application modals.
- The Typography section renders one horizontal A/B/C `ChoiceChip` group with
  exactly one selected option at every revision.
- Selecting A, B, or C immediately updates every application-owned typography
  role and its dependent Header, row, and sparse-list extents.
- A uses the Dense metrics, B uses the Balanced metrics, and C uses the
  Comfortable metrics exactly as documented.
- Button labels retain Medium weight and local page-title literals no longer
  bypass the selected preset.
- Theme changes preserve System brightness, light, dark, and both high-contrast
  theme variants.
- Selection does not discard Timeline position, expanded children, Detail
  state, Capture draft, pending mutation, graph session, or focus restoration.
- The control remains usable at viewport widths `320`, `390`, `744`, and `1200`
  and text scales `1.0`, `1.3`, `2.0`, and `3.2`.
- Semantics expose the group purpose, each full option label, and the active
  selection without relying on color alone.
- Golden evidence covers the same representative journal fixture under A, B,
  and C at `390 x 844`.
- The chosen preset survives application and runtime restart, is shared across
  graphs on the device, and does not write to or sync through the Logseq graph.
- A missing or invalid persisted value selects B without adding compatibility
  aliases or data migrations.
- A stored A or C value is loaded before typography-sensitive content becomes
  visible, avoiding a B-to-stored-preset startup flash.

## Consequences

- Account exposes a Settings action, and Account, Settings, and cache-reset
  confirmation share one mutually exclusive modal state.
- Typography changes apply immediately to the mounted application without an
  Apply step or loss of route, journal, capture, mutation, graph-session, or
  focus-restoration state.
- The Apple hosts persist exactly `dense`, `balanced`, or `comfortable` in
  `UserDefaults.standard` through bounded application-platform messages.
- Startup withholds typography-sensitive content until the host preference
  resolves; missing, invalid, or failed reads select Balanced.
- Settings adds no divider and uses three equal-width Material `ChoiceChip`
  controls rather than an application-owned segmented-control imitation.

## Risks

- `ChoiceChip` is not a visually connected Material segmented button; this is
  an intentional use of the maintained public surface.
- C expands multi-line rows and can reduce visible feed density or increase
  truncation at narrow widths.
- Switching the application theme and known sparse extents in one interaction
  can cause a visible scroll-position shift unless the logical anchor is
  retained across the preset change.
- The Capture composer owns a fixed `15/19.5` input style in `bonsai_flutter`,
  so it cannot exactly match B or C through the current application API.
- Persistent settings expand the host/application contract and need startup
  ordering that avoids briefly showing B before a stored A or C choice.
- Three runtime-selectable scales triple the normal-scale golden variants and
  increase typography regression coverage.

## Questions

- None. Preset B, cross-restart persistence, and native Apple `UserDefaults`
  storage are selected.
