# Replace bonsai-ui with logseq/lui

Status: in progress (branch `devin/lui-migration`)
Date: 2026-09-23
Decision: replace the entire bonsai-ui stack (Jane Street `bonsai`,
`bonsai_swiftui` OCaml packages, `bonsai_flutter`, `bonsai-swiftui` host
toolchain) with `logseq/lui` (`lui` + `ocaml-signal` opam packages,
`LUIAppleBackend` Swift package, `lui_flutter_backend` Dart package).
Functionality and app logic stay unchanged; system presentation differences
are acceptable.

## Why a rewrite, not a wrapper

- bonsai is an incremental-computation graph (`Bonsai.Cont.state_machine0`,
  `Bonsai.Effect`, `Cont.Clock.until`); lui is Elm-style
  (`Lui_app.create backend model update view`, `update : 'model -> 'action -> 'model`).
- `bonsai_swiftui` renders `Ui.View` trees over a binary renderer protocol;
  lui renders `Lui_elements.t` mount closures over a JSON patch protocol.
- Custom native components travel `Ui.Native_widget` (kind ids 2103-2106);
  lui exposes them through `Lui_extension` + `LUIAppleExtensionRegistry` /
  `LuiFlutterExtensionRegistry` with string identifiers and per-node props.
- The worker session RPC (`Worker.Service`, `Driver` pump) is bonsai-only;
  it is ported in-repo as `journal_worker_*` modules.

## Pinned dependencies

| package | pin |
| --- | --- |
| `lui` | `git+https://github.com/logseq/lui.git#c4468ffdbb0e68319b90306933db7edb066b778b` |
| `ocaml-signal` | `git+https://github.com/logseq/ocaml-signal.git#48a4a4d37f87addbb28d85a10a55bd13becf94be` |

Both live in `logseq_journal.opam` `pin-depends`. `bonsai`, `bonsai_swiftui*`,
`incr_dom`, `virtual_dom` are removed; the `ocaml` bound moves from `= 5.1.1`
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
- `application.ml` — ported to `Lui_app`: the `state` record becomes the
  model, `update` becomes `'model -> 'action -> 'model`, effects run inline
  (worker `send`, platform requests, timers scheduled via `Journal_pump`
  thunks), the view becomes `ui_context -> model signal -> send ->
  Lui_elements.t` built with `create_with_extensions`.
- `native_embed.ml` — `Journal_bridge.register Application.native_hooks`.
- `journal_platform.ml` — unchanged LJP2 envelope codec; only the transport
  binding changes (`Journal_bridge.platform_request` /
  `platform_event` / `platform_response` instead of
  `Driver.Handler.application_platform`).

## Hosts

### Apple (SwiftUI)

`swift/` rewires to `LUIAppleBackend` + a `LUIAppleExtensionRegistry` holding
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
entitlements, bundle ids, and minimum versions move from
`bonsai-swiftui.sexp` into the new host configuration.

### Flutter

`flutter/` replaces `bonsai_flutter`/`bonsai_flutter_native` with
`lui_flutter_backend` (+ its native hook), rewiring the Dart host to the
same C exports and registering the journal extensions in
`LuiFlutterExtensionRegistry`.

## Known semantic adaptations

- `Ui.Event.Payload.text_edit` (session ids, revisions, selection, IME
  composing) has no lui equivalent: `TextChanged (node, text)` carries the
  full text only. `Journal_capture`/editor state simplifies to plain string
  edits.
- `Cont.Clock.until` timers (sync-error card lifetime, notification
  deadlines) become model fields + `Journal_pump`-scheduled actions.
- `Bonsai.Effect` return values (worker sends, platform requests, external
  URL opens) run inline inside `update`.
- `with_test_id` → `accessibility_identifier`; `V.help` → `tooltip`;
  `V.progress ~style:Circular` → `spinner`; `V.secure_field` →
  `secure-field`; `V.text_editor`/`Text_editing.Value` → `text-field` /
  `textarea` (no selection/composing props).
