# Logseq DB Worker Implementation Plan

Goal: Add an independent `logseq_db_worker` package under `logseq_db_worker/` that safely reads and writes pinned Logseq DB graphs through one shared semantic engine used by both a `bonsai_flutter` Worker service and a standalone CLI.

Architecture: A UI-independent `Engine` exclusively owns one restored DataScript database and one Logseq-compatible SQLite session, while thin Bonsai and CLI adapters translate into the same typed `Protocol.request` and call the same `Engine.execute` function.

Tech Stack: OCaml 5.1.1, Dune, `datascript-ocaml-native`, SQLite 3 through `sqlite3`, `bonsai_flutter`, Eio, Cmdliner, Yojson, and the pinned Logseq ClojureScript implementation as the semantic oracle.

Related: [Current application architecture](001-journal-mobile-app-architecture.md), [Logseq outliner operations](../../../logseq/deps/outliner/src/logseq/outliner/op.cljs), [Logseq DB schema](../../../logseq/deps/db/src/logseq/db/frontend/schema.cljs), [DataScript Logseq SQLite example](../../../datascript-ocaml/examples/logseq_sqlite_storage.ml), and [Bonsai Worker contract](../../../bonsai_flutter/ocaml/runtime/worker.mli).

## Problem statement

The repository currently owns an application-private journal store rather than a native Logseq graph.

The existing store uses a custom exact `journal.*` schema and the generic `Datascript_sqlite` backend.

That backend creates `kvs(address TEXT, payload TEXT)`, while a current Logseq DB graph stores DataScript pages in `kvs(addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)`.

The two layouts are not interchangeable, so opening SQLite successfully is not evidence of Logseq compatibility.

The target package must instead implement the current Logseq DB graph model, physical storage contract, tree invariants, and outliner semantics.

The target package must expose one read and write contract to both the Bonsai Worker service and the CLI.

The CLI cannot reuse `Worker.Service.t` directly because that type is abstract and its lifecycle callbacks are not public.

Both adapters must therefore reuse a lower-level engine rather than duplicate graph behavior.

Direct production writes to a real Logseq graph are blocked until lossless codec behavior, exclusive graph ownership, minimum-schema admission, atomic persistence, and cross-runtime write parity are proved.

## Research scope and baseline

This plan was produced from read-only inspection of the current repository and its sibling `logseq`, `datascript-ocaml`, and `bonsai_flutter` repositories.

No OCaml, Dune, Flutter, Logseq, or DataScript implementation file was changed during this research.

| Repository | Inspected commit | Relevant baseline |
|---|---|---|
| `logseq_journal` | `fbd42bfa0c60d1cef46f5dcd1b3f62754aeb4fcd` | One app-private DataScript store and one Bonsai Worker service slot. |
| `logseq` | `4f21d068aed43bb2ea5823247cae73ecdd8d60f8` | DB graph schema `65.33` and the current outliner pipeline. |
| `datascript-ocaml` | `b1029d6a7210baae15aa2189293bd126b746bad4` | Generic SQLite backend plus a private Logseq storage example. |
| `bonsai_flutter` | `d5f8d36b5539550cbc2466311acda4d8c609032e` | Typed singleton Worker Domain runtime and SQLite device closure. |

The current `logseq_journal` working tree already contains many unrelated modified files.

Implementation must begin by reconciling those changes and must never overwrite or normalize them as part of this feature.

The current dependency manifests pin `bonsai_flutter` at `d5f8d36`, while the existing source-boundary test still expects the older `a512` pin.

That pre-existing baseline mismatch must be resolved or explicitly recorded before feature test failures can be attributed to this package.

Semantic goldens must run from a dedicated detached Logseq worktree at `4f21d068aed43bb2ea5823247cae73ecdd8d60f8` which rejects every tracked, staged, and untracked change after verifying HEAD.

Coordinated ownership, sidecar, and interop changes use a separate Logseq worktree and their own recorded commit, so a dirty or patched runtime can never generate output labeled as the pinned semantic oracle.

Repository policy requires explicit authorization before any Dune file is modified.

The implementation described below necessarily changes root and package Dune files, so that authorization is a hard precondition rather than an implied part of this planning-only request.

## Research findings

### Current repository boundary

[`app/journal_schema.ml`](../../app/journal_schema.ml), [`app/journal_storage.ml`](../../app/journal_storage.ml), and [`app/journal_repository.ml`](../../app/journal_repository.ml) implement a journal-specific persistence layer.

That layer deliberately rejects extra schema attributes and cannot admit a Logseq graph with dynamic property attributes.

[`app/application.ml`](../../app/application.ml) calls `App.create_with_worker` with `Journal_worker.service`.

The current Bonsai application therefore has one service slot, not a dynamic service registry.

The new service must eventually replace the existing service or participate in one composite application service.

This plan recommends replacement and removal of the obsolete app-private storage path because the repository explicitly disallows compatibility layers.

The existing journal tests still provide useful behavioral patterns for UUID validation, expected-revision conflicts, bounded responses, subtree behavior, and fatal storage-failure handling.

Those patterns should be re-expressed against Logseq semantics rather than copied with the old schema.

### Bonsai Worker boundary

The supported integration chain is `Worker.Service.create` to `App.create_with_worker` to `Native_backend.embed`.

`Worker.Service.t` is abstract, and the CLI cannot call its `init`, `handle`, or `shutdown` callbacks.

The Bonsai adapter must call `Engine.open_` during Worker `init`, `Engine.execute` during `handle`, and `Engine.close` during `shutdown`.

The CLI must open and call that same engine directly, as demonstrated by the lower-layer reuse pattern in [`network_smoke_cli.ml`](../../../bonsai_flutter/examples/network/ocaml/network_smoke_cli.ml).

The service must use `Worker.Service.Serial` because one engine owns one mutable DataScript state and one SQLite connection.

Worker requests use a bounded mailbox, and push delivery is latest-wins by topic.

Graph push events must therefore be bounded revision or invalidation messages rather than a lossless transaction stream.

Expected business failures must be encoded in `Protocol.response` so every transport observes the same typed result.

A Worker's `handle -> Error string` fails only that request and leaves the Worker session attached, while an uncaught handler exception terminalizes the Worker session.

A mutation-time persistence write or commit failure is not an expected protocol failure.

The Engine becomes `Fatal`, the Bonsai adapter raises a bounded fatal exception so the Worker session terminates, and the application renders a fatal error which requires an application restart before the graph can be opened again.

### Logseq physical storage

The canonical Logseq table is declared in [`common/sqlite.cljs`](../../../logseq/deps/db/src/logseq/db/common/sqlite.cljs).

Address `0` contains the DataScript root metadata, address `1` contains the transaction tail, and later integer addresses contain persistent sorted-set pages.

`content` is Transit JSON, while `addresses` is a separate JSON list of child addresses.

The current private OCaml implementation in [`logseq_sqlite_storage.ml`](../../../datascript-ocaml/examples/logseq_sqlite_storage.ml) can restore and query substantial real-graph data.

It is an examples-only Dune library without a `public_name` or public interface, so a consumer package cannot depend on it as a stable installed library.

Its current multi-address store concatenates UPSERT statements without an explicit encompassing SQLite transaction.

Its codec also maps some unsupported Transit values into less precise OCaml values, which is unsafe when compaction rewrites a complete root or index page.

The public generic `datascript-ocaml-native.sqlite` library is not an acceptable fallback because its table schema and payload contract are different.

The Logseq-compatible codec and atomic session belong to `logseq_db_worker` and are bound to the exact pinned `datascript-ocaml` commit.

The package uses the current public immutable `Datascript.db`, transaction report, storage payload, `Storage.store`, `Storage.store_tail`, and restore APIs instead of adding a new upstream findlib component.

The private upstream example is a research reference only and is neither linked nor copied as a second implementation.

If the current pinned public API cannot pass the local compile-time staging spike and atomicity tests, implementation stops and reports the exact API blocker before any dependency pin or architecture change is proposed.

### Logseq graph and outliner semantics

The current graph schema version is exactly `65.33` in [`schema.cljs`](../../../logseq/deps/db/src/logseq/db/frontend/schema.cljs).

The active DB graph tree uses `:block/parent` and fractional string `:block/order`, not legacy `:block/left`.

Stable external identity is `:block/uuid`, while property schema identity is a qualified `:db/ident`.

Numeric DataScript entity IDs are connection-local implementation details and must never enter the public protocol, persisted command history, or push messages.

The current Logseq UI and Logseq CLI converge on `logseq.outliner.op/apply-ops!` and its validated canonical operation batch.

That function stages operations on an isolated temporary connection and commits the combined change once to the real connection.

Save, insert, delete, move, indent, outdent, page, and property operations contain domain behavior beyond direct datom updates.

Examples include fractional-order generation, parent and page rewrites, cycle prevention, built-in protection, timestamps, title-derived references, typed properties, orphan cleanup, recycle metadata, and transaction metadata.

Block deletion currently performs a hard subtree delete after removing selected descendants whose ancestor is also selected.

Normal page deletion is different because it moves the page into the hidden Recycle hierarchy, while class, property, built-in, hidden, and today's journal pages have special rules.

Default outdent reparents the original root's right siblings beneath the final outdented block to preserve visual preorder.

The alternative logical-outdent behavior is not the default and must not be selected accidentally.

Split and merge are editor-level composites rather than canonical primitive outliner operations.

The current worker persists client-operation and undo history for ordinary local transactions as well, and those rows become sync-critical when the graph is remote or RTC-enabled.

Writing only the main graph SQLite file cannot provide the remote pipeline or an atomic commit across those stores.

### Graph ownership and derived stores

Logseq uses a graph-local `db-worker.lock` with `repo`, `pid`, `lock-id`, and `owner-source` fields.

The current node worker atomically creates the lock, rejects a live or inaccessible owner, attempts stale cleanup only after the recorded PID is reported absent, and exposes an ownership assertion used by selected guarded methods.

Its stale path is a read-then-unlink sequence which can race with replacement, and it does not guarantee universal pre-write revalidation or identity-checked release because the main outliner path and low-level storage callbacks do not re-read the lock on every write and shutdown unlinks the path without comparing `lock-id`.

Universal revalidation and owner-only release below are therefore new coordinated requirements rather than claims about the current runtime.

SQLite's own lock is necessary but insufficient because another Logseq process may retain an older DataScript database in memory and later overwrite disk state.

The new engine must never act as a live multi-writer.

The OCaml engine is not a reusable Logseq db-worker-node daemon, so the compatible initial choice is `owner-source = unknown` rather than a false CLI or Electron identity.

A future distinct `ocaml-worker` identity requires a coordinated lock-protocol and allowed-owner-value change in Logseq.

The production ownership contract must be coordinated and tested in the Logseq repository so Desktop and the Logseq CLI fail safely while the OCaml owner is active.

Logseq search and vector databases are derived sidecars, but direct main-database writes bypass the normal listener that updates them.

Native writes must invalidate those sidecars before the first main-database mutation while exclusive ownership is held, and failure to invalidate must block the mutation.

### Compatibility choice

This plan recommends exact compatibility with the pinned Logseq `db.sqlite` format rather than a normalized OCaml-only SQLite store plus export and import adapters.

That choice is required if the product must open a Logseq graph directly and later allow the pinned Logseq runtime to reopen and continue editing it.

The choice increases the initial cost because compatibility includes Transit values, persistent-set pages, root and tail behavior, graph admission, and cross-runtime mutation parity.

No implementation may describe an OCaml-only normalized store as a Logseq graph.

## Recommended scope and decisions

The target is a DB graph, not a live file graph and not a dual file-and-DB graph.

The target physical format is the exact pinned Logseq `db.sqlite` format.

The minimum supported schema is `65.33`.

Older schema versions are rejected with `Unsupported_schema`; schema `65.33` and newer versions continue through lossless value and semantic admission, and the package performs no graph migration.

Accepting a newer schema version does not authorize lossy decoding or unknown writes: any storage value or operation semantics the pinned codec cannot preserve is rejected before mutation with `Unsupported_value` or `Unsupported_semantics`.

This is deliberately stricter than Logseq itself, which migrates older local graphs, reports a newer local graph as requiring a newer client, and uses schema-major compatibility for RTC.

The package opens existing graphs only and does not create a new graph or synthesize Logseq built-ins.

The package distinguishes `:logseq.kv/local-graph-uuid`, which identifies an ordinary local graph, from a non-nil `:logseq.kv/graph-uuid` or client-operations `sync_meta.graph-uuid`, which identifies RTC state in the pinned runtime.

The package rejects a graph when `:logseq.kv/graph-remote? = true`, or when non-nil RTC identity exists without a consistent remote flag, and reports malformed or contradictory combinations as `Ambiguous_sync_state`.

The client-operations database, pending local rows, and the mere existence of RTC-related schema entities without a value are not sufficient remote classifiers by themselves.

The package supports verified package-created snapshots first and enables a real local graph only after the native ownership and sidecar invalidation gates pass.

The package never permits live multi-writer access.

The native graph directory is platform-defined and selected before Worker startup.

On Desktop, the graph directory is `~/logseq/<graph-name>`.

On iOS, the graph directory is `<app-data-dir>/graphs/<graph-name>`.

The trusted platform adapter expands and canonicalizes the platform base directory, validates `<graph-name>` as one confined path component, and passes the resulting absolute graph directory to the Engine.

The native database path is always `<graph-dir>/db.sqlite`; no legacy encoded-repo directory lookup, alternative root, or raw caller-supplied path fallback is supported.

Block delete follows current Logseq hard-subtree-delete semantics.

Page delete follows current Logseq recycle semantics for ordinary pages.

Outdent follows current Logseq direct-outdent semantics.

Split and merge are excluded from the first stable protocol because editor cursor and selection behavior are outside this worker.

Raw write transactions, arbitrary write Datalog, direct template, import, reaction, asset-management, undo, redo, sync, and RTC commands are excluded from the first stable protocol.

