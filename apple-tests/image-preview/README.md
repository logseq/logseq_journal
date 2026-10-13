# Timeline image-preview acceptance

`JournalTimelineImagePreviewAcceptance.swift` runs against an isolated full
Application host. It taps the real Timeline thumbnail, checks the selected image
and paging boundaries, zooms, shares the current image, closes, reopens, and
checks scrolled position and Detail/Back interaction after rapid closes.
It never invokes Photos or uses a personal graph.

The defect's owner is the Swift/UIKit presentation lifecycle. The public OCaml
media owner produced the correct three-file preview and selected index after
normal thumbnail taps. The native representable was then dismantled before
`viewDidAppear`, and its cleanup emitted a business dismissal. A pure reducer
test cannot execute that lifecycle. Keep this regression at the actual native
Application UI boundary; the existing `application_view_test`,
`journal_media_test` and `journal_media_runtime_test` already cover preview
references, offscreen retention, route/graph retirement and duplicate cleanup.

Use the full production Swift/OCaml host described in
[`../warm-start/README.md`](../warm-start/README.md), with five roots and 135
children. Reuse its existing build and cached dependencies when available.
The test's bundle identifier must match the isolated host. This acceptance uses
`org.logseq.journal.pr47-application-fixture`; do not install or launch it as the
production bundle.

Make a separate copy of the disposable fixture support directory. Generate
640×420 RGB PNGs named `red.png`, `blue.png` and `green.png`, with colors
`(202,44,44)`, `(40,80,210)` and `(36,160,80)`. A numbered white marker may occupy
the left portion of each image; keep its center/right region uniformly colored
for screenshot assertions. No binary image files belong in Git.

Reuse the warm-start fixture's binary PPX compilation pipeline for
`apple-tests/image-preview/generate_assets.ml`, then replace the final `#load`
with the generated `.cmo` file. Avoid pretty-printing a generated AST back into
source: compiler-only identifiers may not survive that conversion. Pass the copied support directory,
PNG directory and, for an older fixture, its existing journal-page UUID. The
generator uses public storage sessions and `Core.step` → `Effect_runner.submit`
asset requests. It starts a disposable Python HTTPS server on an ephemeral
loopback port, generates a temporary certificate with OpenSSL, and fetches the
three PNGs through the production asset runner. Its network provider routes
asset connections to that server while retaining the fixture's
`https://api.logseq.io` account identity; the production resolver may resolve
that hostname, but no production server receives an HTTP request. The temporary
certificate is trusted only by this runner, and the server and certificate files
are removed when preparation ends. Python 3 with `ssl` and OpenSSL with
`req -addext` must be available on `PATH`.

The generator releases each lease, closes the cache scope, and reads the
persisted asset back through the public cache requests before emitting PPX
metadata. It adds three ordered direct image children to the known fixture root
and updates only the synthetic journal day and title. Regenerate the synthetic
date after midnight. Run it only against the separate disposable support copy.

Stage the resulting descriptor as `Documents/timeline-images.json` and its
support directory as `Documents/support-timeline-images` in the isolated app.
Use an explicit Simulator UDID. Terminate only that fixture before copying.
Preserve the complete committed SQLite database and its WAL/SHM sidecars;
read-only mirror inspection must succeed before the UI run. Copying the database
through Python SQLite backup alone can discard sidecars needed by the read-only
startup path. Keep the preparation connection open during copying when needed.
The fixture descriptor's support path is rebased by `--support-root`.

Add the XCTest source to the existing UI runner, build it for testing and select
the `JournalTimelineImagePreviewAcceptance` class with parallel testing disabled.
The first method proves Timeline entry, paging, zoom, close and reopen. The second
starts from a nonzero scroll position and exercises three rapid closes followed
by reopening across Detail/Back. Save assertions and screenshots together; an
accessibility match alone does not establish the visible selected image.

Run `dune build @all app/native_embed.exe.o`, `dune runtest --force` and
`python3 tool/test_photo_save.py` for compilation, existing lease regressions and
the native save owner. These checks supplement the real Timeline UI result.
Keep RED/GREEN result bundles, logs, screenshots, video and source/binary hashes
outside this repository, for example under `/tmp/journal-image-preview-<date>/`.
Do not replace Timeline acceptance with a standalone Gallery fixture.
