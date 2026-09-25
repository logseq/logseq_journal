# Use native SwiftUI Menu trigger semantics for the account menu

## Problem

The account menu (top-right `person.crop.circle` button in
`app/journal_header.ml`) mounts through `V.Menu.create` in
`app/journal_view.ml`, which emits this wire shape:

```text
menu-item (text:" ", icon:"person.crop.circle", width:20, size:"sm")
  └─ dropdown-menu
       └─ menu-item × N   (the real entries: Diagnostics, Switch graph,
                            Delete local graph copy, Sign out)
```

The outer `menu-item` is not a menu entry at all — it is the menu's
*trigger*. Lui reuses the `menu-item` node kind for it: a `menu-item` whose
only child is a `dropdown-menu` renders as a native popup menu
(`LUIMenuItemView` → `Menu { LUINativeMenuActions } label: { itemLabel }`).
Two mismatches fall out of that reuse:

1. `LUIWireProtocol` validates `menu-item requires text`, so an icon-only
   trigger cannot omit `text`. `V.Menu.create` works around it with a
   whitespace placeholder (`~text:" "` when `title` is empty) — standard
   SwiftUI imposes no such requirement; `Menu { } label: { Image }` is a
   first-class form.
2. `V.Menu.create` pins `~width:20` on icon-only triggers to stop the label
   `HStack` (icon + `Text`) from stretching inside bar capsules. A fixed
   20pt frame on a scalable SF Symbol can clip the icon — system images
   scale with Dynamic Type, and at large accessibility text sizes the
   rendered glyph can exceed a hard-coded 20pt box. Analysis only; no
   production change is made in this task.

The target semantic is the standard SwiftUI shape:

```swift
Menu {
    Button("Diagnostics") {}
    ...
} label: {
    Image(systemName: "person.crop.circle")
}
.accessibilityLabel("Account menu")
```

i.e. trigger label and menu content are different things, an icon-only label
needs no placeholder text, and the accessibility label lives on the trigger,
not on a hidden text run.

## Proposal

Introduce a distinct menu-trigger expression in the Lui wire/API layer so the
trigger stops impersonating a `menu-item`:

- A dedicated node kind (working name `menu-trigger`, see Questions) that
  carries the trigger's label semantics — icon, optional text, accessibility
  label — and owns exactly one `dropdown-menu` child containing the menu
  entries. Its `text` property is optional when `icon` is present, removing
  the `" "` placeholder.
- On the Apple backend, `menu-trigger` maps directly to
  `Menu { entries } label: { label }`, preserving native popup presentation,
  dismissal, and toolbar placement (`isToolbarChild` must accept the new
  kind so the trigger stays in native chrome).
- The journal side mounts `V.Menu.create` through the new node, dropping the
  whitespace placeholder and re-evaluating the `width:20`/`size:"sm"` pins
  (whether sizing stays on the trigger or defers to the native label is an
  open question below). The `"Account menu"` accessibility label keeps
  flowing through `V.semantics` → `accessibility-label`.
- Preserve what already works: existing entries, their `Button_role`
  variants (including the destructive "Delete local graph copy"), `on_select`
  dispatch, `V.Menu.choice` checkmarks via `check_menu_item`, and the
  submenu/context-menu paths that legitimately use `menu-item` children.

This is a coordinated change: the wire kind, OCaml constructor, and Apple
validation/rendering live in `logseq/lui`; the mount site and accessibility
properties live here.

## Alternatives considered

### Keep `menu-item` + whitespace placeholder

Zero work and currently functional, but it keeps a schema lie: a
non-semantic whitespace run passes validation as a label, the trigger's kind
misdescribes its role, and the `width:20` clip risk stays. The placeholder is
also a magnet for future layout surprises (e.g. a backend that trims or
measures the label text).

### Replace the trigger with a plain button and manage menu state manually

Re-creates what SwiftUI `Menu` already provides (anchoring, dismissal,
popover placement, toolbar integration) in application or shim code, and
conflicts with the repository's native-first UI policy. Rejected.

### Only adjust `width`/`size` on the current node

Widening or removing the frame pins addresses only the clip symptom. It
leaves the placeholder-text hack in place and keeps the semantic misuse of
`menu-item`, so it is at best a partial mitigation, not the decision.

### Introduce a distinct menu-trigger node

Chosen direction above: the wire accurately models trigger vs. item,
icon-only labels become valid without placeholders, and the fix generalizes
to any future icon-only menu. Cost: a cross-repo coordinated change plus a
Flutter backend decision.

## Acceptance criteria

- The trigger and the menu items are distinct node kinds on the wire; a
  `menu-item` no longer serves as a popup trigger.
- An icon-only trigger mounts without any `text` placeholder and renders
  the native `Menu { } label: { Image }` form.
- The trigger icon is not clipped at default, compact, or large
  accessibility text sizes.
- The `"Account menu"` accessibility label (and its hint) is preserved and
  announced on the trigger.
- All existing entries, their icons, the destructive role on "Delete local
  graph copy", and `on_select` callbacks behave as today; `check_menu_item`
  checkmarks still render.
- The menu works in portrait and landscape, inside the compact toolbar,
  and under large accessibility text.
- Lui backend validation tests are added/updated covering the new node kind
  (children rules, label requirements, toolbar membership).
- `dune build @all`, `dune runtest`, and `dune build @fmt` pass in this
  repo after the shim change.

## Risks

- **Cross-repo coordination.** The wire kind, `Lui_elements`/`Lui_ui`
  constructor, protocol validation, and `LUIDropdownMenuView`/
  `LUIMenuItemView` changes live in `logseq/lui`; the journal change must
  wait on a published lui rev, and intermediate states can fail validation
  (`dropdown-menu` parent rules, `isToolbarChild`, `menu-item requires
  text`) or drop the menu entirely.
- **Flutter backend parity.** `lui_flutter_backend` consumes the same wire;
  a new kind needs a Flutter equivalent (e.g. `PopupMenuButton`) or a
  defined fallback, or the mobile Flutter host regresses.
- **Existing submenu users.** `Lui_elements.submenu` is the same
  `menu-item` + `dropdown-menu` nesting used inside menus; whether nested
  triggers migrate to the new node or keep `menu-item` affects validation
  on both sides.
- **Context menus.** `context-menu` shares `menu-item` semantics with its
  own strict rules (press support, property allowlist); widening or
  splitting `menu-item` roles must not weaken those rules.
- **Accessibility regression.** Removing the visible text run makes the
  trigger icon-only; if `accessibility-label` lands on the wrong node or is
  dropped by `property_supported`, VoiceOver loses "Account menu".

## Questions

- Should the new node be named `menu-trigger`, or should `dropdown-menu`
  itself be extended to carry trigger label semantics (no new kind)?
- Should the trigger accept arbitrary label content (a child view subtree)
  or stay limited to text+icon like `menu-item`?
- Which property carries the spoken label — `accessibility-label` on the
  trigger, or should `text` double as the accessibility label when present?
- Do submenus keep reusing `menu-item` as their in-menu trigger, or does
  the submenu trigger also migrate to the new node kind?
- Does `lui_flutter_backend` need a synchronized implementation in the same
  change, or is a later parity pass acceptable?
- Should `width`/`size` remain exposed on the trigger, or should the native
  `Menu` label size itself and the pins be dropped?