Automatic canonical main-graph effects triggered by a supported operation are not excluded silently and must either reach parity or produce a typed pre-stage rejection.

The first structural slice contains block reads plus `Save_block`, `Insert_blocks`, `Move_blocks`, `Move_up_down`, `Indent_outdent`, and `Delete_blocks`.

The next accepted slices add page and typed property operations one operation family at a time behind the same compatibility gates.

The current application integration replaces `Journal_worker.service`; it does not attempt to attach a second service to the same `App.t`.

The entrypoint registry can contain multiple `App.t` values, but each `App.create_with_worker` carries one typed service and the process has one active logical Worker session at a time.

## P0 gates before a production writer

1. The Logseq physical codec and staged atomic session must be implemented once inside `logseq_db_worker` and bound to the current pinned DataScript commit.

2. Every Transit value reachable from an admitted `65.33` graph, including dynamic user values, must round-trip losslessly, and an unsupported value must reject read-write admission before any mutation.

3. The local session must implement `stage -> atomic commit -> install` from the pinned public immutable DB and Storage APIs and must not use the current stored `Conn.transact` path, which installs `conn.db` and advances mutable tail bookkeeping before storage success is known.

4. One SQLite commit containing every changed node, root, and tail write must use `BEGIN IMMEDIATE`, `journal_mode = WAL`, and `synchronous = FULL`, with SQLite rollback when an error is reported.

5. The engine must install `db_after` and the staged tail or compaction bookkeeping only after SQLite reports a successful commit.

6. Any mutation-time persistence write or commit failure must move the Engine to `Fatal`, terminate the Worker session, render an application-level fatal error, and require application restart rather than returning a recoverable protocol response, while checkpoint and close failures retain their adapter-specific shutdown diagnostics.

7. The pinned Logseq runtime must restore and validate an OCaml-written graph and then perform a subsequent outliner mutation successfully.

8. The OCaml engine must restore and continue from a graph mutated by the pinned Logseq runtime.

9. Every read-write target, including a verified snapshot, must acquire an exclusive owner lock, and a snapshot must be package-created and verified rather than trusted from a caller-supplied mode label.

10. A formally tested exclusive-owner contract must cover lock races, stale locks, malformed locks, permission errors, identity tampering, and owner-only release.

11. Remote, non-nil RTC-identity, contradictory-sync-state, unsupported-schema, and unsupported-value fixtures must fail closed, while ordinary `local-graph-uuid` and client-operation history fixtures remain remote-classifier admissible and untouched.

12. Search and vector sidecars must be invalidated before the first native mutation or native mutation must remain disabled.

13. The exhaustive command algebra, payloads, preconditions, automatic pipeline effects, conflict outcomes, and parity oracle must be approved before implementation behavior is added.

14. Dune modifications in this repository and any coordinated `logseq` ownership or sidecar changes must receive explicit authorization.

## Target architecture

```text
Flutter host or Bonsai component
              |
              v
Logseq_db_worker_bonsai_service
              |
              | Protocol.request
              v
        Logseq_db_worker.Engine <---------------- Standalone CLI
              |                                      |
              | one execute path                     | Protocol.request
              +------------------+-------------------+
                                 |
                  +--------------+--------------+
                  |                             |
           Query projections              Outliner planners
                  |                             |
                  +--------------+--------------+
                                 |
                  Staged and validated db_after
                                 |
                  Atomic Logseq SQLite session
                                 |
          db.sqlite plus explicit owner and backup
```

The core dependency graph is one-way.

```text
pinned Datascript + sqlite3 -> logseq_sqlite_codec/storage -> storage_session
                                                                  |
protocol <- graph_types <- admission/query/outliner ------------> engine
                                                                  ^     ^
                                                                  |     |
                                                                CLI   Bonsai
```

The core library must not depend on Bonsai, Flutter, Cmdliner, process-global CLI state, `Worker_runtime`, or `Eio_posix.run`.

The CLI and Bonsai libraries may depend on the core, but they may not contain graph query or mutation rules.

## Proposed package layout

The package lives in the existing root Dune project and does not introduce a nested `dune-project`.

The opam manifest remains at the repository root as `logseq_db_worker.opam`, while every source file owned by the package remains under `logseq_db_worker/`.

Because both packages are released from this source tree at version `0.1.0`, a local solve must pin both package names before installing either one:

```sh
opam pin add logseq_db_worker . --no-action
opam pin add logseq_journal . --no-action
opam install logseq_journal
```

`logseq_journal` depends on exactly the sibling `logseq_db_worker` version; no unpublished fallback source or compatibility package is supported.

```text
logseq_db_worker/
  lib/
    dune
    logseq_db_worker.ml
    logseq_db_worker.mli
    config.ml
    config.mli
    error.ml
    error.mli
    graph_types.ml
    graph_types.mli
    protocol.ml
    protocol.mli
    graph_locator.ml
    graph_locator.mli
    admission.ml
    admission.mli
    ownership.ml
    ownership.mli
    snapshot.ml
    snapshot.mli
    backup.ml
    backup.mli
    logseq_sqlite_codec.ml
    logseq_sqlite_codec.mli
    logseq_sqlite_storage.ml
    logseq_sqlite_storage.mli
    storage_session.ml
    storage_session.mli
    query.ml
    query.mli
    mutation_plan.ml
    mutation_plan.mli
    engine.ml
    engine.mli
    outliner/
      order.ml
      order.mli
      tree.ml
      tree.mli
      validation.ml
      validation.mli
      references.ml
      references.mli
      save_block.ml
      insert_blocks.ml
      move_blocks.ml
      indent_outdent.ml
      delete_blocks.ml
      pages.ml
      properties.ml
  bonsai/
    dune
    logseq_db_worker_bonsai_service.ml
    logseq_db_worker_bonsai_service.mli
  cli/
    dune
    main.ml
    cli_command.ml
    cli_command.mli
    cli_output.ml
    cli_output.mli
  test/
    dune
    test_support.ml
    test_protocol.ml
    test_graph_locator.ml
    test_codec.ml
    test_storage_atomicity.ml
    test_admission.ml
    test_ownership.ml
    test_snapshot.ml
    test_query.ml
    test_order.ml
    test_save_block.ml
    test_insert_blocks.ml
    test_move_blocks.ml
    test_indent_outdent.ml
    test_delete_blocks.ml
    test_pages.ml
    test_properties.ml
    test_engine.ml
    test_bonsai_service.ml
    test_cli.ml
    test_cross_runtime.ml
    test_performance.ml
    fixtures/
      logseq-65.33/
      codec/
      protocol/
      expected/
  tool/
    dune
    logseq_oracle.cljs
    generate_fixtures.ml
    compare_canonical_graphs.ml
```

The exact file split may be reduced during refactoring, but public types must remain confined to `Config`, `Error`, `Graph_types`, `Protocol`, and `Engine`.

DataScript database values, SQLite handles, storage callbacks, numeric entity IDs, and lock handles must remain private.

## Testing Plan

The implementation uses test-driven development with all contract, unit, integration, differential, failure-injection, adapter, and platform tests written before production behavior.

The first test pass establishes a deliberate RED baseline using compiling interfaces and nonfunctional stubs.

Each failure must name the missing behavior rather than fail because of a syntax error, missing fixture, unavailable tool, or unrelated repository baseline issue.

### Test layers

| Layer | Purpose | Primary files |
|---|---|---|
| Protocol | Prove stable JSON and OCaml request, response, error, cursor, and limit contracts. | `test_protocol.ml`, `fixtures/protocol/`. |
| Locator | Enforce the Desktop and iOS graph-directory contracts, graph-name confinement, and canonical database location. | `test_graph_locator.ml`. |
| Snapshot | Prove backup-based creation, atomic import and publish, catalog-token binding, tamper rejection, and interrupted-entry cleanup. | `test_snapshot.ml`. |
| Codec | Round-trip all pinned Transit tags, schema values, root metadata, tail groups, datoms, and address lists. | `test_codec.ml`, `fixtures/codec/`. |
| Atomic storage | Prove staged state is not installed early, each physical batch is atomic, every injected mutation write or commit failure produces an application-level fatal error, and checkpoint or close failures produce their shutdown diagnostics. | `test_storage_atomicity.ml`. |
| Admission | Accept a local graph with compatible schema metadata and reject every unsupported mode without scanning graph datoms. | `test_admission.ml`, `test_engine_open.ml`. |
| Ownership | Prove exclusive acquisition, identity revalidation, stale handling, tamper detection, and owner-only release. | `test_ownership.ml`. |
| Read model | Prove bounded, deterministic, UUID-based graph projections and pagination. | `test_query.ml`. |
| Outliner | Prove current Logseq structural, page, reference, order, and property semantics. | `test_order.ml` through `test_properties.ml`. |
| Engine | Prove lifecycle, expected-basis conflicts, staged commit, fatal persistence outcomes, backup, and sidecar invalidation. | `test_engine.ml`. |
| Adapters | Prove the Worker and CLI map to the same `Engine.execute` trace without semantic branches. | `test_bonsai_service.ml`, `test_cli.ml`. |
| Differential | Compare the pinned Logseq runtime and OCaml engine in both write directions. | `test_cross_runtime.ml`, `tool/logseq_oracle.cljs`. |
| Platform | Prove the current immutable SDK accepts the local Bonsai dependency closure and prove macOS operation, iPhoneOS packaging, persistence, close, and relaunch. | Consumer builds plus package and signed-device smoke tests. |
| Performance | Enforce the approved response, open, latency, and RSS budgets on a recorded reference machine and fixture. | `test_performance.ml`. |

### Mandatory codec corpus

The codec corpus must include null, booleans, integers, 64-bit integers, floating-point values, strings, keywords, symbols, UUIDs, instants, regex values, lists, arrays, maps, sets, tuples, references, DataScript datoms, schema maps, root metadata, tail groups, and persistent sorted-set nodes.

The corpus must also contain every Transit tag reachable from a fresh schema `65.33` graph and from representative block, page, class, property, task, journal, asset, and recycle entities.

Unknown tags, out-of-range numbers, malformed address JSON, malformed root or tail values, dangling addresses, and lossy values must produce typed admission errors.

### Mandatory atomicity cases

Fault injection must fail each prepared UPSERT, root write, tail write, commit, WAL checkpoint, and close path.

Tests must prove that `stage_transact` changes neither the Engine database nor session tail and that no production mutation calls persisted `Datascript.transact` or `Conn.transact`.

No injected failure or process-termination test on the supported filesystem may observe a mixture of old and new root, tail, or index pages after restart.

Every injected mutation persistence failure must move the Engine to `Fatal`, prevent every later request in that session, terminate the Worker session, and cause the application harness to render the fatal error state.

The failing request receives no recoverable `Protocol.Failed` storage response.

The CLI must print the bounded fatal diagnostic and exit with code `5`.

A checkpoint or close failure must produce the documented CLI exit or Worker shutdown diagnostic even though application destruction may prevent a new UI state from being rendered.

### Mandatory structural outliner cases

Save tests cover built-in rejection, UUID immutability, title changes, unchanged saves, timestamps, page timestamps, page-name normalization, references, tags, scheduled and deadline references, orphan cleanup, Unicode, and size limits.

Insert tests cover before, after, first-child, last-child, nested preorder input, caller-supplied UUIDs, blank-target replacement, cross-page insertion, internal reference remapping, and invalid parents or orders.

Move tests cover ordered multi-root selections, selected descendants, same-parent moves, cross-parent moves, cross-page subtree rewrites, before, after, first-child, last-child, original-position rejection, page targets, self moves, cycles, built-ins, comments, and property-value membership.

Move-up and move-down tests cover top and bottom boundaries, multi-root order, nested contexts, and no-op results.

Indent tests cover missing left siblings, multiple continuous roots, collapsed left siblings, last-child order generation, and invalid discontinuous selections.

Outdent tests cover page roots, property-value rejection, direct-outdent right-sibling reparenting, order preservation, cross-page invariants, and cycle prevention.

Block-delete tests cover hard subtree deletion, selected ancestor deduplication, built-in rejection, reference cleanup, range-comment cleanup, default property value replacement, empty input, and missing UUIDs.

Page tests cover create, rename, ordinary recycle delete, today's journal clearing, built-in and hidden rejection, class and property deletion rules, restore, permanent delete, title ambiguity, and UUID identity.

Property tests cover qualified identifiers, UUID resolution, same-title ambiguity, type and cardinality validation, self-reference rejection, single and many values, explicit replace and append batch modes, status and class rules, closed values, default placeholders, and idempotent no-op updates.

Order tests cover exact fractional keys, key validity, insertion between adjacent values, insertion at both bounds, long repeated insertion, and stable string ordering.

Separate sync or rebase parity cases cover the pinned touched-order duplicate repair and prove ordinary local mutations do not run an unconditional whole-graph repair.

### Mandatory read and protocol cases

Every collection read must require a positive bounded limit and return a deterministic continuation cursor.

Every cursor test must cover canonical encoding, authentication, expiry, key rotation, protocol version, query fingerprint, basis, last sort key, tampering, filter changes, and a stale-basis `Conflict` between pages.

Every successful response must include the resulting basis, every failure includes it when known, and every response must remain within the configured byte budget.

Selectors must accept UUIDs or explicitly typed page and property selectors, and an ambiguous title must return `Ambiguous_selector`.

Numeric entity IDs must never appear in JSON, public OCaml values, push events, golden output, or persisted semantic commands.

Malformed protocol versions, unknown operations, trailing fields, oversized input, invalid UTF-8, and invalid UUIDs must be rejected before engine execution.

### Mandatory cross-runtime cases

The fixture runner must create a fresh graph with the pinned Logseq runtime and emit a canonical projection plus the source commit and schema version.

Clone A must receive a Logseq outliner operation while clone B receives the matching OCaml request.

The comparison must preserve UUIDs and order, inject deterministic creation UUIDs wherever the reference API permits, and normalize only storage addresses, DataScript transaction numbers, clock values, or unavoidable generated UUIDs explicitly declared nondeterministic by that case.

