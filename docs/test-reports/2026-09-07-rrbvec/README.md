# Retained ordered state: implementation and acceptance

The implementation replaces the three retained List owners in the approved decision with `Rrbvec.t`. It preserves protocol and Flutter List boundaries, cursor equality, ordering, state retention limits, and frozen outbox payloads. The measured benefit is principally lower allocation and retained memory, with faster deep timeline windows. Complete mutation/replan or frame speedups are not implied.

## Reproduction and provenance

- Baseline: `b32baf08ef0503cc84ab5df613607b058efa9e59` in a detached worktree.
- Package: `rrbvec.dev`, Git pin `dd5ce904f91d53235b5136f7a771f3f074c3971d`.
- Environment: native arm64, OCaml 5.1.1, the same installed dependency closure for both implementations.
- [summary.json](summary.json) records production source digests, per-sample measurements, standard deviations, allocation, GC counts, and live-memory observations. [measurements.md](measurements.md) reports medians, observed ranges, absolute allocations, and ratios. Every paired operation has matching output checksums.

Run the same executable probe against either worktree:

```sh
python3 tool/rrbvec_owner_probe.py --worktree /path/to/worktree --owner timeline --size 512
python3 tool/rrbvec_owner_probe.py --worktree /path/to/worktree --owner worker --size 512
python3 tool/rrbvec_owner_probe.py --worktree /path/to/worktree --owner overlay --size 4096 --shared
python3 tool/rrbvec_owner_summary.py
```

`rrbvec_owner_probe.py` obtains compiled public library interfaces and their native dependency closure from Dune. It compiles the same [owner_probe.ml](owner_probe.ml) and the registered Worker test fixture against each implementation. It does not use `Obj`, private module entry points, bypass a `.mli`, or duplicate a production collection algorithm. Worker fixture checks run before measurement and are recorded in the raw logs.

Measurements run sequentially, with seven samples per operation; the first sample is discarded. Elapsed time uses `Mtime_clock` and integer nanoseconds. Fixture construction and one-time input creation happen outside timed regions. Required output construction happens inside them. Full major collection precedes a sample. A minor collection flushes allocation accounting after the timer stops; reported minor-GC counts include that final flush. Allocation is reported in words in raw logs and converted to bytes using the arm64 word size. Forced collections are not included in the elapsed-time measurement.

Timeline samples repeat 10,000 window reads, 3,000 point updates, 1,000 expand/collapse pairs, or 500 complete geometry/window preparations. The 16-slot and 512-slot workloads include front, middle, and trailing windows. Worker samples each start with a fresh database and publish 16 or 512 real mutations, then measure paged pulls, acknowledgment, and ten interleaved publish/pull/ack operations. This prevents outbox growth between samples from changing the workload. A publication includes its real target read, mutation, persistence, projection callback, and event drain. Pulls include DTO creation and the public Worker request path. Individual acknowledgment samples have substantial scheduler/timer variation and are not used to claim a speedup.

Overlay samples use valid fixture outboxes at 32, 128, and the configured limit of 4,096 records, with disjoint UUIDs and repeated changes to one UUID. Seeding and opening happen outside timing. Replan measurements invoke public authoritative-commit operations; reads use public pinned snapshots. Complete replan still includes UUID Map work, effect replay, diffing, persistence, and the unchanged temporary outbox/children-index construction.

## R1: Worker windows

`database_session.windows` retains vectors throughout publication and acknowledgment. Cursor search yields an index, then pull slices only the returned range and folds it into protocol DTOs once. Exact equality is required even for the fast latest-cursor check. Count is constant time; arbitrary cursor search remains linear.

The report includes both the complete implementation and an isolated R1 build, so Overlay bucket changes are not incorrectly attributed to Worker window storage. Whole-publication latency remains dominated by database work. The isolated 512-publication workload shows a deterministic reduction in allocation; it does not establish a meaningful complete-mutation latency improvement. Some cursor searches and suffix operations have higher allocation constants than Lists, as the proposal anticipated.

The public Worker tests cover empty and acknowledged cursors, duplicate acknowledgment, unknown acknowledgment, stale generations, zero-limit pages, 70 ordered publications across vector leaf boundaries, seven-window pagination, prefix acknowledgment, noncanonical and evicted cursors, immutable returned pages, and oversized-publication resync. The resync test verifies that old windows disappear, their cursors are rejected, and a subsequent publication remains readable.

Live-memory samples before/after acknowledgment show the retained-window memory being released. `RESYNC_LIVE_WORDS` in the Worker logs records full-GC observations around a real oversized insertion; its net heap delta also includes the newly inserted tree and outbox payloads, so it is not an isolated window-release allocation metric. The empty post-resync result, rejected old cursor, and the production reset to `Rrbvec.empty` establish that the owner no longer retains the old windows. No retention cap or new cursor index has been added. A queue comparison was not used to justify these results: the measured owner includes non-destructive paging, and the implementation requested here is the vector representation.

## R2: Timeline slots

The retained state and staged deletion roots are persistent vectors. Windows and retention trimming use slices; adjacent slot access uses `retained_slot`; Application block lookup uses `find_block`. `fold_slots` replaces the obsolete complete-List accessor. Point updates visit every matching occurrence and use `set`; contiguous edits splice retained slices. Undo reconciles removed keys into current state and preserves intervening updates rather than restoring an old root wholesale.

