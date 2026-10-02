# Paired local composer development

This Journal branch uses LUI commit
`f73927380d7138003d2ad2f434a48f20d9d8c323` for its shared composer.
The commit is published on the LUI Composer branch in
[LUI PR #93](https://github.com/logseq/lui/pull/93), and the exact GitHub pin in
`logseq_journal.opam` resolves independently of the PR's merge state.
Merge LUI PR #93 before the Journal integration PR.
For paired local development, use a dedicated development opam switch:

```sh
opam pin add --no-action lui.0.1.0 ../lui
opam install lui.0.1.0
```

Verify `git -C ../lui rev-parse HEAD` against the pin before building.
Apple builds must use the same checkout's backend package:

```sh
JOURNAL_OCAML_OBJECT="/path/to/simulator-compatible-production.o" \
  JOURNAL_LUI_PACKAGE_PATH="$PWD/../lui/platform/apple" \
  bash tool/build_journal_apple.sh ios-simulator /tmp/JournalComposer.app
```

Use the repository's runnable OCaml object/host workflow; the Apple build
script's default stub is link-only. Set `JOURNAL_OCAML_OBJECT` to the complete
simulator-compatible production object when using this command for UI checks.

LUI owns composer measurement, attachment preview/remove targets and the
feedback slot above controls. Journal supplies descriptors and public events.
The native picker/resource adapter remains mounted while the capture is
collapsed. Collapse changes visibility only; explicit Discard clears an editing
draft. An admitted save keeps its owner. These changes do not add draft
persistence across application restarts.

Explicit Discard also invalidates the picker request generation. A completion
from that discarded draft is released instead of being attached to a new
draft. Collapse preserves the generation, so its existing staging completion
can still update the hidden draft. Both cases are covered by public reducer
events.

Validation commands: `dune runtest` in LUI, `swift test` in
`lui/platform/apple`, and `dune exec test/journal_routes_test.exe` in Journal.
The existing full Journal suite also has a source-boundary assertion requiring
`V.progress` in `app/journal_timeline.ml`; it fails on the unchanged base commit
as well and is unrelated to composer behavior.