The canonical comparison must include entity attributes, tree preorder, parent and page identities, orders, references, tags, properties, and recycle metadata.

After every OCaml mutation and close, the pinned Logseq db-worker-node must restore, validate, query, and execute one further outliner mutation.

After every corresponding Logseq mutation, the OCaml engine must reopen and continue with the next request.

Remote, contradictory-sync-state, old-schema, unsupported-value, and unsupported-semantics fixtures must be stable rejection cases; newer-schema fixtures must prove admission when every reachable value and requested semantic remains supported.

Local fixtures containing `:logseq.kv/local-graph-uuid`, value-less RTC-related schema entities, a client-operations store, and pending local rows must not be classified as remote when `:logseq.kv/graph-remote?` is false or absent.

A non-nil `:logseq.kv/graph-uuid` or client-operations `sync_meta.graph-uuid` must reject remote-disabled admission as contradictory RTC identity rather than being confused with the local graph UUID.

### Proposed boundedness and performance budgets

Task 0 must record the exact CPU, memory, OS, SQLite version, build profile, and cold or warm cache condition used for release measurements.

Before approving thresholds, Task 0 must also freeze the fixture content hash, benchmark command, process-reset policy, warm-up count, sample count, percentile estimator, cold-cache procedure, RSS sampler, variance allowance, and retry rule.

The initial RED contracts use a `1 MiB` request envelope, `256 KiB` encoded response ceiling, `64 KiB` push ceiling, default page size `50`, maximum page size `200`, maximum tree result `2,000` nodes, maximum tree depth `64`, and maximum changed-UUID push list `1,024`.

On an Apple Silicon reference machine with at least `16 GiB` RAM and a release build, the proposed `100,000`-block fixture budgets are cold open within `15 s`, peak RSS below `1.5 GiB`, warm `Get_block` p95 below `20 ms`, warm `Get_children` for `100` items p95 below `100 ms`, and a post-backup structural mutation p95 below `750 ms` across at least `100` samples.

Snapshot creation and the first native recovery backup are measured and reported by bytes per second rather than hidden inside the mutation latency budget.

If the pinned Logseq or OCaml baseline cannot meet a proposed number, Task 0 must approve a replacement before the RED suite is frozen rather than weakening it after implementation.

### RED verification

Run the complete package test target after interfaces, stubs, fixtures, and tests exist.

```sh
opam exec -- dune runtest logseq_db_worker/test
```

The command must fail only at assertions that identify unimplemented codec, admission, ownership, query, outliner, engine, adapter, and parity behavior.

Record the failing test inventory in the implementation task or pull request before adding production behavior.

NOTE: I will write *all* tests before I add any implementation behavior.

## Public configuration contract

`Config.t` must identify a graph through Logseq concepts rather than accept an arbitrary database leaf.

```ocaml
type compatibility_profile =
  | Logseq_65_33_or_newer

type target =
  | Snapshot of { token : Uuid.t }
  | Import_snapshot of { inbox_entry : string }
  | Native_local_graph of
      { graph_name : string
      ; graph_dir : string
      }

type t =
  { application_support_directory : string
  ; target : target
  ; compatibility_profile : compatibility_profile
  ; response_budget_bytes : int
  ; default_page_size : int
  }
```

`application_support_directory` is an absolute existing directory which owns the snapshot catalog, cursor keys, temporary imports, and diagnostics.

For `Native_local_graph`, `graph_name` is one non-empty UTF-8 path component and `graph_dir` is the absolute canonical directory derived by a trusted adapter from the platform contract.

Desktop derives `graph_dir` by expanding and canonicalizing `~/logseq/<graph-name>`.

iOS derives `graph_dir` by resolving `<app-data-dir>/graphs/<graph-name>` beneath the application data-directory capability.

`Graph_locator` rejects separators, `.`, `..`, NUL, invalid UTF-8, symlinks which escape the platform graph base, and any mismatch between `graph_name` and the final directory component.

The resolved native database path is `<graph-dir>/db.sqlite`.

There is no `repo->graph-dir-key` transformation, URI-component directory encoding, legacy `<root>/graphs/<encoded repo>` lookup, arbitrary graph-root override, or automatic path fallback.

There is no protocol or user-facing CLI raw-path mode; `graph_dir` may only be constructed by a trusted platform adapter or the Desktop CLI's fixed resolver.

No caller-declared detached or native label, generic SQLite fallback, implicit migration, or automatic format detection is allowed.

Locator tests must cover Desktop home expansion, iOS application-data confinement, Unicode graph names, empty names, separators, `.`, `..`, NUL, invalid UTF-8, symlink escape, a basename mismatch, a missing directory, a missing `db.sqlite`, and canonical-path stability across repeated resolution.

`Snapshot.create` uses the SQLite backup API, writes a catalog-key-authenticated manifest inside the copied graph, registers an unguessable token in the package-owned snapshot catalog, and returns that token to the caller.

The snapshot token resolves its target exclusively through the adapter-owned catalog and cannot be combined with a caller-supplied graph directory or graph name.

The CLI resolves one platform application-support catalog at process startup, and the Bonsai adapter receives one rooted under the framework Worker data-directory capability.

Neither graph protocol requests nor normal CLI subcommands accept a catalog-root override, while tests inject a temporary catalog capability when constructing the adapter.

Moving a snapshot between hosts requires `Snapshot.import`, which copies it into the destination catalog root, verifies the manifest and database identity, and issues a new local token.

`Import_snapshot` names one bounded file or directory entry under the adapter-owned `inbox/` capability and cannot carry an absolute or relative filesystem path.

Worker `init` may import that entry through the shared `Snapshot.import` core operation, atomically consume it, and open the newly issued catalog token.

As a temporary physical-device bootstrap path, an iOS `Native_local_graph` may also import a same-name inbox directory when the configured native graph is missing or returns `Corrupt_storage` during its first open. The Worker copies `inbox/<graph-name>/db.sqlite` through the SQLite backup API into an app-owned temporary directory beneath `<app-data-dir>/graphs`, atomically publishes it as `<app-data-dir>/graphs/<graph-name>`, and retries the original native target.

This bootstrap is confined to the exact iOS native-directory contract. It never runs for Desktop paths, a valid native graph, `Graph_locked`, `Storage_busy`, `Unsupported_schema`, `Remote_graph`, `Ambiguous_sync_state`, unsupported client history, an invalid inbox entry, or a differently named inbox entry. A replaced corrupt graph and any inbox entry that can be moved are preserved under the package-owned catalog for diagnostics; they are not deleted. A device-tool upload may be owned by a different operating-system user and therefore remain in `inbox/` when the app cannot rename it. That retained entry is harmless because a valid native graph always wins and suppresses the bootstrap on later launches.

The bootstrap does not introduce another target kind or snapshot-mode session. After publication, the Engine opens the configured `Native_local_graph` normally and reports `Native_read_write`.

Create and import build a temporary catalog entry, restore and admit the copied database, write the snapshot UUID and source identity manifest, and atomically publish the directory and token mapping only after every step succeeds.

Interrupted temporary entries are never addressable by a token and may be garbage-collected later.

Resolution rejects symlinks, path escape, hard links to graph files outside the catalog, an inode or content identity substituted after registration, and a manifest which no longer matches the catalog entry.

After acquiring ownership and before SQLite open, the Engine revalidates the opened directory and database identity through descriptor-relative operations.

Every target is exclusive read-write. `Snapshot`, `Import_snapshot`, and `Native_local_graph` always acquire the target graph's owner lock before opening SQLite.

Snapshots are writable snapshots, while `Native_local_graph` remains disabled until the native gates pass.

There is no access-mode field and no read-only target or session.

The target classification is derived from locator state and the verified snapshot catalog rather than trusted from a caller-supplied mode label.

Tests may construct a temporary Logseq root only through the same snapshot helper or an explicitly test-only catalog capability.

For `Native_local_graph`, the Desktop CLI derives `graph_dir` only from `~/logseq/<graph-name>` and prints the canonical resolved directory in verbose or JSON graph information.

The stable CLI does not accept a native graph-root or graph-directory override.

The Bonsai startup configuration must carry an explicit target and application-support directory selected by the host or application policy.

On iOS, the Flutter host obtains `<app-data-dir>` from the platform, confines `graph_dir` beneath `<app-data-dir>/graphs/`, and encodes the canonical directory and graph name in the immutable startup envelope before Worker initialization.

For physical-device test data, the host or test harness first launches the app once so the app process creates its catalog and inbox directories, then uploads a same-name graph directory under `<application-support-directory>/logseq-db-worker/inbox/`. The next app launch performs the app-owned native bootstrap above. Test tooling must not upload directly into `<app-data-dir>/graphs`, because files copied by device tooling may retain ownership that prevents the app from creating the ownership database and other native sidecars.

## Shared protocol contract

`Protocol.request` is the only semantic request type used by the service and CLI.

Every request carries an independent protocol version and request ID.

Every mutation also carries a caller-supplied mutation UUID, expected graph basis, and caller-supplied UUIDs for newly created entities.

Persisted Logseq timestamps are Unix epoch milliseconds from an Engine-owned wall-clock dependency injected by each adapter.

If non-decreasing values are required within a session, the Engine clamps them against the last emitted epoch value and never persists a monotonic-clock tick.

A separate monotonic clock handles durations and timeouts, while tests inject deterministic epoch-millisecond and monotonic dependencies outside the public protocol.

The protocol version is independent of Logseq schema `65.33` and the physical storage format version.

```ocaml
type request =
  { api_version : int
  ; request_id : Uuid.t
  ; command : command
  }

and mutation_context =
  { mutation_id : Uuid.t
  ; expected_basis : int64
  }

and failure_phase =
  | Open
  | Execute

and failure =
  { request_id : Uuid.t
  ; phase : failure_phase
  ; basis : int64 option
  ; error : Error.t
  }

and response =
  | Succeeded of
      { request_id : Uuid.t
      ; basis : int64
      ; success : success
      }
  | Failed of failure
```

The concrete interface should use project-approved UUID and JSON types, but the semantic fields above are required.

The core `Protocol.failed` constructor is the only place that attaches a request ID and optional basis to an `Error.t`, and both adapters use it for open and execution failures.

Expected-basis preconditions provide retry safety without adding a second durable mutation ledger that cannot commit atomically with the graph.

Caller-supplied entity UUIDs keep create and insert identities deterministic across explicit application restarts.

A repeated create whose UUIDs already describe the requested final entities may return `Already_applied`.

A repeated request whose expected basis is stale and whose effect is not already present returns `Conflict` with the current basis and a bounded current projection.

Mutation IDs are deduplicated within a live engine session and are used for diagnostics, but they are not claimed as a durable cross-restart idempotency ledger.

Every continuation cursor is an opaque authenticated envelope containing the protocol version, a query-and-filter fingerprint, the graph basis, the last stable sort key, and expiry.

The adapter-owned catalog stores the cursor authentication key outside graph data, rotates it only at an explicitly versioned protocol boundary, and injects a deterministic test key for cross-adapter traces.

Decoding verifies canonical encoding, integrity, and expiry before it reads any cursor field.

A cursor whose basis or query fingerprint no longer matches returns `Conflict` rather than silently skipping or duplicating items across pages.

Differential tests compare decoded cursor semantics when production authentication bytes legitimately differ.

Every mutation resolves its complete selector set before planning, and one missing, ambiguous, duplicated, or wrong-kind selector rejects the whole request rather than mutating the resolvable subset.

Empty mutation selections are invalid unless a specific operation contract defines an idempotent no-op.

A caller that receives Worker `Cancelled`, `Shutdown`, transport loss, or process loss after an accepted mutation treats the result as uncertain even when the synchronous SQLite call could not be preempted.

The caller must refresh graph basis and all touched projections before deciding whether to retry, because the commit may have succeeded after cancellation won Worker result arbitration.

The first structural protocol slice is intentionally narrow enough to freeze as the following algebra.

```ocaml
type block_uuid = Uuid.t

type relative_position =
  | Before of block_uuid
  | After of block_uuid
  | First_child of block_uuid
  | Last_child of block_uuid

type insert_position =
  | Relative of relative_position
  | Replace_empty of block_uuid

type direction =
  | Up
  | Down

type indent_direction =
  | Indent
  | Direct_outdent

type block_tree =
  { uuid : block_uuid
  ; title : string
  ; children : block_tree list
  }

type structural_mutation =
  | Save_block of
      { block : block_uuid
      ; title : string
      ; context : mutation_context
      }
  | Insert_blocks of
      { roots : block_tree list
      ; position : insert_position
      ; context : mutation_context
      }
  | Move_blocks of
      { roots : block_uuid list
      ; position : relative_position
      ; context : mutation_context
      }
  | Move_up_down of
      { roots : block_uuid list
      ; direction : direction
      ; context : mutation_context
      }
  | Indent_outdent of
      { roots : block_uuid list
      ; direction : indent_direction
      ; context : mutation_context
      }
  | Delete_blocks of
      { roots : block_uuid list
      ; context : mutation_context
      }

type mutation_status =
  | Applied
  | No_change
  | Already_applied

type mutation_success =
  { status : mutation_status
  ; basis_before : int64
  ; basis_after : int64
  ; changed_uuids : block_uuid list
  ; changed_uuids_truncated : bool
  }
```

`roots` is always non-empty, UUIDs are unique within the request, and every string, tree depth, tree node count, root count, and encoded request size is bounded by constants frozen in `Protocol.mli` and its JSON fixtures.

`Insert_blocks` accepts recursive preorder trees and performs flattening only inside the shared planner, so the wire format cannot contain contradictory parent and level declarations.

`Replace_empty` is the only blank-target replacement form and requires exactly one existing structurally empty target, while no title-based heuristic silently converts another insert position into replacement.

`Save_block` changes title only in the structural slice, while collapse state and other patches require their own later typed variants and parity cases.

An identical `Save_block`, a boundary `Move_up_down`, and another oracle-proved semantic no-op return `No_change` without advancing basis.

