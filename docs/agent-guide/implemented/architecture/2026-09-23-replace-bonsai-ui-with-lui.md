# Replace bonsai-ui with logseq/lui

## Problem

The application rendered through the entire bonsai-ui stack: the Jane Street
`bonsai` incremental-computation packages, `bonsai_swiftui` OCaml packages,
`bonsai_flutter`, and the `bonsai-swiftui` host toolchain. That stack was
replaced with `logseq/lui` (`lui` + `ocaml-signal` opam packages,
`LUIAppleBackend` Swift package, `lui_flutter_backend` Dart package).

## Decision

Replace the entire bonsai-ui stack with logseq/lui. Functionality and app
logic stay unchanged; system presentation differences are acceptable.

The `state` record became the lui model, `update` became
`'model -> 'action -> 'model`, effects run inline, and views are
`Lui_elements.t` mount closures built through the `V.*`/`Ui.*` shim in
`app/journal_view.ml` and rendered over a JSON patch protocol. Shared UI
idioms delegate to `Lui_element_combine` composites wherever semantics match.

## Pinned dependencies

| package | pin |
| --- | --- |
| `lui` | `git+https://github.com/logseq/lui.git#835a80a3bd0e7dca7d26b35d0401372e591aa108` |
| `ocaml-signal` | `git+https://github.com/logseq/ocaml-signal.git#976b40f1770a65b3464df1ef38d1550f1d8a43dd` |

Both live in `logseq_journal.opam` `pin-depends`. `bonsai`, `bonsai_swiftui*`,
`incr_dom`, `virtual_dom` were removed; the `ocaml` bound moved from `= 5.1.1`
to `>= 5.4` (lui requirement).

## Module map

### `logseq_db_worker/lui/` (public lib `logseq_db_worker.lui`)

- `journal_worker_ids` — replaces `Bonsai_swiftui_spec.Id` subsets used by the
  worker (`Runtime.epoch`, `Worker.{generation,domain_id,request_id,
  push_sequence,push_topic}`, `Application.entrypoint_name`) as private
  int64/int/string wrappers.
- `journal_bounded_mailbox`, `journal_worker_eio_backend`,
  `journal_worker_runtime`, `journal_worker` — mechanical port of
  `bonsai-ui ocaml/runtime/{bounded_mailbox,worker_eio_backend,
  worker_runtime,worker}.ml{,i}`. Deltas: `module ID = Bonsai_swiftui_spec.Id`
  → `module ID = Journal_worker_ids`; `('response,'push) event -> unit
  Bonsai.Effect.t` subscribers → `event -> unit`; `Private.drain_to_effects
  ~schedule` → `Private.deliver ~max_events` (invokes subscribers on the app
  thread, called from the lui pump entry).
- `logseq_db_worker_lui_service` — the former
  `logseq_db_worker_bonsai_service`, same request/response/push types and
  push topics (invalidation=0, manager=1, auth=2, bootstrap=3, graph_state=4,
  asset=5), same `Service.create ~push_topic_count:6
  ~concurrency:(Concurrent{max_in_flight=2})`. Only the `Worker`/`ID`
  module references change.

### `app/`

- `journal_lui_native` — lui extension registry + mount helpers.
  Identifiers: `journal-chrome` (was kind 2103), `journal-asset-import`
  (2104), `journal-media` (2105), `journal-asset-settings` (2106),
  `journal-list` (former `Native_list` family). Every component ships one
  required `payload` string property containing the same JSON the previous
  `~encode_props` produced (so the Swift `Properties` Codable structs decode
  unchanged), and emits one `"event"` extension event with `id:int` +
  `payload:string` fields matching `BonsaiNativeEvent(id, payload)`.
  `decode_event` maps `ExtensionEvent` back for the update dispatch.
- `journal_pump` — mutexed cross-thread work queue. Worker fibers enqueue
  thunks; the app thread drains them inside the lui scheduler via the
  `journal_ocaml_pump` C entry (ocaml-signal is single-threaded — no
  `Lui_app.send` from worker threads).
- `journal_bridge` + `journal_lui_bridge.c` — native FFI. Mirrors
  `lui/platform/native/lui_ocaml_bridge.c`: `lui_ocaml_start(patch_cb,
  platform, host)` plus all `lui_ocaml_*` event entries, and journal extras:
  `journal_ocaml_extension_event(node,name,payload_json)`,
  `journal_ocaml_pump()`, `journal_ocaml_platform_event(data,len)` /
  `journal_ocaml_platform_response(data,len)` (binary-safe LJP2 envelopes),
  `journal_ocaml_set_wakeup_callback(cb)` and
  `journal_ocaml_set_platform_request_callback(cb)` feeding the OCaml
  `external`s `journal_ml_wakeup` / `journal_ml_platform_request`.
- `application.ml` — ported to `Lui_app`: the `state` record became the
  model, `update` became `'model -> 'action -> 'model`, effects run inline
  (worker `send`, platform requests, timers scheduled via `Journal_pump`
  thunks), the view became `ui_context -> model signal -> send ->
  Lui_elements.t` built with `create_with_extensions`.
