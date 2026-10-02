# Journal media fixes: local verification

Base: GitHub main `badccfd1c68ee80cd40634f6d6d0161b31b0e879`, fetched again before implementation rounds. Worktree: `/Users/rcmerci/Documents/Codex/2026-10-01/task-4/fixes`; branch: `fix/journal-media-metadata-20261001`.

## Changes and before/after evidence

| Issue / production owner | Behavioral RED before the fix | GREEN after the fix |
| --- | --- | --- |
| External URLs / Journal_media | `Show` presented `logseq://fixture` as an external link (`Failure: external URL allowlist`). | Only complete HTTP(S) URLs produce External; mixed-case schemes, IPv6, percent escapes and Unicode paths/domains succeed. Unsupported schemes, empty host, malformed authority/port, whitespace/control bytes, invalid percent escapes and invalid UTF-8 produce an unavailable placeholder without managed demands. |
| Tag reconciliation / Journal_graph_runtime | Valid tagged point response projected `["before"]` as `[]`. Alcotest run `G1DY93OQ`, v2 boundary 0. | Public change-push/hydration/point-response flow preserves unchanged titles, replaces changed titles (including Chinese), and clears tags on a valid empty response. All 15 application integration tests pass. |
| Favorites / Application native adapter | First 64 media roots queried; root 65 was not admitted after the native journal-list visible-range callback. Alcotest run `T8V9WT7Y`, root navigation 0. | The mounted app receives the real journal-list extension event, converts Visible_range into Int64_pair, retires offscreen media roots, and admits root 65. Page/block target UUIDs differ from membership UUIDs in this fixture. Repeated visibility does not refetch the root. All 10 application view tests pass. |
| Final byte budget / Effect_runner | Actual synthetic-database children/tree reads exceeded the encoded budget after resolving tag titles. A point read with Chinese text, quotes and newlines exceeded a configured budget one byte below its actual encoding. Both new native fixture tests failed while the seven existing fixture regressions passed. | Children and page-tree enrichment overflow returns responseTooLarge within the normal response budget. The actual UTF-8/JSON-escaped point response succeeds at its exact encoded size and rejects at size minus one. All nine native worker/mutation fixture tests pass. |

URL compatibility was also tested before correction: the first strict validator rejected `https://example.com/日记.png`; the final implementation validates UTF-8, parses percent-encoded Unicode components, and preserves the original URL for the native host.

The media URL and graph runtime regressions use their public reducer/event interfaces. Favorites must exercise Application's adapter because Root_navigation does not own the media retention effects, and the media runtime works when supplied correct visibility events. Budget testing executes the real Effect_runner and database enrichment: Core has no database/tag resolution state, so injecting an oversized completion would not reproduce this defect. No implementation or private `.mli` boundary is bypassed.

## Local commits

- `6e77daa`: HTTP(S) external attachment validation + pure reducer cases.
- `c560da3`: point-read tag cache/projection replacement + graph runtime regression.
- `8542cac`: real Favorites range event retention + mounted adapter regression.
- `a9df8c5`: final encoded snapshot-read budget + synthetic database regression.
- `c9bc238`: retain legitimate Unicode HTTP attachment URLs + compatibility cases.

## Verification commands

In this worktree, use the existing Mac OCaml environment:

```sh
export PATH=/Users/rcmerci/.opam/logseq-journal-lui/bin:$PATH
export OCAMLPATH=/Users/rcmerci/Documents/Codex/2026-09-30/task-3/local-prefix/lib
dune build @all
dune exec test/journal_media_test.exe
dune exec test/logseq_db_worker_application_integration_test.exe
dune exec test/application_view_test.exe
python3 docs/test-reports/2026-10-01-journal-media-fixes/run_native_regressions.py
dune runtest
```

The checked-in native runner resolves its checkout from its own path and loads Dune's compiled public interfaces and links the existing registered `test/macos_mutation_runtime_test.ml`. The older toplevel runner cannot load `dllapp_stubs` in this environment (`_caml_startup`); the native path runs the same public tests without modifying that unrelated harness or any Dune files.

- `dune build @all`: passed (existing linker warning about the SDK SQLite text stub).
- Changed-source `ocamlformat --check`: passed.
- `git diff --check`: passed.
- `dune runtest`: affected and other tests passed, with the existing source_boundary_test failure: required literal `V.progress` is absent from unchanged `app/journal_timeline.ml`.
- The same source_boundary_test failure was reproduced against the immutable main archive; timeline source bytes match the fix checkout.
- `spec-dev-tool check --all`: existing invalid `implemented/feature/2026-09-28-bottom-lui-capsules.md`, missing Problem, Alternatives considered and Consequences. This document is unchanged. The new decision passes individually.

Local raw evidence is in `/Users/rcmerci/Documents/Codex/2026-10-01/task-4/fix-evidence/`: `favorites-red.log`, `tags-red.log`, `budget-green.log`, and `dune-runtest-final.log`. Additional RED outputs above were captured during the task before their production fixes; they are summarized here rather than labelled as raw log files.

## Scope and limits

All fixtures are synthetic and use temporary local databases or a synthetic service. The original local verification used no real user graph, notebook content, remote sync IO, mouse automation, Simulator, iPhone install, PR, push or remote merge. The original implementation checkout remains clean. No spec/ OCaml, `.mli`, Dune or bonsai_flutter file was changed.

Favorites retains the native list's visibility events and uses a root vector rebuilt when Favorites data changes; visible-window lookup does not add repeated whole-list scans. Tags are authoritative: empty metadata clears the old value. The budget guard applies to successful snapshot reads after metadata enrichment and uses actual Protocol serialization bytes bounded by configured/protocol ceilings; it does not alter mutation commit semantics or silently trim metadata. Oversized reads return an explicit failure. These are local correctness fixes, with no physical-device rendering claim.

## Draft PR publication verification (2026-10-02)

The user authorized publishing the completed local fixes as a draft PR. GitHub main remained `badccfd1c68ee80cd40634f6d6d0161b31b0e879`; all six prior local commits remain present, with no equivalent merged changes or existing PR for this branch. Composer PR #37 and the independent UUID renderer work are outside this branch. Publication adds this portable native regression runner and current evidence only; it does not change the four production fixes or dependencies. No merge, deployment, device installation or mouse automation is authorized in this publication round.

Publication rerun: `dune build @all`, the media URL reducer, all 15 application integration tests, all 10 application view tests, and all nine worker/mutation fixtures passed with the checked-in native runner. The forced full `dune runtest --force` rerun retained only the known `V.progress` source-boundary failure; changed-source formatting, portable-runner Python syntax and diff checks passed. The updated decision passes individually; the all-documents check retains the same historical capsules-document failure. The native runner only uses public compiled interfaces and temporary fixture databases.