An insert whose caller UUIDs already form the entire requested final tree may return `Already_applied`, while partial UUID reuse or a different final tree returns `Conflict`.

A move to its original position, a missing indent target, an outdent of a page root, a cycle, a wrong-kind anchor, an empty root list, a duplicate UUID, or any missing selector rejects the whole command with the operation-specific typed error and no transaction.

Successful `Applied` changes return the before and after basis plus a bounded changed-UUID projection, and `basis_after` advances exactly once for the atomic command.

The page and property rows below are research candidates rather than an implementable schema by themselves.

Task 1 must replace every candidate row with an exhaustive OCaml variant, versioned JSON example, selector rule, size bound, precondition, no-op rule, error set, and automatic-effect inventory before any production behavior begins.

The property value algebra must enumerate the pinned user-visible types `default`, `number`, `date`, `datetime`, `checkbox`, `url`, `node`, and `asset`, plus each admitted internal type, without a generic untyped JSON escape hatch.

## Read operation matrix

| Operation | Selector and input | Result | Required behavior | Slice |
|---|---|---|---|---|
| `Graph_info` | None. | Local graph UUID from `:logseq.kv/local-graph-uuid`, graph name, canonical graph directory, schema, basis, mode, and admission facts. | Never expose the RTC graph UUID, handles, or entity IDs. | Structural. |
| `Get_block` | Block UUID. | Bounded block projection. | Include UUID, title, parent, page, order, timestamps, refs, tags, and property summary. | Structural. |
| `Get_page` | Page UUID or typed name and kind. | Page projection. | Reject ambiguous name and kind matches. | Structural. |
| `Get_children` | Parent UUID, limit, cursor. | Ordered direct children. | Follow Logseq order for valid graphs, use UUID only to make invalid duplicate-order projections deterministic, and return a continuation. | Structural. |
| `Get_page_tree` | Page UUID, depth, limit, cursor. | Bounded preorder tree. | Enforce depth, item, and byte budgets. | Structural. |
| `Get_ancestors` | Block UUID, limit. | Nearest-first ancestors. | Detect and reject cycles instead of looping. | Structural. |
| `Get_siblings` | Block UUID, limit, cursor. | Ordered siblings plus current position. | Use the same ordering module as writes. | Structural. |
| `List_pages` | Kind filter, limit, cursor. | Page summaries. | Preserve UUID identity and typed page kinds. | Page. |
| `List_tags` | Limit and cursor. | Tag or class summaries. | Use typed relations rather than title parsing. | Property. |
| `List_properties` | Scope, limit, cursor. | Property schema summaries. | Return qualified identifiers and value contracts. | Property. |
| `List_tasks` | Typed filters, limit, cursor. | Task projections. | Use DB graph task properties rather than Markdown TODO text. | Property. |
| `Get_references` | UUID, direction, limit, cursor. | Stable referring or referred UUIDs. | Bound cardinality and preserve relation kind. | Property. |

Arbitrary raw pull or Datalog query is not part of the stable service contract.

Application feed orchestration issues at most one `Get_page_tree` request at a time. Each response advances the retained page queue and emits the next request, so a 31-day initial feed cannot fill the bounded serial Worker request or response lane.

## Write operation matrix

| Operation | Stable input | Core derived behavior | Primary parity oracle | Slice |
|---|---|---|---|---|
| `Save_block` | UUID, complete replacement title, and mutation context. | Protect UUID and built-ins, update timestamps, rebuild refs and tags, clean orphan relations, and touch page. | `outliner/core.cljs`, worker pipeline tests. | Structural. |
| `Insert_blocks` | Non-empty recursive block trees with UUIDs, explicit relative or `replace_empty` position, and mutation context. | Flatten internally, generate orders, assign parent and page, remap internal refs, write stubs, and insert or replace atomically. | Outliner core and CLI add tests. | Structural. |
| `Move_blocks` | Root UUIDs, target UUID, `before`, `after`, `first_child`, or `last_child`, mutation context. | Normalize roots, preserve order, reject cycles and invalid targets, and rewrite descendant page on cross-page moves. | Outliner core and semantic route tests. | Structural. |
| `Move_up_down` | Root UUIDs, direction, mutation context. | Resolve contextual target and delegate to the same move planner. | Outliner core tests. | Structural. |
| `Indent_outdent` | Continuous root UUIDs, direction, mutation context. | Apply current direct semantics, expand a collapsed left target only when appending after its existing last direct child, preserve the current no-child branch without clearing collapse, and reparent right siblings on outdent. | Outliner core tests. | Structural. |
| `Delete_blocks` | Root UUIDs and mutation context. | Deduplicate descendants, reject built-ins, hard-delete subtrees, and clean refs and special relations. | Outliner core and delete tests. | Structural. |
| `Create_page` | Title, kind, mutation context, and caller UUID only for a non-journal page. | Apply the deliberately narrow v1 collision policy, derive journal UUID from journal day and reject a conflicting supplied UUID, reject an existing or recycled identity instead of restoring or converting it, and create no namespace parents implicitly. | Outliner page tests plus explicit restriction fixtures. | Page. |
| `Rename_page` | Page UUID, title, and mutation context. | Delegate to the `Save_block` pipeline, normalize `:block/name`, preserve UUID-backed aliases, clean title-derived relations, and reject ambiguity. | Outliner page tests. | Page. |
| `Delete_page` | Page UUID and mutation context. | Recycle ordinary pages, clear today's journal, and apply class or property rules. | Outliner page and recycle tests. | Page. |
| `Restore_recycled_page` | Recycled page UUID and mutation context. | Restore a valid recorded parent and reuse a recorded order when present; restore an originally top-level page as top-level with no order, and do not repair order collisions. | Outliner recycle tests. | Page. |
| `Permanently_delete_recycled_page` | Recycled page UUID and mutation context. | Delete only an eligible recycled page root and clean relations. | Outliner recycle tests. | Page. |
| `Upsert_property` | Existing qualified ident or UUID resolved to ident, or a new qualified ident or name plus schema, and mutation context. | Derive a new property block UUID from its ident, validate type, cardinality, identity, existing values, and built-in constraints, and do not expose an independent caller UUID or page conversion. | Outliner property tests. | Property. |
| `Set_property` | Block UUID, property ident or UUID, typed value, and mutation context. | Resolve and validate typed values, refs, self-reference, and idempotent equality. | Outliner property tests. | Property. |
| `Remove_property` | Block UUID, property ident or UUID, and mutation context. | Apply status, default, extends, alias, and placeholder semantics. | Outliner property tests. | Property. |
| `Batch_set_property` | Block UUIDs, property, one typed value with `append` or a complete typed collection with `replace`, and mutation context. | Apply one scalar to every target for append or one complete collection to every target for replace, matching Logseq's scalar add-one and collection replace behavior and validating every target. | Outliner property tests plus explicit adapter fixtures. | Property. |
| `Batch_remove_property` | Block UUIDs, property, and mutation context. | Match canonical batch removal, including status handling and cleanup of generated value blocks that have no remaining referrers. | Outliner property tests. | Property. |
| `Manage_closed_values` | Property and value UUIDs plus explicit action. | Add, update, associate, or delete validated closed values. | Outliner property tests. | Property. |
| `Manage_class_property` | Class UUID, property ident, explicit add or remove, and mutation context. | Maintain typed class-property relations and defaults. | Outliner property tests. | Property. |

The first release candidate must complete the structural slice before enabling the page or property slice.

The pinned recycle primitive can select a recycled page or block root, while `Restore_recycled_page` and `Permanently_delete_recycled_page` are deliberate protocol restrictions that reject non-page roots.

Each later slice must be activated only after its complete accepted-input differential corpus passes in both directions.

`Apply_template`, `Batch_import_edn`, `Toggle_reaction`, raw `Transact`, split, merge, undo, redo, sync, and RTC remain explicit direct protocol non-goals for this plan.

A direct protocol non-goal does not permit a supported operation to omit an automatic canonical main-graph effect.

V1 parity is defined over the accepted canonical main-graph domain.

Derived search and vector projections are independently invalidated and rebuilt rather than transactionally reproduced.

The client-operation, undo, checksum, and sync-history listener is an explicit non-parity surface which the worker does not append.

For every supported operation, Task 1 must inventory all observable canonical main-graph hooks in the pinned pipeline, including command or template interpretation, `created-by`, asset relations, references, page or tag conversion, and transaction metadata.

The implementation must either reproduce each automatic canonical main-graph effect or reject the graph or input with `Unsupported_semantics` before staging, and the differential oracle must cover that branch.

Separate integration gates cover sidecar rebuild and client-operation history coexistence rather than treating them as canonical graph datoms.

## Outliner implementation model

Each public mutation is parsed into a typed command and planned against one immutable current database value.

An outliner planner may query the current database and produce a `Mutation_plan`, but it may not access SQLite or install state.

`Mutation_plan` contains stable semantic intent, concrete DataScript operations, touched UUIDs, invalidated projections, and expected derived effects.

Each mutation carries current-compatible local transaction metadata, a stable transaction UUID derived from the request, canonical operation metadata, and the derived `:block/tx-id` updates required by the pinned pipeline.

The local-only engine does not create RTC client-operation rows or claim persisted Logseq undo history.

The engine applies the complete plan to a non-persisting staged database and runs graph and operation validation against `db_after`.

Only a validated plan may enter the storage commit path.

The storage session persists the exact staged transaction as one tail or compaction batch and either returns successful completion or raises a fatal persistence error.

The engine installs `db_after` and advances its basis only after a successful commit.

This boundary mirrors Logseq's temporary-connection staging and single real-connection commit without copying UI or DOM behavior.

### Tree and ordering invariants

Every non-page block has a UUID, parent, page, valid fractional order, title, created timestamp, and updated timestamp.

The parent graph is acyclic.

Every descendant's `:block/page` matches its containing page.

Logseq reads sibling order by `:block/order`.

The worker may use `(block/order, block/uuid)` only as a deterministic projection rule for already-invalid duplicate-order data, and parity tests must prove that it does not change valid graphs.

All new order values come from one port of the pinned Logseq fractional-indexing implementation.

Duplicate-order repair is limited to touched order additions in the sync or rebase-style rule that requires it, and is not an unconditional local admission or mutation repair.

No operation writes legacy `:block/left`.

### Reference and title pipeline

`Save_block` is not complete until it matches current title-derived relation behavior.

The reference planner must cover block UUID references, page references, tags, links, property keys and values, scheduled and deadline journal references, private and non-reference exclusions, aliases, and self-reference rules.

It must retract orphaned references and tags and preserve relations that remain derivable.

The pipeline must update affected block and page timestamps using the Engine clock, with a deterministic dependency substituted only by tests and the oracle harness.

The first structural slice cannot claim Logseq parity if it merely writes `:block/title`.

### Delete semantics

`Delete_blocks` hard-deletes selected root subtrees because that is the current pinned Logseq behavior.

If both an ancestor and descendant are selected, only the ancestor is treated as a delete root.

Page recycle behavior is not reused for ordinary block deletion.

Changing block deletion to recycle would be a separate product decision and a deliberate divergence from the pinned oracle.

### Property semantics

Properties are typed graph relations and are not serialized as file-graph `key:: value` text.

The public selector accepts a qualified ident or UUID.

A title convenience selector may exist only when it resolves uniquely, otherwise it returns `Ambiguous_selector`.

Batch mode is explicit as `replace` or `append` rather than inferred from whether JSON happens to contain a scalar or collection.

That explicit mode is a protocol clarification which the adapter maps to current Logseq scalar add-one or collection replace semantics.

Single-property planners must preserve Logseq's special handling for status, default values, class extension, aliases, closed values, and empty placeholders.

Batch removal follows its narrower canonical behavior and must not be described as repeated single removal unless it is deliberately implemented that way and differentially proved.

## Admission policy

Admission runs before a writable engine becomes Ready and returns a complete typed diagnostic list.

The storage layer first verifies the exact `kvs(addr, content, addresses)` table contract and integer address domain.

It performs bounded startup validation of root address `0`, tail address `1`, and the three index-root payloads, then restores the immutable DataScript database without mutation.

It verifies `:logseq.kv/db-type = "db"` and requires the schema-version value to parse to `{ major; minor }` with `(major, minor) >= (65, 33)`.

Startup admission reads the schema from root metadata and verifies only that the required `db/ident`, `block/uuid`, `block/title`, `block/parent`, `block/page`, `block/order`, and `kv/value` attributes exist.

Startup admission does not enumerate block datoms, validate every attribute value, detect parent cycles, or search for duplicate sibling orders. Structural mutation planners reject invalid requested operations, and mutations that can change the tree run complete validation against their staged `db_after` before persistence.

It permits dynamic user property attributes because those are part of the DB graph model.

It rejects missing or malformed startup metadata, an older schema, unsupported local identity, and incompatible runtime modes. A newer schema continues when the startup metadata and requested semantics remain within the pinned operation matrix.

It permits `:logseq.kv/local-graph-uuid`, a client-operations database, and pending local rows.

It distinguishes the mere existence of an RTC-related `:db/ident` from a non-nil `:kv/value` on that entity.

It rejects when `:logseq.kv/graph-remote?` has the Boolean value `true`.

A non-nil `:logseq.kv/graph-uuid` or client-operations `sync_meta.graph-uuid` is RTC identity in the pinned runtime, and its presence while the remote flag is not true is contradictory and returns `Ambiguous_sync_state`.

It also rejects a present non-Boolean remote flag or another sync identity combination which the Task 1 classifier corpus proves malformed, rather than guessing.

It rejects unsupported Transit values before enabling writes.

It rejects a graph whose lock state cannot be classified safely.

The package performs no graph migration, new-graph initialization, schema repair, file-graph import, or compatibility fallback.

A change to the minimum supported schema or any newly supported value/operation semantics requires an explicit dependency-pin update, new fixtures, a revised operation matrix, and a complete accepted-main-graph parity run. A graph whose schema is newer than the pinned oracle may be admitted only when the codec proves lossless reachability and the requested operation uses semantics already covered by the pinned operation matrix.

