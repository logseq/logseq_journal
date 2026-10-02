# UUID reference lifetime regression verification

## Source and scope

Independent branch `fix/uuid-reference-lifecycle-20261002`, based on repeatedly fetched main `5423af832eadf9316353c2590f318eb63c7fbd07` after PR #38 merged. The original UUID worktree and other task checkouts are preserved. This repair changes the OCaml runtime/application adapter and tests only; no Swift UI, dune/spec files, dependency declarations, temporary dependency pins, or DB Worker candidate patch is included. No merge, deployment, physical-device operation, desktop Logseq interaction or personal-graph mutation occurs.

The three findings are [old source completions](https://github.com/logseq/logseq_journal/pull/38#discussion_r4162318296), [shared Changed_block failure](https://github.com/logseq/logseq_journal/pull/38#discussion_r4162318300), and [outer Worker terminal cleanup](https://github.com/logseq/logseq_journal/pull/38#discussion_r4162318302).

## Before and after

| Trigger | Before | After |
| --- | --- | --- |
| A newer target read publishes, then an older feed snapshot returns | Reference title rolls back even when the UI feed generation is obsolete | Every observed source carries its request-issuance epoch. Updates older than the cached epoch or change invalidation fence are discarded, including equal-title newer completions |
| A referenced target is also loaded, and its shared Changed_block point read fails | Old referenced title remains cached without retry/invalidation | Failed shared reads invalidate the source. A late older failure cannot clear a newer successful title |
| Four accepted reference requests terminate as outer Failed/Cancelled | Worker sends the terminal events, but application does not notify the runtime; queued targets never start | Application retains accepted Worker IDs, routes terminal outcomes through runtime failure handling, releases pending/active ownership and drains the existing bounded queue |
| An interrupted request later returns or receives another terminal | Its previously owned state risks contaminating follow-up work | Completed/failed requests become unowned; the runtime ignores late completions and duplicate terminals. The actual Worker suppresses cancelled handler returns |

The source epoch is a local monotonic counter, not a lexical ordering of opaque database revision tokens. Change invalidation fences previously issued snapshots before replacement reads are issued. The source cache keeps its existing bounds. Source work is limited to the incoming fragment and changed UUIDs; there is no graph scan per item or new scheduling subsystem.

## Test ownership and RED evidence

The production graph runtime owns source publication and hydration. Public `submit`, `receive` and `reconcile_push` operations reproduce the first two failures, so their regressions are kept at that boundary. Before the repair, the new 50-case runtime executable reports exactly two failures: stale source publication and missing shared-failure invalidation.

The pure application root reducer does not represent accepted Worker IDs or adapter cleanup effects, so it cannot reproduce the third failure. The narrowest available application boundary is `Application.For_testing.app_with_service`. The new controlled-service tests start a real Worker Domain, execute the production application adapter and LUI runtime, and observe actual Worker events and emitted label properties. They do not inject an already incorrect read result or replace the application owner.

In the failure fixture, the first four target handlers wait until all four slots are occupied, then return `Error`, producing actual outer `Worker.Response Failed`. In the cancellation fixture, tests call the real `Worker.cancel` API. Protected handlers deliberately return old values after cancellation, and actual Worker cancellation suppresses those completions. Both fixtures observed four real terminal events before the pre-fix failure: the next four queued reads never start. After the fix, queued reads finish, terminated targets can be invalidated and reread, and the final label resolves all eight targets. The public runtime additionally checks late protocol completions and duplicate old failures after interruption.

These are deterministic runtime regressions and controlled-service/application integration tests with a real Worker Domain. They are not end-to-end database/cloud, native rendering, or device acceptance tests. No new simulator screenshot is claimed.

## Validation

- Final targeted runtime: 50 cases pass, including stale overlapping feeds, unchanged newer titles, shared failure invalidation, stale failure fencing, interrupted late completion/duplicate terminal, and existing hydration limits.
- Final targeted application: 12 cases pass, including real outer Failed and Cancelled handling, four-slot exhaustion/recovery, queue draining, target reread and suppressed late cancelled returns.
- Model, ten mounted LUI cases, fifteen existing Worker application integration cases and routes pass.
- `dune build @all app/native_embed.exe.o` passes.
- Changed OCaml formatting and `git diff --check` pass.
- The first full suite exposed a new fixture teardown race: `hooks.dispose` requests asynchronous shutdown and a following existing fixture could start before session detachment. The new fixture now calls the public Worker runtime `stop` after disposal, awaiting its own session detachment. The final full-suite rerun passes both controlled-service cases and the following existing fixture.
- The clean main archive reproduces the unchanged source-boundary failure: required literal `V.progress` is absent from `app/journal_timeline.ml`, which uses `V.loading`. This is a historical source assertion, not the behavior verification for these fixes.
- `spec-dev-tool check --all` retains the existing invalid `2026-09-28-bottom-lui-capsules.md` missing Problem, Alternatives considered and Consequences. This repair decision validates.

## Final full-suite result

Final `dune runtest` exits 1 solely because of the same main-baseline `V.progress` source assertion. The rerun executes all 12 application cases successfully and all 150 sync/transport cases successfully; previously passed unchanged test actions remain cached by dune. No check was disabled or rewritten. The first restricted-sandbox run also failed synthetic transport servers with `bind(::1): Operation not permitted`; the final run permits local loopback sockets and those tests pass. Its initial fixture-detachment race is resolved by explicitly awaiting the fixture's own session stop, without changing the production disposal lifecycle.

Evidence files in this directory preserve the pre-fix runtime/application failures, final passing checks, full-suite rerun and clean-main source-boundary control. Additional first-run diagnostics and all build logs remain in the parent task directory.

- [Runtime RED](red-runtime.txt), [application RED](red-application.txt)
- [Runtime GREEN](green-runtime.txt), [application GREEN before teardown-only correction](green-application.txt)
- [Final full-suite rerun, including final application teardown](full-runtest-final.txt)
- [Clean-main source-boundary control](main-source-boundary.txt)


## Build environment and remaining limits

LUI was freshly resolved from its existing main-tracked repository: checkout and origin/main both `17ca74628e4f6577b7bef3c765d9ba003842eaa8`. It was built and installed into this task's isolated `lifecycle-prefix`, leaving the shared opam switch and other task dependency trees unchanged. Datascript uses this task's existing copied dependency prefix. No package declaration or lockfile changed; no temporary PR SHA was pinned.

```sh
eval "$(opam env --switch=logseq-journal-lui --set-switch)"
export OCAMLPATH=/Users/rcmerci/Documents/Codex/2026-10-01/task-14/lifecycle-prefix/lib:/Users/rcmerci/Documents/Codex/2026-10-01/task-14/dependency-prefix/lib
dune exec test/journal_graph_runtime_locality_test.exe
dune exec test/application_view_test.exe
dune build @all app/native_embed.exe.o
```

No simulator/native-host rebuild, live cloud peer, personal-graph performance benchmark or physical iPhone validation was run for this repair. Actual outer Failed and Cancelled were exercised; Shutdown shares the production routing branch but was not separately driven through a real session shutdown/restart acceptance test.
