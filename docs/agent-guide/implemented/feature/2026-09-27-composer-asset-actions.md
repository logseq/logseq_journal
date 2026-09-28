# Composer Asset Actions

## Problem

The capture composer accepts only text (plus a task toggle). Attaching an
asset requires saving the block first and then using the detail page's
"Attach file" flow, so quick capture of a photo or file takes two passes.

## Proposal

Add 文件 (files), 照片 (photo library), and 相机 (camera, iOS only) actions to
the composer action row, each arming the shared `journal-asset-import`
extension. The extension's `request` prop becomes
`{ id, source, staged }`: `source` selects the picker (`files` keeps today's
`.fileImporter`; `photos` uses SwiftUI `PhotosPicker`; `camera` uses
`UIImagePickerController` in a `UIViewControllerRepresentable`, iOS only —
elsewhere it emits `unavailable`/`dismissed`), and `staged` tells the host to
copy the pick into a temp file before emitting. Every pick flows through the
existing pick-event payload (path/title/type + the four generated UUIDs +
echoed request fields), so OCaml needs no new decode.

`Journal_capture` carries a `pending_attachments` list (cap 9) of staged
picks; the extension renders them above the composer capsule as a horizontal
strip of thumbnails (reusing `JournalMediaDecoder` for image types,
icon+name otherwise) with a remove (x) affordance. A capture with attachments
but blank text is saveable (`can_save` admits `pending_attachments <> []`).
On `Block_captured` completion, each pending pick is attached to the new
block via `Graph_service.Import_asset`, with completion/errors reported
through the existing `import_completion` mechanism. Pending attachments are
cleared on successful send and on composer close/cancel.

## Decision

Implemented as proposed:

- `composer_content`/`composer_page` take `~assets` (a
  `composer_assets` record). The attach actions are ordinary `V.buttons`
  items — 文件 (`doc`), 照片 (`photo`), 相机 (`camera`, only when the host
  passes `~camera:true`) — dispatched as `capture-attach:<source>` via
  `prefix_action`. They arm the extension by bumping `capture_pick_request`
  and setting `capture_pick_source`.
- `Journal_asset_import.request` is `{ id; source; staged }`. The detail
  "Attach file" mount sends `{ source = Files; staged = false }` and is
  unchanged; the composer sends `staged = true` with the armed source.
  `decode_event` classifies `picked` | `remove` | `dismissed` | `unavailable`.
- `Journal_capture` gained `pending_attachments` (cap `attachment_limit = 9`),
  `can_attach`, `add_attachment`, `remove_attachment ~token`,
  `clear_attachments`, and `attachment_imports` (which pairs the captured
  block id with the pending list on `Block_captured`).
- Attach-on-save is an outbox field `capture_imports` on application state,
  drained by a `run_edge_callbacks` entry that issues one
  `Graph_service.Import_asset` per staged pick against the captured block —
  covering every `Block_captured` arrival path without hooking `send`.
- Pending clears on `Capture_closed` and when the batch drains.
- `journal_graph_runtime.refresh_response` now projects the committed block
  directly when it is absent from the timeline entries (empty-source roots
  are filtered there) — otherwise `Captured`/`Updated` completions rejected
  attachment-only captures, which this feature makes possible.
- `photo`, `camera`, and `paperclip` were registered in `journalIconNames`
  (`swift/JournalIcons.swift`); unregistered names render as a placeholder
  glyph.

## Alternatives considered

### Reuse the `journal-media` extension for the pending strip

Its view renders a vertical block-attachment grid with QuickLook taps, a
reuse picker, and edit affordances — not a compact removable strip. Only the
file-image decoder (`JournalMediaDecoder`) is reused.

### Retain security-scoped URLs instead of staging copies

Scope is held by the extension view and released on disappear/completion;
pending picks must survive until attach-on-save (after the composer may be
gone), so staged requests copy into a temp file at pick time. The detail
flow keeps the unchanged scope-retain path (`staged:false`).

### Mount the strip through the lui composer's `attachments` slot

The slot hosts the picker extension inside the capsule, but it only mounts
while items exist — the first pick would have no mounted host to arm. The
extension instead wraps the composer and renders the strip itself.

## Acceptance criteria

- 文件/照片/相机 actions appear in the composer action row (camera hidden on
  macOS) and arm the matching picker.
- A pick adds a pending attachment rendered as a removable thumbnail in the
  composer; remove dispatches a `remove` event that drops it.
- Saving a capture with pending attachments creates the block, then sends
  one `Import_asset` worker command per attachment targeting the new block.
- Detail-page "Attach file" keeps working byte-for-byte on the pick event.
- `dune build`, `dune build @macos-app`, `dune build @ios-app`,
  `dune runtest`, and `dune build @fmt && git diff --check` pass.

## Risks

- Attachment-only captures create empty-source blocks; acceptable (the block
  is the attachment container).
- Temp copies of removed/discarded picks linger until OS temp cleanup.
- Attachment import failures surface only via `import_completion`; the
  composer may already be closed when they arrive.

## Consequences

- Blank text + attachments is saveable; an attachment-only capture creates an
  otherwise-empty block that acts as the attachment container.
- Attachment import failures surface through `import_completion`, which can
  arrive after the composer closed.
- Staged temp copies are consumed by the import and otherwise reclaimed by
  OS temp cleanup.

## Questions

None — the task mandate resolves the open calls: blank-text-with-attachments
is saveable, pending attachments are capped at 9, attach actions are inert
while saving or at the cap, and pending attachments clear on send and on
composer close/cancel.