## Storage and durability contract

`logseq_db_worker` owns the only production Logseq SQLite codec and storage session used by this repository.

`Logseq_sqlite_codec` maps the pinned DataScript storage payloads to and from Logseq Transit content plus child-address JSON.

`Logseq_sqlite_storage` owns the exact `kvs(addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)` physical adapter.

`Storage_session` exposes an abstract session, restore, `stage_transact`, `commit_staged`, checkpoint, reachability GC, and close operations to the rest of the core library.

It must use one long-lived SQLite connection with prepared statements.

The Engine holds an immutable `Datascript.db` and an explicit transaction tail and must never mutate a stored `Datascript.conn` through the current `Conn.transact` path.

The local session stages against a non-persisting database value, receives `db_after` and `tx_data`, and invokes the pinned `Storage.store_tail` or `Storage.store` path only from `commit_staged`.

The intended pinned-API flow is the following.

```text
session.db with persistence detached
  -> Datascript.transact
  -> tx_report { db_after; tx_data }
  -> calculate next tail or compaction batch
  -> local storage callback performs one SQLite transaction
  -> install db_after and next tail only after success
```

The local storage callback receives the complete DataScript address-and-payload list and encodes and commits that list without exposing it outside the core library.

`stage_transact` must compute `db_after`, transaction data, the next tail, and any compaction page plan without changing the Engine database, the session tail, or SQLite.

`commit_staged` must execute every address change under one `BEGIN IMMEDIATE` transaction and either commit the complete plan or roll it back.

Only a successful commit receipt authorizes the Engine to install `db_after` and the session to install the next tail or compaction state.

A staged value is single-use, bound to the session identity and original basis, and cannot be committed or installed twice.

Persisting through the current `Datascript.transact` or `Conn.transact` paths is explicitly forbidden for production graph mutations because their store timing does not provide this install-after-commit contract.

Task 2 must prove that the exact pinned public API can compile this detached staging flow before mutation behavior is implemented.

Failure of that proof is a stop condition and does not authorize an upstream component, dependency upgrade, or fallback storage path.

Every open must set and verify `PRAGMA journal_mode = WAL`, `PRAGMA synchronous = FULL`, a bounded busy timeout, and the approved exclusive locking mode before admission becomes Ready.

Compaction must atomically write every changed B-tree page, each page's exact child-address JSON, root address `0`, and the cleared tail at address `1`.

Reachability garbage collection remains a separate operation under the same exclusive owner lock.

Task 1 freezes the GC triggers at `256` unreachable physical addresses or `16 MiB` of SQLite logical-size growth since Engine open or the last successful GC.

At least `256` unreachable addresses triggers GC, while `255` does not; at least `16 MiB` of logical-size growth triggers GC even when fewer than `256` addresses are unreachable.

When either threshold is reached, GC must create or cryptographically verify a recovery backup, derive reachability from the committed root, revalidate ownership, and delete only unreachable addresses in its own SQLite transaction before the pending graph mutation commits.

After a successful GC, the logical-size growth baseline advances to the current SQLite page count and page size; a no-op GC caused by file growth therefore does not repeat on every later mutation.

A GC persistence failure follows the same fatal application policy as a graph mutation write failure.

The codec must preserve the semantic type and value of every admitted Transit item, but it need not preserve Transit cache shorthands or byte-for-byte JSON spelling.

A raw preflight scanner must detect every unknown tag and unsupported primitive before any decoder can coerce it into a lossy OCaml substitute.

The engine does not attempt to classify, recover, or continue after a persistence failure.

Any failure reported by `BEGIN`, an address write, or `COMMIT` moves the Engine to `Fatal` immediately.

The Bonsai application renders its fatal error state, and only a full application restart may create a new Engine and reopen the graph.

A successful commit installs the staged database and returns success with the new basis.

Close must run a WAL checkpoint with `TRUNCATE`, inspect the result, finalize statements, and close the database.

A mutation is reported as durable only after SQLite reports successful `COMMIT` under the verified `synchronous = FULL` policy.

Fault-injection acceptance covers callback failures and process termination on the supported filesystem, while sudden power-loss guarantees remain exactly those provided by the selected SQLite and filesystem configuration and are not extended by this package.

No code may use a raw file copy as a backup of a live WAL database.

Before the first mutation in any read-write session, `Backup` must use the SQLite backup API to create a consistent recovery copy, and backup failure must block the write.

Native mode additionally binds the backup manifest to the owner generation before sidecar invalidation begins.

## Ownership contract

A verified snapshot is created through `Snapshot.create`, stored under a package-controlled snapshot root, and tied to both its manifest and catalog token.

Every target acquires an owner primitive before opening a mutable DataScript session.

A verified snapshot uses a package-owned nonblocking advisory file lock held by an open descriptor for the session, so the kernel releases that primary lock on process exit.

It also atomically creates a current-format `db-worker.lock` interop sentinel while writable so a pinned Logseq process refuses to open the snapshot concurrently.

The snapshot phase never removes an unexpected or stale interop sentinel and therefore never enters the pinned runtime's read-then-unlink replacement race.

After a crashed writer, `Snapshot.recover` creates a new catalog entry and token through a consistent SQLite backup while leaving the original snapshot and sentinel untouched.

A native local graph uses the coordinated canonical `db-worker.lock` protocol described below.

Before every snapshot SQLite mutation, backup, checkpoint, and release, the Engine proves its advisory descriptor remains held and revalidates the sentinel identity.

Snapshot release unlinks the sentinel only if its graph identity, PID, and lock UUID still match, then releases the advisory descriptor.

This rule prevents two CLI or Worker instances or a pinned Logseq process from writing the same snapshot concurrently and prevents a package writer from bypassing native Logseq ownership by changing a mode label.

The native lock preserves the pinned `repo` field for interoperability, records the exact validated `graph_name` as that identity, and also records the current PID, a random lock UUID, and `owner-source = unknown`.

An active PID, a PID that cannot be inspected because of permissions, malformed metadata, an unreadable lock, or an unclassifiable process state fails closed.

Only a lock whose positive PID is provably absent may enter stale cleanup.

The coordinated protocol must add a generation guard or another cross-runtime primitive which prevents the current read-then-unlink replacement race, and native writes remain disabled if that primitive cannot be shared with Logseq.

Before every native SQLite mutation, backup, sidecar invalidation, checkpoint, and release, the Engine re-reads and verifies graph identity, PID, and lock UUID.

Any missing or changed lock terminalizes the engine before further graph writes.

Native release uses the same coordinated generation guard and removes the lock only when the on-disk identity still matches the Engine identity.

The coordinated Logseq test must prove that Desktop and the Logseq CLI refuse to start another writer while this owner is alive and recover normally after release.

The engine does not advertise an HTTP health endpoint, enter Logseq's reusable daemon server list, or pretend another client can attach to it.

## Derived sidecar policy

The main graph database is canonical, while search and vector indexes are reconstructable projections.

The native owner must use a Logseq-coordinated invalidation contract rather than silently leave those projections usable after a direct write.

Native writes remain disabled until the coordinated Logseq change provides independent durable invalidation and rebuild state for both FTS and vector projections.

This is a target contract, not an API currently exposed to OCaml.

Resetting only the FTS `user_version` and truncating a vector index only when it is already open is insufficient.

The coordinated Logseq change must freeze the exact sidecar paths and a callable invalidation entrypoint which durably records both projection states, or equivalent independent durable markers which the next capable pinned Logseq open is guaranteed to consume, rather than duplicating guessed SQL in this package.

The engine first creates the consistent main-database backup, then invalidates derived sidecars while the graph owner lock is held, and only then starts the main write.

If invalidation fails, the main mutation does not start.

The next pinned Logseq open must rebuild every projection it can serve and leave any unsupported projection durably invalid for a later capable runtime.

The integration suite must cover a vector-incapable reopen followed by a vector-capable reopen and prove that the first process cannot consume state which prevents the second from rebuilding vector data.

The client-operations database is opened for ordinary local graphs, and current local transactions can create pending rows even before the graph is remote.

Admission therefore does not classify by the store's presence, by pending rows alone, or by the mere presence of RTC-related KV entities.

Remote classification and native-write capability are separate decisions.

The Engine never deletes, rewrites, or appends client-operation, undo, checksum, or sync history in this local-only scope.

A verified snapshot contains the backed-up canonical main graph and package manifest but deliberately omits copied client-operation, search, and vector sidecars, so snapshot write mode is explicitly no-sync and no-persisted-undo while the package owns it.

Native read-write admission treats initialized sync checksums or transaction counters, persisted history, and pending rows as capability evidence rather than remote identity.

Before each such native state is admitted, the coordinated cross-runtime suite must prove checksum continuity, pending replay or rebase behavior, existing undo behavior, the next pinned Logseq local mutation, and later sync enablement remain correct after an external main-database commit.

If that coexistence contract is not proved for the observed state, native read-write admission returns `Unsupported_semantics` rather than deleting or rewriting the client-operations store.

## Engine lifecycle and errors

`Engine.t` is abstract and owns the graph locator, admission facts, ownership handle, backup state, SQLite storage session, current immutable DataScript database, current basis, and bounded mutation cache.

The lifecycle states are `Opening`, `Ready`, `Fatal`, and `Closed`.

`Engine.open_` resolves and classifies the target, verifies snapshot provenance when present, acquires the appropriate owner primitive for every read-write request, opens storage, restores the database, runs admission, and returns either a Ready engine or an `Error.t` which has no transport request metadata.

Any failure after owner acquisition closes partial resources and releases only the owner acquired by that attempt before returning the typed open error.

`Engine.execute` handles both reads and writes through one request dispatcher.

`Engine.close` is idempotent only for a completed close, and a close failure transitions the Engine to `Fatal`.

The CLI maps a close failure to exit code `5` after writing a bounded safe diagnostic.

The Bonsai adapter raises a bounded safe close diagnostic from `shutdown`, allowing the Worker runtime to record `Session_callback_failed`.

It does not claim that `App.create_with_worker ~trace` receives Worker shutdown diagnostics because the service has no access to that Driver trace sink.

If persistent close diagnostics are required, the service constructor must receive an explicit Worker-domain-safe diagnostic sink.

Application destruction is not guaranteed to pump a terminal event back to the UI, so close diagnostics are not promised as an ordinary UI response and a failed lock release remains fail-closed for the next open.

Expected typed errors include `Invalid_request`, `Unsupported_api_version`, `Graph_not_found`, `Graph_locked`, `Unsupported_schema`, `Remote_graph`, `Ambiguous_sync_state`, `Unsupported_value`, `Unsupported_semantics`, `Corrupt_storage`, `Not_found`, `Ambiguous_selector`, `Duplicate_selector`, `Built_in_protected`, `Invalid_tree`, `Invalid_order`, `Invalid_position`, `Conflict`, `Response_too_large`, `Storage_busy`, and `Closed_session`.

Persistence failures are intentionally absent from `Error.t` because they terminate the session and surface through the adapter's fatal-error path rather than `Protocol.Failed`.

Every `Error.t` includes a stable code, safe message, and bounded structured details.

`Protocol.Failed` attaches the incoming request ID and current basis when known, which lets the same open or execution error participate in CLI and Worker responses without making Engine startup depend on a request.

SQLite paths, raw Transit payloads, database handles, and unbounded exception text are excluded from ordinary protocol errors.

## Bonsai service adapter

`logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.mli` exposes a constructor for one typed `Worker.Service.t`.

The service constructor captures no open database, mutable DataScript value, or SQLite handle on domain 0.

`App.create_with_worker` runs `decode_config` on domain 0, so that callback performs only bounded immutable startup decoding and validation within the framework application-payload budget.

The host must create and canonicalize the absolute application-support directory before startup.

The service passes it through `Worker.Service.create ~data_directory`, requires `Worker.Session_context.data_dir = Some _`, and adapts that confined Eio capability to the snapshot catalog.

Failure to resolve or open this directory occurs before `init` and is therefore a framework `Session_startup_failed`, not an `Open_failed` protocol response.

Graph locator resolution, ownership acquisition, SQLite open, DataScript restore, and admission run in Worker `init` on the Worker Domain.

Request-specific reads, first-write backup, native sidecar invalidation, and mutations run from Worker `handle` through `Engine.execute`, still entirely on the Worker Domain.

The adapter state is `Ready of Engine.t | Open_failed of Error.t`.

Worker `init` opens one engine on the Worker Domain using decoded `Config.t` and returns `Ok (Open_failed error)` for expected locator, ownership, storage, or admission failures.

Worker `init` uses its framework-level `Error string` only for an invalid callback invariant or another failure which cannot be represented safely as `Error.t`.

Worker `handle` calls `Engine.execute` in `Ready`, or wraps the saved open error with the incoming request ID in `Open_failed`, and returns `Ok (Protocol.response)` for both cases.

If `Engine.execute` raises `Fatal_storage_error`, Worker `handle` lets the bounded safe exception escape, the Worker runtime terminalizes the session, and the application renders its fatal error state.

The adapter must not convert that exception into `Error string` or `Protocol.Failed`, because either conversion would leave a transport or Engine session appearing reusable.

An expected graph-open failure therefore leaves the Worker transport ready, and the initial UI component must send `Graph_info` or another status request and render its `Protocol.Failed` response instead of waiting for application construction to fail.

Worker `shutdown` closes the engine and releases only its own graph lock in `Ready`, while `Open_failed` needs no Engine close.

The service uses `Serial` and one bounded push topic.

Successful mutations emit `Graph_invalidated { basis; changed_uuids; truncated }` after commit.

The push is a latest-wins hint, and the UI refreshes through a basis-aware read rather than treating pushes as a lossless log.

The changed UUID count, string bytes, and estimated immutable heap payload are bounded by the adapter because the Worker runtime does not business-encode typed OCaml push values or impose a byte limit.

Pushes become visible only during a later accepted foreground pump, responses drain before pushes, and multiple pushes for one topic may collapse to the latest value.

