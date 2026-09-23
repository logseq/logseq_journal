# LUI API friction found while rewriting journal on the typed DSL

Working notes — things that confused or would confuse an AI consumer of the
lui API, found while porting `app/journal_view.ml` + callers to
`Lui_elements`. Each item notes where it bit us and a suggested fix.

## Emit-time validation of typed-looking values

1. **`icon ~size` / `Lui_ui.size` rejects numeric strings at emit.**
   `SizeValue` only accepts the control-size vocabulary (`default/sm/lg/icon`,
   plus `heading/display` on table_cell). Journal's old shim passed
   `"18"` — `set_prop` raises `Invalid_argument` at mount, i.e. an init
   crash, not a compile error and not a warning. The typed DSL models `~size`
   as `control_size` so it can't express point sizes at all: an icon at 18pt
   (very common in HIG toolbars/lists) is unrepresentable.
   Suggest: an `IconPointSize` int prop for icons, or allow numeric strings
   in SizeValue on `icon`.

2. **Same class of problem wherever a prop takes a closed vocabulary but the
   producer API is raw `Lui_ui.*_property` strings** — the shim could pass any
   string; nothing checked it until emit. The typed DSL fixes the *public*
   surface, but `Lui_ui` stays public and stringly — an AI reaching for the
   low-level API (which docs/examples still show) gets crashes, not types.

## Property support matrix invisible at the type level

3. **Per-kind prop whitelist lives only in runtime validation.**
   `button` on a `row`? `background` on `avatar`? `gap` on `scroll`? All
   compile, all explode (or silently drop, pre-check) at emit. The widening
   this branch did (card main/cross, scroll orientation, avatar bg/size,
   bottomTabs auto-height) was driven entirely by trial-and-error crashes.
   Suggest: typed constructors already give each element its own optional
   params — extend that pattern so props a kind can't take simply don't
   exist on its constructor (they mostly do now); the remaining trap is
   `apply_universal` accepting props for kinds that don't support them
   (e.g. `~main` on `scroll` compiles and crashes — or did before this
   branch).

4. **Two matrices must be kept in sync by hand** (OCaml `lui_protocol.ml`
   whitelist + Swift `LUIWireProtocol.swift` `propertyAllowed`). Divergence =
   `invalidBatch` crash on the backend. An AI editing one side has no signal
   that the other exists. Suggest: generate both from the schema, or have the
   OCaml emit warn when the backend profile lacks the prop.

## Layout semantics surprises

5. **`card`/`panel` children overlapped (ZStack)** until this branch — the
   natural reading of "panel" is a container like column. An AI reasonably
   writes `card [a; b]` and gets overlapping views.
   (Fixed on this branch: card/panel now stack like column.)

6. **`row` appends a hidden trailing `Spacer` for left-aligned rows.**
   Inside `scroll ~orientation:\`horizontal` that spacer explodes to
   unbounded width — chips truncated to "Mu…". Debugged via hierarchy dumps;
   no doc mentions it. Suggest: document the implicit spacer, or scope it to
   bounded-width contexts.

7. **`bottom_tabs` inside `scroll` renders zero-height** unless `~height` is
   pinned — a very natural composition for "page with tab bar" fails
   silently. (Fixed on this branch via containerRelativeFrame; remains to be
   proven on a real page host.)

8. **`avatar` with no image rendered empty** — silently. A placeholder
   glyph/initial is the platform norm. (Fixed this branch: ~background /
   ~foreground / ~width / ~height now supported.)

## Events & enabled flags

9. **`*-enabled` props must be set or events are silently swallowed.** The
   typed DSL now implies them from handler presence — but `Lui_ui` consumers
   (the old shim) still had to set `PressEnabled`/`ChangeEnabled` by hand.
   This is the single biggest silent-failure mode for hand-rolled mounts.

## Extension / plugin API

10. **Extension kinds are raw string identifiers + Yojson payload blobs.**
    `Journal_lui_native.mount` takes `identifier` string and a JSON payload
    the app builds by hand (`Native_list.build` constructs the whole list
    model as `Yojson.Basic` assoc lists). Nothing on the OCaml side ties an
    extension's prop schema to its Swift host implementation — wrong keys,
    wrong types, wrong child binding all fail only at runtime on the device.
    Suggest: `Lui_extension` codegen — given an extension schema JSON, emit a
    typed OCaml module (props record → encoder, event decoder, typed
    constructor) so extensions get the same typed surface as built-ins.

11. **Extension nodes silently can't carry standard props.**
    `set_prop` on an extension node raises; the shim needs
    `node_is_standard` guards everywhere (`with_test_id`, `frame`, grow).
    An AI wrapping an extension in `~width` gets an init crash. Suggest:
    typed constructors for extensions should accept the standard frame/
    accessibility props and route them through the extension host wrapper.

12. **Multi-mount pattern is invisible:** `menu_item_mount` exists because a
    button mounted inside a `dropdown_menu` must be a `menu_item`, not a
    `button` — the kind is dictated by the parent, not the call site. The
    typed `menu_item`/`button` split is good, but journal's shim needed a
    parallel hidden mount path per element; nothing in the API explains why.
    Suggest: a `~menu` context or a documented "menu role" adapter instead of
    duplicate mounts.

13. **`accessibility-identifier` ≠ `key` and both look like "id".**
    Shim uses `key` for semantics and accessibility_identifier for tests;
    DSL `~key` vs `~accessibility_identifier` — fine, but `menu_item`'s
    picker identity is its `key`, so an AI must know which one drives
    `on_select` ids vs accessibility. Doc needed.

## Events payload shape

14. **Lui_protocol.event is a flat ADT; payload-carrying variants differ per
    control** (`TextChanged`, `ToggleChanged`, `Submit`, `Dismiss`,
    `Press`) and the typed handlers (`~on_input` etc.) hide that — good —
    but composing custom payloads (e.g. journal's Text_edit with revision
    bookkeeping) still requires matching on the raw event inside
    `~on_input:(fun ev -> ...)`. Acceptable, but a `payload` accessor per
    handler kind (`on_input_string`) would remove a match arm every caller
    duplicates.

## Style vocabulary

15. **`style-class` names are Apple-chrome-specific magic strings**
    (`"semibold"`, `"single-line"`, `"footnote"`...) with no typed
    equivalent — the DSL keeps it a raw string param. On Flutter/web they
    no-op. Suggest: a `[ `semibold | `single_line | ... ]` typography
    variant type for the portable subset.