- `journal_view.ml` — SwiftUI-like shim (`V.*`, `Ui.*`) over
  `Lui_elements.t` mounts; shared idioms delegate to `Lui_element_combine`
  composites (`toggle_row`, `labeled_row`, `empty_state`,
  `settings_section`, `confirm_dialog`, `check_menu_item`, `loading`,
  `feedback_banner`) when their content/behavior parameters suffice, falling
  back to manual `Lui_elements` mounts for richer content.
- `native_embed.ml` — `Journal_bridge.register Application.native_hooks`.
- `journal_platform.ml` — unchanged LJP2 envelope codec; only the transport
  binding changed (`Journal_bridge.platform_request` /
  `platform_event` / `platform_response` instead of
  `Driver.Handler.application_platform`).

## Hosts

### Apple (SwiftUI)

`swift/` rewired to `LUIAppleBackend` + a `LUIAppleExtensionRegistry` holding
one `LUIAppleExtension` per journal identifier. The host links
`journal_lui_bridge.o` + the `-output-complete-obj` OCaml archive (same
shape as `lui/examples/components/ios-swiftui` +
`tooling/mobile/build_components_ios_simulator.sh`), declares the
`lui_ocaml_*`/`journal_ocaml_*` C exports, installs the patch callback into
`LUIAppleBackend.apply(json:)`, forwards backend `onEvent`s into the C
entries (kind codes as before, extension events via
`journal_ocaml_extension_event`), and binds the wakeup callback to
`DispatchQueue.main.async { journal_ocaml_pump() }`.
`JournalApplicationPlatform` keeps its LJP2 request/response semantics:
OCaml `platform_request` callback → async `services.response` →
`journal_ocaml_platform_response`; host pushes →
`journal_ocaml_platform_event`. Amplify (`amplify-swift` 2.61.0),
entitlements, bundle ids, and minimum versions moved from
`bonsai-swiftui.sexp` into the new host configuration.

### Flutter

`flutter/` replaced `bonsai_flutter`/`bonsai_flutter_native` with
`lui_flutter_backend` (+ its native hook), rewiring the Dart host to the
same C exports and registering the journal extensions in
`LuiFlutterExtensionRegistry`.

## Known semantic adaptations

- `Ui.Event.Payload.text_edit` (session ids, revisions, selection, IME
  composing) has no lui equivalent: `TextChanged (node, text)` carries the
  full text only. `Journal_capture`/editor state simplified to plain string
  edits.
- `Cont.Clock.until` timers (sync-error card lifetime, notification
  deadlines) became model fields + `Journal_pump`-scheduled actions.
- `Bonsai.Effect` return values (worker sends, platform requests, external
  URL opens) run inline inside `update`.
- `with_test_id` → `accessibility_identifier`; `V.help` → `tooltip`;
  `V.progress ~style:Circular` → `spinner`; `V.secure_field` →
  `secure-field`; `V.text_editor`/`Text_editing.Value` → `text-field` /
  `textarea` (no selection/composing props).

## Alternatives considered

### Wrap the bonsai-ui stack behind a lui facade

Rejected — the two stacks are structurally incompatible, so no thin wrapper
was possible:

- bonsai is an incremental-computation graph (`Bonsai.Cont.state_machine0`,
  `Bonsai.Effect`, `Cont.Clock.until`); lui is Elm-style
  (`Lui_app.create backend model update view`,
  `update : 'model -> 'action -> 'model`).
- `bonsai_swiftui` renders `Ui.View` trees over a binary renderer protocol;
  lui renders `Lui_elements.t` mount closures over a JSON patch protocol.
- Custom native components traveled `Ui.Native_widget` (kind ids 2103-2106);
  lui exposes them through `Lui_extension` + `LUIAppleExtensionRegistry` /
  `LuiFlutterExtensionRegistry` with string identifiers and per-node props.
- The worker session RPC (`Worker.Service`, `Driver` pump) was bonsai-only;
  it is ported in-repo as `journal_worker_*` modules.

### Keep the bonsai-ui stack

Rejected — the migration was requested upstream; retaining the bonsai
toolchain would leave the journal on a divergent UI stack from the rest of
the product surface.

## Consequences

- The app has one renderer (lui JSON patch protocol) and no compatibility
  transport; all bonsai packages and the `bonsai-swiftui` host toolchain are
  gone.
- Editor capabilities narrowed: selection tracking, revision ids, and IME
  composing props are unavailable through lui text fields, so capture/editor
  state is plain strings.
- Timer-driven UI (sync-error card lifetime, notification deadlines) is
  owned by the model plus `Journal_pump` thunks rather than clock
  combinators.
- Presentation differs from the bonsai build in system-idiomatic ways
  (composites from `Lui_element_combine` provide the grouped-card settings
  look); functional behavior is preserved.