The UI must handle `Worker.send` results `Full`, `Not_ready`, and `Stopping` without assuming a request was accepted.

No file in the `bonsai_flutter` repository is modified by this plan.

The current immutable iPhoneOS closure already contains the pinned `datascript-ocaml-native`, `datascript-ocaml-native.sqlite`, `datascript_ocaml`, `sqlite3`, Transit, EDN, Yojson, persistent-sorted-set, time, Eio, and Unicode dependencies required by the local core and Bonsai adapter.

The application consumer must keep `(features sqlite)` in `bonsai-flutter.sexp` so the Apple target permits and links system SQLite.

The local codec is part of `logseq_db_worker`, so no new DataScript opam component, supported-closure entry, SDK repository generation, or toolchain reinstall is required.

The CLI library and Cmdliner must remain unreachable from the Bonsai and iPhoneOS dependency closure.

A future DataScript pin change or new third-party dependency requires a separate dependency and Apple-closure plan rather than silently expanding this task.

## CLI adapter

The installed executable name is `logseq-db-worker`.

Every graph read or write subcommand constructs a `Protocol.request`, calls `Engine.execute`, and renders the same response used by the Worker.

Snapshot create and import are pre-Engine catalog operations exposed by the same core `Snapshot` module to both adapters, and they do not contain graph query or outliner logic.

A one-shot CLI open failure is wrapped with that command's request ID as the same `Protocol.Failed` response that the Worker would produce from `Open_failed`.

An NDJSON session mode accepts and emits the exact versioned protocol for differential tests and automation.

NDJSON retains `Open_failed` as session state and returns the same typed open failure for each well-formed request instead of inventing an uncorrelated startup response.

The CLI contains no direct DataScript query, transaction, order, page, or property logic.

If engine capabilities require Eio, CLI `main` owns exactly one `Eio_posix.run`, injects the resulting environment into `Engine.open_`, and closes through `Fun.protect` in both one-shot and NDJSON modes.

Representative commands are shown below.

```sh
logseq-db-worker snapshot create --source-graph-name notes --format json
logseq-db-worker --graph-name notes graph info --format json
logseq-db-worker --snapshot-token "$SNAPSHOT_TOKEN" graph info --format json
logseq-db-worker --snapshot-token "$SNAPSHOT_TOKEN" block get --uuid "$BLOCK_UUID" --format json
logseq-db-worker --snapshot-token "$SNAPSHOT_TOKEN" block children --uuid "$BLOCK_UUID" --limit 50 --format json
logseq-db-worker --snapshot-token "$SNAPSHOT_TOKEN" block save --request request.json --format json
logseq-db-worker --snapshot-token "$SNAPSHOT_TOKEN" session --input ndjson
```

Exit code `0` means the requested command or NDJSON transport completed.

Exit code `2` means CLI syntax or local request decoding failed before engine execution.

Exit code `3` means a one-shot response is `Protocol.Failed` with phase `Execute` after applying the precedence below.

Exit code `4` means a one-shot response is `Protocol.Failed` with phase `Open` after applying the precedence below.

Exit code `5` means a fatal persistence or storage-lifecycle failure occurred.

Classification is disjoint and ordered: `5` wins for a fatal write, commit, checkpoint, or close failure; otherwise `4` applies to phase `Open`; otherwise `3` applies to any other typed graph or dispatched catalog failure; and `2` occurs only before Engine or catalog operation dispatch.

NDJSON mode emits typed failures per request and exits nonzero only when the session itself cannot continue.

Human output is a projection of the typed response and is never parsed internally by tests that require protocol stability.

## Current application integration

The package can be built and tested independently before the current journal application consumes it.

Actual application integration must replace `Journal_worker.service` because one `App.t` can own only one Worker service.

The application startup contract must supply an application-support directory, one access-qualified target, and the closed compatibility profile.

A snapshot target contains only a catalog token, while a native target contains the validated graph name and the canonical graph directory derived by the platform adapter.

On Desktop, the adapter expands `~`, resolves `~/logseq/<graph-name>`, and rejects a result outside the canonical `~/logseq` base.

On iOS, the adapter obtains `<app-data-dir>` from the native platform channel, resolves `<app-data-dir>/graphs/<graph-name>`, and rejects a result outside the canonical `<app-data-dir>/graphs` base.

Neither platform exposes a graph-directory text field or accepts an arbitrary path through the application startup payload.

The graph selector and permission UX are product decisions outside the storage package, but the host must resolve them before Worker startup.

The new startup envelope replaces the old app-private store selection rather than supporting both formats.

The application maps graph responses into bounded journal UI projections without moving graph rules back to domain 0.

Once the graph-backed flow reaches parity, obsolete app-private storage, schema, path, repository, worker, recovery, and their dedicated tests are removed in the same integration change.

The authoritative architecture document must be updated in that change to replace the app-private-store decision with the admitted Logseq graph ownership model.

## Detailed implementation plan

### Task 0: Confirm decisions, authorization, and a clean baseline

Files:

- Review `docs/agent-guide/002-logseq-db-worker.md` and record approved decisions in the implementation task.

- Reconcile existing modifications in `app/`, `test/`, `flutter/`, and the opam manifests before overlapping edits.

- Update the current pin assertion only as a separate acknowledged baseline fix if it is still stale.

Steps:

1. Confirm exact-file compatibility, DB-graph-only scope, minimum schema `65.33`, package-created snapshots, local-only writes, the Desktop and iOS graph-directory contracts, block hard delete, direct outdent, and the operation slices.

2. Confirm that `logseq_db_worker` owns one local codec and staged atomic session against the exact pinned `datascript-ocaml` commit, with no upstream component and no generic-store fallback.

3. Confirm that native ownership coordination and sidecar invalidation may change the sibling Logseq repository if required.

4. Obtain explicit permission to modify Dune files in this repository and any Dune file required by the separately coordinated Logseq interop worktree.

5. Approve the remote value-level classifier, every automatic-effect exclusion, and the proposed boundedness and performance budgets.

6. Record `git status --short` and the three dependency commits before implementation.

7. Create or verify a detached clean oracle worktree at `../logseq-oracle-4f21d068` and reserve a separate `../logseq-worker-interop` worktree for coordinated tests and runtime changes.

8. Make every oracle entrypoint reject tracked, staged, or untracked content in the oracle worktree, not merely a mismatched HEAD.

9. Run the current repository test baseline without changing code.

```sh
git -C ../logseq worktree add --detach ../logseq-oracle-4f21d068 4f21d068aed43bb2ea5823247cae73ecdd8d60f8
git -C ../logseq worktree add -b codex/logseq-db-worker-interop ../logseq-worker-interop 4f21d068aed43bb2ea5823247cae73ecdd8d60f8
test -z "$(git -C ../logseq-oracle-4f21d068 status --porcelain=v1 --untracked-files=all)"
opam exec -- dune runtest
```

Expected result: Existing tests pass, or every pre-existing failure is recorded separately from the new package.

Stop condition: Do not begin implementation if relevant working-tree changes are unexplained, Dune authorization is absent, or a decision gate changes the architecture in this plan.

### Task 1: Freeze the protocol and oracle corpus

Files:

- Create `logseq_db_worker/lib/config.mli`.

- Create `logseq_db_worker/lib/error.mli`.

- Create `logseq_db_worker/lib/graph_types.mli`.

- Create `logseq_db_worker/lib/protocol.mli`.

- Create `logseq_db_worker/lib/engine.mli`.

- Create `logseq_db_worker/test/fixtures/protocol/`.

- Create `logseq_db_worker/test/fixtures/expected/`.

- Create `logseq_db_worker/tool/logseq_oracle.cljs`.

Steps:

1. Encode the configuration, snapshot token, selector, read, structural mutation, page mutation, property mutation, response, cursor, push, open-error, and execution-error contracts from this plan.

2. Keep every DataScript, SQLite, numeric entity ID, and ownership type out of the public interfaces.

3. Replace every page and property candidate row with an exhaustive OCaml algebra and versioned JSON fixtures that define selectors, fields, value types, request limits, preconditions, no-op behavior, conflict outcomes, and errors.

4. Define explicit request, response, collection, depth, title, UUID-count, changed-UUID, cursor-basis, and performance budgets.

5. Freeze a value-level remote classifier which rejects `graph-remote? = true` and contradictory or malformed sync identity, while proving ordinary local client-operation and RTC-related metadata admissible.

6. Inventory every automatic canonical main-graph pipeline effect triggered by each supported operation and mark each as implemented or as a typed pre-stage `Unsupported_semantics` rejection, while recording derived sidecars and client-operation history as separate integration gates.

7. Make the oracle verify the supplied Logseq repository HEAD against the exact expected commit, open the graph through `frontend.worker.db-core`, and invoke `:thread-api/apply-outliner-ops` through that initialized worker path.

8. If a test harness cannot invoke that route directly, it must install the exact worker transaction pipeline and admitted listeners through the same initialization path before calling `apply-ops!`; an outliner-only connection is not a valid worker oracle.

9. Emit a canonical stable JSON graph projection and use the pinned tests as case and assertion sources, while generating each reference output by running the oracle rather than expecting the test suites to emit goldens.

10. Store the Logseq commit, schema version, deterministic Engine clock, deterministic UUID inputs, and normalization rules beside each golden.

11. Preserve UUID and order in comparisons, inject them wherever the reference API permits, and normalize only declared nondeterministic addresses, transaction IDs, or clock values.

12. Source cases from `deps/outliner/test/logseq/outliner/`, `src/test/frontend/worker/`, `src/test/logseq/cli/command/`, `deps/db-sync/test/logseq/db_sync/`, and its parent-order rebase fixtures.

Verification:

```sh
pnpm --dir ../logseq-oracle-4f21d068/deps/outliner test
pnpm --dir ../logseq-oracle-4f21d068/deps/db test
pnpm --dir ../logseq-oracle-4f21d068/deps/db-sync test
pnpm --dir ../logseq-oracle-4f21d068/cli test
cd ../logseq-oracle-4f21d068
bb dev:test -n frontend.worker.db-core-test
bb dev:test -n frontend.worker.pipeline-test
bb dev:test -n frontend.worker.undo-redo-test
bb dev:test -n frontend.worker.db-sync-test
bb dev:test -n logseq.cli.command.add-test
bb dev:test -n logseq.cli.command.update-test
bb dev:test -n logseq.cli.command.remove-test
bb dev:test -n logseq.cli.command.upsert-test
cd ../logseq_journal
test -z "$(git -C ../logseq-oracle-4f21d068 status --porcelain=v1 --untracked-files=all)"
pnpm --dir ../logseq-oracle-4f21d068 db-worker-node:compile
pnpm --dir ../logseq-oracle-4f21d068/deps/db exec nbb-logseq ../../../logseq_journal/logseq_db_worker/tool/logseq_oracle.cljs generate --expected-logseq-commit 4f21d068aed43bb2ea5823247cae73ecdd8d60f8 --output ../../../logseq_journal/logseq_db_worker/test/fixtures/expected/oracle-worker-route-smoke.json
opam exec -- dune exec ./logseq_db_worker/tool/compare_canonical_graphs.exe -- --fixtures logseq_db_worker/test/fixtures/expected
```

Expected result: The pinned Logseq oracle tests pass before their behavior is used as the OCaml target.

### Task 2: Add build-only package scaffolding and write the complete RED suite

Files:

- Modify `dune-project` to declare the second package.

- Create root `logseq_db_worker.opam` and generated `logseq_db_worker.opam.locked`.

- Create `logseq_db_worker/lib/dune`.

- Create `logseq_db_worker/bonsai/dune`.

- Create `logseq_db_worker/cli/dune`.

- Create `logseq_db_worker/test/dune`.

- Create `logseq_db_worker/tool/dune` for the OCaml fixture generator and canonical comparer.

- Create all test files listed in the proposed package layout.

- Create private local interfaces `logseq_db_worker/lib/logseq_sqlite_codec.mli`, `logseq_db_worker/lib/logseq_sqlite_storage.mli`, and `logseq_db_worker/lib/storage_session.mli` plus their corresponding compiling `.ml` stubs.

- Create only the minimum compiling module stubs required by those tests.

- Create `test/logseq_db_worker_application_integration_test.ml` with the future single-service and graph-startup RED cases.

- Create `flutter/test/logseq_db_worker_host_adapter_test.dart` with the future application-support, snapshot-token, inbox-import, and native graph startup RED cases.

- Create `flutter/integration_test/logseq_db_worker_runtime_flow_test.dart` with the future persist-and-relaunch RED flow and a RED case which injects a mutation persistence failure and expects the application fatal-error state.

- Extend `../logseq-worker-interop/src/test/frontend/worker/db_worker_node_lock_test.cljs` with the external native-owner RED cases.

- Extend `../logseq-worker-interop/src/test/frontend/worker/db_core_test.cljs` with the derived-sidecar invalidation RED cases.

Steps:

1. Use one root Dune project and separate public libraries for core and Bonsai integration.

2. Give `logseq_db_worker` and `logseq_journal` the same repository release version and define the application package's dependency on that exact sibling version.

3. Document a local two-package pin flow which pins both names to this repository before solving or installing either package.

4. Keep the core dependency list free of Bonsai, Flutter, and Cmdliner.

5. Declare CLI `(public_name logseq-db-worker)` and `(package logseq_db_worker)` explicitly so installation ownership is unambiguous in the multi-package project.

6. Add all protocol, locator, local codec, atomicity, admission, ownership, query, outliner, engine, adapter, CLI, cross-runtime, performance, application-integration, and coordinated Logseq ownership tests before production behavior.

7. Make each stub return a typed not-implemented result or otherwise fail the intended behavioral assertion.

8. Add a compile-time spike which stages a transaction against a non-persisting immutable DB value, receives `db_after` and `tx_data`, and routes one complete storage batch through a local callback without calling persisted `Datascript.transact` or `Conn.transact`.