At 512 slots, point-update allocation falls from approximately 12.5 KB to 616 bytes per operation. Middle and trailing windows improve, while front/small windows and small splices have extra constants. These extra costs are fractions of a microsecond in the measured workloads; complete geometry/window preparation stays within approximately 4% of the List baseline for small states and is essentially unchanged for 512-slot states. This tradeoff is acceptable for the requested retained-state representation and is not presented as a universal operation-speed improvement.

Keeping 128 changed states plus staged deletion grows live memory by 197,510 words with Lists versus 6,609 words with vectors in the 512-slot fixture. Both release those versions after undo. The measured preparation includes complete sparse extent calculation and window materialization; it is not a Flutter frame/GPU benchmark. Existing rendering tests and the native app builds separately verify the real consumer path.

The public state test was red before implementation: one point update with the old state still reachable retained 1,557 new words, exceeding the 600-word sharing budget. It is green with vectors. The same test checks stable ordering, old-state immutability, an intervening sibling edit, an intervening insertion, restored deletion, and retention capping. Existing tests retain coverage for 10,000-record rolling input, 50,000 synthetic windows, heading boundaries, anchors, summaries, expansion epochs, loading/cursor markers, stale completions, generation changes, focus restoration, and undo geometry.

## R3: Overlay effect buckets

Block/page bucket values are vectors in all queryable roots and snapshots. Bulk index construction converts each completed bucket once. Incremental replan uses `push_back`. Point, tombstone, and tree-candidate readers traverse the vectors directly, retaining chronological and first-match semantics. UUID Maps, unrelated outbox Lists, and children indexes retain their original representations. `frozen_outbox` still copies mutable record payloads.

A separate diagnostic build counts append allocation and replay visits, without changing production code or using diagnostic timings as performance evidence:

```sh
python3 tool/rrbvec_bucket_profile.py --worktree /path/to/disposable/worktree --size 128
```

The script temporarily instruments the implementation in a disposable worktree, calls only the same public Database operations, and restores the source afterward. It forces minor collection around each append and subtracts an empty-call calibration. These diagnostic GC barriers invalidate timing comparisons; only copy allocation and visit counts are reported from these runs.

For 128 records on one UUID, every diagnostic sample reports:

| Observation | List | Vector |
| --- | --- | --- |
| Consumed block bucket memberships | 128 | 128 |
| Bucket append allocation, words | 24,768 | 3,290 |
| Logical block/page replay visits | 16,256 | 16,256 |
| Page/children memberships in this Save-block fixture | 0 | 0 |

Sources: [List diagnostic](buckets-128-shared-list.log), [vector diagnostic](buckets-128-shared-vector.log). Page bucket behavior is additionally covered by the existing journal-creation/page-read suites; this particular allocation workload makes no page-bucket speed claim. The unchanged unused replan outbox construction is included in complete timings and is not credited as a vector benefit.

In the 4,096-record shared-UUID workload, complete replan allocation drops by approximately 200 MB out of roughly 26 GB of cumulative allocation, while median replan latency changes from approximately 3.14 s to 3.08 s. That small complete-operation change is consistent with the unchanged quadratic replay cost. Ordinary block/page/structure reads remain within approximately 2% in these samples. Disjoint bucket construction can allocate slightly more because vector roots have a higher constant cost. The repeatable bucket-copy reduction, lower large-shared-owner allocation, and stable ordinary-read costs satisfy the scoped allocation objective without claiming subquadratic replan.

The new public Database case performs forty chronological writes to one UUID, holds a snapshot after the twentieth write, replans after an authoritative update, and verifies both the current fortieth title and the frozen twentieth title. Existing tests cover ordinary reads, tree/tombstone reads, dependency shadows, persistence, and concurrency. The representation does not make mutable payloads immutable; the explicit freezing remains required.

## Repository and behavior validation

The task adds no new bug ownership boundary. These are resource and behavior-preservation tests for a representation change. Timeline exercises public pure state transitions. Worker acceptance uses real public reducer events with its existing effect runner, where retained windows are owned. Overlay acceptance executes public Database operations, where bucket construction/replay is owned. No already-incorrect external result is injected, no regression is duplicated across additional layers, and no existing test is removed.

The following checks cover the final implementation; [validation.json](validation.json) records statuses and native framework hashes:

- `dune build @all` and `dune runtest`.
- `python3 tool/test_macos_regressions.py`.
- `ocamlformat --check` on changed OCaml sources and the probe; `git diff --check`. The full 241-file audit also found three unchanged historical reproduction files that fail formatting on both baseline and current worktrees; see [format-audit.json](format-audit.json). They were not reformatted as part of this representation change.
- `opam lint` on all changed package declarations and lock files.
- `bonsai-flutter build macos --profile debug`.
- `bonsai-flutter build ios --profile debug --no-codesign`, including Mach-O and iOS app-bundle verification.
- Both built native frameworks contain `camlRrbvec` symbols. This verifies the application link closure rather than merely the installed opam pin.
- Only the three authorized library `dune` files and their dependency declarations in `dune-project` change. Direct package declarations and transitive lock closure include the pinned dependency, including the `logseq_sync` lock through Overlay.
- No OCaml file under `spec/` and no Bonsai Flutter OCaml file is modified. Existing Flutter components, maximum retention 512, maximum supplied rows 40, overscan 4, and UX behavior are preserved.
- `spec-dev-tool check --all` validates the decision lifecycle and document format.