9. Add a local `test_bonsai_service.ml` consumer-closure test which proves the adapter reaches only dependencies already present in the current immutable iPhoneOS SDK and does not reach Cmdliner.

10. Run each repository's attributable RED targets separately and record the intended inventory before attempting an aggregate build.

```sh
opam exec -- dune build @install
opam exec -- dune runtest logseq_db_worker/test
cd ../logseq-worker-interop
bb dev:test -n frontend.worker.db-worker-node-lock-test
bb dev:test -n frontend.worker.db-core-test
```

Expected result: Interfaces and stubs compile, the pinned DataScript API spike compiles without an upstream component, the local Bonsai dependency graph resolves against the current immutable SDK inputs, and every behavioral RED target fails a named assertion for missing behavior rather than dependency resolution.

Stop condition: Do not implement a production function until the full RED inventory exists and unrelated baseline failures are separated.

### Task 3: Implement the local lossless atomic Logseq SQLite session

Files in `logseq_db_worker/lib/`:

- Implement `logseq_sqlite_codec.ml` against `test/test_codec.ml` and the pinned corpus.

- Implement `logseq_sqlite_storage.ml` against `test/test_storage_atomicity.ml` and the real Logseq table contract.

- Implement `storage_session.ml` against the staging, lifecycle, GC, and fatal-error tests.

Steps:

1. Use the private DataScript example and pinned Logseq CLJS storage as behavior references while keeping one new implementation in this package.

2. Implement exact Transit decoding and encoding for the complete pinned corpus.

3. Add a raw Transit preflight pass that rejects unsupported tags and values before the semantic decoder can downgrade them.

4. Implement `stage_transact` from the pinned public immutable DB and transaction-report APIs so it computes a single-use staged value without mutating a stored connection, session tail, or SQLite.

5. Expose `commit_staged` which uses prepared address UPSERTs and one `BEGIN IMMEDIATE` transaction for every node, root, and tail change.

6. Verify WAL, `synchronous = FULL`, busy-timeout, and locking PRAGMAs before allowing a writable session.

7. Install root, tail, compaction, and returned `db_after` state only after a successful commit receipt.

8. Make every mutation write, commit, or GC persistence failure raise one bounded `Fatal_storage_error` and make the session permanently unusable, while writable checkpoint and close failures use the documented shutdown diagnostics.

9. Implement reachability GC as a separate owner-guarded transaction whose failure cannot change semantic graph state.

10. Keep the generic `datascript-ocaml-native.sqlite` backend unreachable from Logseq graph open and remove every local fallback branch or auto-detection path.

11. Run the local codec, atomicity, process-kill, GC, and Engine integration tests against the exact pinned DataScript packages.

```sh
opam exec -- dune exec ./logseq_db_worker/test/test_codec.exe
opam exec -- dune exec ./logseq_db_worker/test/test_storage_atomicity.exe
opam exec -- dune exec ./logseq_db_worker/test/test_engine.exe
```

Expected result: The local codec restores and round-trips the admitted corpus, each storage batch is atomic, staged state installs only after success, and no `datascript-ocaml` or `bonsai_flutter` repository change is required.

Stop condition: Do not write graph mutation behavior while codec values are lossy, a staged transaction mutates state early, a storage batch can partially commit, or durability PRAGMAs are unverified.

If the exact pinned public DataScript API cannot implement the tested detached staging flow, stop and report the specific API blocker instead of changing the upstream pin, adding a second storage route, or modifying the Bonsai SDK plan.

### Task 4: Implement locator, admission, storage lifecycle, and query Engine

Files:

- Implement `logseq_db_worker/lib/graph_locator.ml`.

- Implement `logseq_db_worker/lib/admission.ml`.

- Implement `logseq_db_worker/lib/snapshot.ml`.

- Implement `logseq_db_worker/lib/storage_session.ml`.

- Implement `logseq_db_worker/lib/query.ml`.

- Implement the query paths in `logseq_db_worker/lib/engine.ml`.

- Keep both package manifests on the existing approved DataScript commit and add no Logseq-specific DataScript component dependency.

Steps:

1. Implement platform graph-directory resolution and confinement: Desktop `~/logseq/<graph-name>`, iOS `<app-data-dir>/graphs/<graph-name>`, and database `<graph-dir>/db.sqlite`, with no legacy encoded-repo fallback.

2. Implement `Snapshot.create` and `Snapshot.import` with SQLite backup or verified copy, a manifest, a package-owned catalog token, and tamper or unregistered-copy detection.

3. Restore a verified snapshot through the local lossless exclusively owned storage session.

4. Implement bounded minimum-schema, required-attribute, KV, remote-value, contradictory-sync-state, and lossless startup admission without enumerating graph datoms.

5. Prove `local-graph-uuid`, value-less RTC-related schema entities, client-operation sidecars, and pending local rows are not standalone remote classifiers, while a non-nil RTC `graph-uuid` fails closed.

6. Implement UUID-based graph info, block, page, children, tree, ancestors, and siblings reads.

7. Bind cursors to basis and query fingerprint while enforcing stable ordering, item limits, depth limits, and byte budgets.

8. Keep native local graphs disabled until the native ownership, backup, sidecar, and history-coexistence gates pass.

Verification:

```sh
opam exec -- dune exec ./logseq_db_worker/test/test_graph_locator.exe
opam exec -- dune exec ./logseq_db_worker/test/test_admission.exe
opam exec -- dune exec ./logseq_db_worker/test/test_snapshot.exe
opam exec -- dune exec ./logseq_db_worker/test/test_query.exe
opam exec -- dune exec logseq-db-worker -- --snapshot-token "$SNAPSHOT_TOKEN" graph info --format json
```

Expected result: Valid verified snapshots at schema `65.33` or newer read deterministically when lossless and semantically supported, every unsupported fixture fails closed, and no SQLite file changes.

### Task 5: Implement the structural mutation slice on exclusively owned snapshots

Files:

- Implement `logseq_db_worker/lib/mutation_plan.ml`.

- Implement `logseq_db_worker/lib/ownership.ml` for the package-created snapshot target.

- Implement `logseq_db_worker/lib/backup.ml` for an exclusively owned snapshot.

- Implement `logseq_db_worker/lib/outliner/order.ml`.

- Implement `logseq_db_worker/lib/outliner/tree.ml`.

- Implement `logseq_db_worker/lib/outliner/validation.ml`.

- Implement `logseq_db_worker/lib/outliner/references.ml`.

- Implement `logseq_db_worker/lib/outliner/save_block.ml`.

- Implement `logseq_db_worker/lib/outliner/insert_blocks.ml`.

- Implement `logseq_db_worker/lib/outliner/move_blocks.ml`.

- Implement `logseq_db_worker/lib/outliner/indent_outdent.ml`.

- Implement `logseq_db_worker/lib/outliner/delete_blocks.ml`.

- Implement the mutation dispatcher in `logseq_db_worker/lib/engine.ml`.

Steps:

1. Port fractional indexing against the pinned goldens and do not run the sync-only duplicate-order repair during ordinary structural mutations.

2. Acquire and hold one nonblocking advisory owner lock plus a current-format Logseq interop sentinel before any snapshot read-write session becomes Ready, and prove both package and pinned Logseq second writers are refused.

3. Keep unexpected stale snapshot sentinels fail-closed and test `Snapshot.recover` creating a new catalog token after process crash without unlinking the old sentinel.

4. Create one consistent recovery backup before the first snapshot mutation and block the write if backup creation or manifest verification fails.

5. Implement pure planners that return complete mutation plans without touching storage.

6. Stage and validate `db_after` through the local `Storage_session.stage_transact` API before persistence.

7. Commit once and install Engine and tail state only after a successful SQLite receipt.

8. Enforce expected basis, caller UUIDs, mutation-cache reuse, conflict, already-applied, and fatal persistence behavior.

9. Complete the title-derived references and tags pipeline before enabling `Save_block` parity.

10. Reject every supported input whose automatic pinned pipeline effects are not yet implemented.

11. Run every structural test and differential command against independently created snapshot clones.

```sh
opam exec -- dune exec ./logseq_db_worker/test/test_order.exe
opam exec -- dune exec ./logseq_db_worker/test/test_ownership.exe -- --target snapshot
opam exec -- dune exec ./logseq_db_worker/test/test_storage_atomicity.exe -- --target snapshot
opam exec -- dune exec ./logseq_db_worker/test/test_save_block.exe
opam exec -- dune exec ./logseq_db_worker/test/test_insert_blocks.exe
opam exec -- dune exec ./logseq_db_worker/test/test_move_blocks.exe
opam exec -- dune exec ./logseq_db_worker/test/test_indent_outdent.exe
opam exec -- dune exec ./logseq_db_worker/test/test_delete_blocks.exe
opam exec -- dune exec ./logseq_db_worker/test/test_cross_runtime.exe -- --oracle-logseq-repo ../logseq-oracle-4f21d068 --expected-oracle-commit 4f21d068aed43bb2ea5823247cae73ecdd8d60f8 --slice structural
```

Expected result: Every structural unit test passes, Logseq and OCaml canonical main-graph projections match over the accepted domain, and each runtime reopens and continues after the other runtime writes.

Stop condition: Keep native local graph writes disabled until the coordinated native ownership task passes, and keep snapshot writes disabled if the snapshot lock or manifest can be bypassed.

### Task 6: Implement native ownership, backup, and sidecar invalidation

Files:

- Extend `logseq_db_worker/lib/ownership.ml` with the coordinated native local-graph contract.

- Extend `logseq_db_worker/lib/backup.ml` with native owner-generation binding.

- Extend `logseq_db_worker/lib/engine.ml` with native pre-write gates.

- Add or update the coordinated lock-owner and sidecar invalidation contract under `../logseq-worker-interop/src/main/frontend/worker/` and its tests if the pinned runtime needs an explicit shared behavior.

Steps:

1. Implement atomic owner-lock acquisition, fail-closed stale classification, and the Logseq-coordinated generation guard for stale cleanup and release.

2. Revalidate lock identity before every storage-affecting operation.

3. Use SQLite backup before the first native mutation and reject raw WAL file copies.

4. Implement independent durable FTS and vector invalidation and prove a vector-incapable reopen cannot consume the later vector rebuild requirement.

5. Prove a replacement lock cannot be unlinked during stale cleanup or release and Logseq refuses a second writer while the OCaml engine owns the graph.

6. Prove identity tampering terminalizes the engine and owner-only close never removes another lock.

7. Prove every admitted client-operation history shape maintains checksum, pending, undo, next-mutation, and later-sync behavior, or reject that shape with `Unsupported_semantics`.

8. Enable `Native_local_graph _` only after the complete native ownership, sidecar, and history-coexistence suites pass.

9. Commit the coordinated Logseq changes before running interop acceptance and record that exact clean commit in every result.

10. If a coordinated change affects canonical main-graph semantics, update the semantic Logseq pin explicitly and regenerate the complete oracle corpus before continuing.

```sh
opam exec -- dune exec ./logseq_db_worker/test/test_ownership.exe
opam exec -- dune exec ./logseq_db_worker/test/test_storage_atomicity.exe
INTEROP_LOGSEQ_COMMIT="$(git -C ../logseq-worker-interop rev-parse HEAD)"
test -z "$(git -C ../logseq-worker-interop status --porcelain=v1 --untracked-files=all)"
opam exec -- dune exec ./logseq_db_worker/test/test_cross_runtime.exe -- --interop-logseq-repo ../logseq-worker-interop --expected-interop-commit "$INTEROP_LOGSEQ_COMMIT" --slice native-ownership
```

Expected result: Ownership races fail safely, recovery backups are consistent, sidecars rebuild on the next Logseq open, and no live multi-writer trace succeeds.

### Task 7: Add page and typed property slices

This task may proceed against exclusively owned snapshots after Task 5 even if the coordinated native-write work in Task 6 remains disabled.

Completing these operation families does not relax any native ownership, sidecar, or client-operation coexistence gate.

Files:

- Implement `logseq_db_worker/lib/outliner/pages.ml`.

- Implement `logseq_db_worker/lib/outliner/properties.ml`.

- Extend `logseq_db_worker/lib/protocol.ml` and JSON fixtures only for already frozen operation variants.

- Extend `logseq_db_worker/lib/engine.ml` dispatch without introducing adapter branches.

Steps:

1. Implement page create, rename, recycle delete, restore, and permanent delete as one validated slice.

2. Run page unit and bidirectional parity tests before enabling those variants.

3. Implement property upsert, set, remove, explicit batch modes, class relations, and closed values as the next validated slice.

4. Run property unit and bidirectional parity tests before enabling those variants.

5. Keep templates, import, reactions, raw transactions, split, merge, undo, redo, sync, and RTC unavailable.

```sh
opam exec -- dune exec ./logseq_db_worker/test/test_pages.exe
opam exec -- dune exec ./logseq_db_worker/test/test_cross_runtime.exe -- --oracle-logseq-repo ../logseq-oracle-4f21d068 --expected-oracle-commit 4f21d068aed43bb2ea5823247cae73ecdd8d60f8 --slice pages
opam exec -- dune exec ./logseq_db_worker/test/test_properties.exe
opam exec -- dune exec ./logseq_db_worker/test/test_cross_runtime.exe -- --oracle-logseq-repo ../logseq-oracle-4f21d068 --expected-oracle-commit 4f21d068aed43bb2ea5823247cae73ecdd8d60f8 --slice properties
```

Expected result: Each operation family is either enabled with canonical main-graph parity over every accepted input or absent from the public runtime dispatcher, and documented pre-stage restrictions are tested as worker rejections rather than equivalent Logseq results.

### Task 8: Implement the CLI and Bonsai adapters against the shared Engine

Files:

- Implement `logseq_db_worker/cli/main.ml`.

- Implement `logseq_db_worker/cli/cli_command.ml`.

- Implement `logseq_db_worker/cli/cli_output.ml`.

- Implement `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`.

Steps:

1. Map every graph CLI subcommand into `Protocol.request` without direct graph logic, and map snapshot create or import into the shared core `Snapshot` catalog API.

2. Add versioned JSON output and exact-protocol NDJSON session mode.

3. Implement the documented exit-code contract.

4. Create one serial Worker service whose lifecycle delegates to `Engine`.

5. Represent expected startup failures as `Open_failed Error.t` state and return them through the first and later request envelopes, while reserving Worker init failure for unrepresentable callback invariants.

6. Inject separate production epoch-millisecond and monotonic Engine clocks in each adapter without exposing a caller-controlled timestamp in the protocol or deriving persisted time from `Worker.Session_context.clock`.

7. Emit only bounded latest-wins invalidation pushes after successful commits.

8. Keep `decode_config` to bounded immutable decoding, resolve the application-support directory through `Worker.Service.create ~data_directory`, import only a named confined inbox entry when requested, and split Worker-Domain filesystem or database work correctly between `init` and request `handle`.

9. Test missing, relative, nonexistent, and inaccessible data directories as framework `Session_startup_failed`, separately from expected graph `Open_failed` responses.

10. Test `Full`, `Not_ready`, `Stopping`, delayed foreground pumps, latest-wins push collapse, and response-before-push ordering.

11. Test cancellation that wins Worker arbitration after a synchronous mutation commits, then prove basis-aware read reconciliation recovers the durable result.

12. Map every mutation persistence failure to CLI exit `5` or a terminalized Worker session and application fatal error, and map close failures separately to CLI exit `5` or Worker shutdown diagnostics.

13. Replay identical request traces through direct Engine, CLI NDJSON, and the Worker test harness, and replay open-failure traces through the shared `Protocol.failed` constructor used by all three harnesses.

```sh
opam exec -- dune exec ./logseq_db_worker/test/test_cli.exe
opam exec -- dune exec ./logseq_db_worker/test/test_bonsai_service.exe
opam exec -- dune exec ./logseq_db_worker/test/test_engine.exe
```

Expected result: All three transports produce the same canonical responses and final graph for every supported trace.

### Task 9: Replace the current application service and remove obsolete storage

Files:

- Modify `app/application.ml` to use `Logseq_db_worker_bonsai_service`.

- Replace the current startup configuration in `app/journal_startup.ml`, `app/journal_startup.mli`, and `flutter/lib/application_host_adapter.dart` with the approved application-support and typed-target contract.

- Extend the macOS and iOS host adapters so Desktop derives `~/logseq/<graph-name>` and iOS derives `<app-data-dir>/graphs/<graph-name>` before encoding the immutable startup target.

- Add an app projection module only if the UI needs a bounded mapping from graph responses to journal rows.

- Modify `app/dune`, `test/dune`, and `bonsai-flutter.sexp` as authorized.

- Modify the `logseq_journal` package dependencies in `dune-project` to depend on `logseq_db_worker`.

- Modify `logseq_journal.opam` and regenerate `logseq_journal.opam.locked` with the new package and approved dependency pins.

- Update `logseq_db_worker.opam` and regenerate `logseq_db_worker.opam.locked` with the repository's existing pinned DataScript and Bonsai commits.

- Implement against `test/logseq_db_worker_application_integration_test.ml`, `flutter/test/logseq_db_worker_host_adapter_test.dart`, and `flutter/integration_test/logseq_db_worker_runtime_flow_test.dart` from the RED phase.

- Rewrite remaining application fixtures to seed a valid temporary Logseq graph through the shared Engine or oracle fixture without adding new behavioral expectations after production behavior.

- Remove `app/journal_schema.ml`, `app/journal_schema.mli`, `app/journal_storage.ml`, `app/journal_storage.mli`, `app/journal_storage_path.ml`, `app/journal_storage_path.mli`, `app/journal_repository.ml`, `app/journal_repository.mli`, `app/journal_worker.ml`, `app/journal_worker.mli`, and obsolete recovery-only storage modules after all consumers are migrated.

- Remove tests dedicated only to the obsolete app-private store.

- Update `docs/agent-guide/001-journal-mobile-app-architecture.md` in the same integration change.

Steps:

1. Select one graph name or snapshot token before application Worker startup, derive the platform-native graph directory when applicable, and encode only the new startup envelope.

2. Replace journal worker requests with shared graph protocol requests.

3. Send an initial `Graph_info` request after the Worker transport becomes ready and render a typed `Open_failed` response in the UI.

4. Render a terminal Worker failure caused by `Fatal_storage_error` as an application-level fatal error which disables graph interaction until application restart.

5. Preserve bounded UI projections, stable UUID keys, stale-generation fences, and durable-state reconciliation.

6. Verify that no DataScript or SQLite work moves to Bonsai domain 0 or Dart.

7. Delete the obsolete store and compatibility paths rather than retaining dual behavior.

8. Run the complete OCaml, headless Bonsai, Flutter, and integration suites.

9. Verify a clean switch can pin both `logseq_db_worker` and `logseq_journal` from this one source tree and install the application without an external unpublished package source.

```sh
opam exec -- dune runtest
opam exec -- dune build -p logseq_db_worker @install
opam pin add logseq_db_worker . --no-action
opam pin add logseq_journal . --no-action
opam install logseq_journal
bonsai-flutter exec --profile=debug -- flutter test --no-pub
bonsai-flutter build macos --profile debug
```

Expected result: The application owns one graph-backed Worker service, all old app-private persistence references are gone, and existing journal UI behavior is expressed through Logseq graph projections.

### Task 10: Run release, performance, and Apple platform gates

Files:

- Use the performance fixtures, thresholds, and `logseq_db_worker/test/test_performance.ml` created during the RED phase.

- Finalize `logseq_db_worker.opam` and `logseq_db_worker.opam.locked`.

- Create `logseq_db_worker/tool/test_ios_device.sh` as the signed import, mutation, shutdown, cold-relaunch, and assertion harness.

- Modify no file in `../bonsai_flutter`; its current immutable SDK and closure metadata are test inputs, not implementation targets.

Steps:

1. Test representative graphs with at least 100,000 blocks, deep trees at the supported depth limit, large sibling sets, and high reference cardinality.

2. Verify the exact response, cursor, open, p95 latency, peak RSS, and throughput budgets approved in Task 0 on the recorded reference environment.

3. Build the installable package with the repository's existing DataScript and Bonsai pins and verify both public libraries and the installed executable resolve.

4. Verify that the Bonsai library reaches the local core and existing SQLite dependencies but not Cmdliner or the CLI executable.

5. Build and run the supported macOS `26.0+` arm64 target with SQLite enabled.

6. Build an unsigned iPhoneOS arm64 package for iOS `15.0+` against the currently installed immutable toolchain to prove target closure and packaging without claiming it can be installed.

7. In a separately gated signed lane with an external Team, bundle identifier, development certificate, provisioning profile, and physical device ID, run a dedicated harness modeled on `tool/ios/test_datascript_worker_device.sh` which imports a confined inbox snapshot, mutates, performs orderly shutdown, cold-launches a second time, and asserts persisted markers and protocol responses.

8. Keep `bonsai-flutter run ios` as a signed smoke launch only and do not use it as the persist-and-relaunch proof.

9. Reject iOS Simulator, Intel Mac, and universal macOS targets because they are outside the current Bonsai support boundary.

10. Run the final pinned Logseq reopen and subsequent-mutation suite on every supported operation family.

```sh
PACKAGE_INSTALL_PREFIX="$(mktemp -d)"
opam exec -- dune build @install
opam exec -- dune runtest
dune install --prefix "$PACKAGE_INSTALL_PREFIX"
OCAMLPATH="$PACKAGE_INSTALL_PREFIX/lib" ocamlfind query logseq_db_worker
OCAMLPATH="$PACKAGE_INSTALL_PREFIX/lib" ocamlfind query logseq_db_worker.bonsai
"$PACKAGE_INSTALL_PREFIX/bin/logseq-db-worker" --help
bonsai-flutter toolchain verify iphoneos
bonsai-flutter build macos --profile debug
bonsai-flutter run macos --profile debug
bonsai-flutter build ios --profile debug --no-codesign
```

Run the following only in the externally provisioned signed lane.

```sh
bonsai-flutter run ios --profile profile --device "$IOS_DEVICE_ID"
logseq_db_worker/tool/test_ios_device.sh --device "$IOS_DEVICE_ID" --inbox-bundle "$IOS_SNAPSHOT_BUNDLE"
```

Expected result: All unconditional tests pass, package artifacts install, the current immutable iPhoneOS SDK builds the local `logseq_db_worker.bonsai` dependency closure without any `bonsai_flutter` repository or toolchain regeneration, unsigned packaging passes, and both graph runtimes continue after each other's writes.

If the existing immutable closure cannot resolve a dependency, stop and report the exact newly introduced dependency instead of updating `bonsai_flutter` as part of this plan.

The signed physical-device lane is required release evidence only when the external signing and device prerequisites are available, and its absence does not make a local developer build falsely claim an unsigned bundle was device-tested.

## Rollout and stop rules

The verified-snapshot query surface may ship independently after codec, snapshot provenance, exclusive ownership, and admission gates pass.

Verified-snapshot structural writes may ship only after exclusive snapshot ownership, atomicity, and structural bidirectional canonical main-graph parity pass.

Native local writes may ship only after ownership, backup, sidecar invalidation, and native cross-runtime tests pass.

Page and property slices remain absent until their individual parity gates pass.

Remote or RTC graph support is a separate project and cannot be inferred from local SQLite success.

Any unsupported schema, value, lock, or sidecar state fails closed before mutation, while any persistence failure after mutation staging produces an application-level fatal error.

Any unclear or unreasonable future `spec/*.mli` contract must stop implementation and be reported rather than bypassed.

No stage introduces a generic-store fallback, a normalized-store fallback, a legacy startup decoder, a second Bonsai Worker slot, or a compatibility wrapper around the old journal store.

## Acceptance criteria

The package is independent when `logseq_db_worker` core and CLI build without the application library.

The service integration is complete when a headless Bonsai application opens the engine on the Worker Domain and all requests remain off domain 0.

The Bonsai dependency integration is complete when the current immutable iPhoneOS SDK builds the local adapter without any `bonsai_flutter` repository change, SDK regeneration, or toolchain reinstall.

The CLI and service share semantics when identical protocol traces produce identical canonical responses and graph state.

The storage is Logseq-compatible when the pinned Logseq runtime and OCaml runtime restore, mutate, close, and continue after one another in both directions, with canonical main-graph parity over the accepted domain.

The writer is safe when every injected callback failure terminates the session with an application-level fatal error and every failure or process-termination point recovers a complete before or after state, never a mixed state, under the verified SQLite durability policy.

The graph owner is safe when no second writer can start, ambiguous locks fail closed, tampering terminalizes the Engine, and only the owner releases its lock.

The protocol is stable when it exposes only UUID or qualified-ident identities, bounded collections, typed errors, explicit versions, basis-aware mutations, and query-and-basis-bound cursors.

The application integration is complete when `Journal_worker.service` and the app-private store are removed rather than retained alongside the graph engine.

## Testing Details

The reference behavior comes from the pinned Logseq outliner, database, worker, CLI, recycle, property, undo, and sync tests, while OCaml tests compare canonical graph meaning rather than physical page addresses.

All tests are authored during the RED phase, implementation proceeds in the documented GREEN order, and each completed slice is refactored only while its unit, differential, atomicity, and adapter suites remain green.

The final verification includes `dune runtest`, bidirectional Logseq reopen tests, CLI and Worker trace parity, macOS build, unsigned iPhoneOS packaging, and externally gated signed physical-device persist-and-relaunch evidence.

## Implementation Details

- Use one root Dune project, one new opam package, one core library, one Bonsai adapter library, and one installed CLI.

- Implement one lossless Logseq SQLite codec and session inside `logseq_db_worker`, bound to the current DataScript pin and with no generic SQLite fallback.

- Resolve native graphs only at Desktop `~/logseq/<graph-name>` or iOS `<app-data-dir>/graphs/<graph-name>`, with `db.sqlite` directly inside that directory and no legacy path fallback.

- Admit existing local DB graphs at schema `65.33` or newer, reject `graph-remote? = true`, contradictory sync identity, migration, creation, unsupported values, and unsupported semantics, and never classify by pending client-operation rows alone.

- Keep one immutable staged DataScript value and install it only after one successful atomic SQLite commit.

- Use UUIDs and qualified property identifiers externally, and never expose numeric entity IDs or storage handles.

- Follow pinned Logseq parent, fractional-order, reference, delete, direct-outdent, page-recycle, and typed-property semantics.

- Require exclusive graph ownership, online backup, sidecar invalidation, lock identity revalidation, and application-level fatal handling for every mutation persistence failure.

- Route CLI and `Worker.Service.Serial` through the same `Engine.execute` function and use latest-wins pushes only for invalidation.

- Replace the current Journal Worker during application integration and remove obsolete app-private persistence without compatibility paths.

- Advance one operation slice only after its complete RED suite and bidirectional accepted-main-graph Logseq parity gate turn green.

## Resolved decisions

1. The final target supports both writable verified snapshots and real local graphs under exclusive native ownership.

2. v1 is limited to existing local DB graphs at schema `65.33` or newer. It performs no graph creation, migration, live file-graph persistence, remote, or RTC operation, and newer schemas still require lossless and semantic admission.

3. The accepted operation scope includes hard block delete, direct outdent, the structural-first rollout, and the later page and typed-property slices. Split, merge, templates, raw transactions, sync, and RTC remain outside the first stable protocol.

4. Dune changes and coordinated lock and sidecar changes in the sibling Logseq interop worktree are authorized.

5. The host selects one typed target before Worker startup. The installed CLI selects exactly one of a snapshot token, a confined inbox entry, or a native graph name. The Flutter production host obtains the native graph name from its platform channel and derives the path itself: Desktop `~/logseq/<graph-name>` and iOS `<app-data-dir>/graphs/<graph-name>`. Tests and explicitly managed host policies may inject a snapshot or inbox target, but no host accepts an arbitrary native graph path.

---
