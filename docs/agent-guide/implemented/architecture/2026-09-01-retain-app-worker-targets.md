# Retain Only App-Used Worker Targets

## Problem

`Logseq_db_worker_contract.Config.target` currently presents five graph target
modes:

```ocaml
type target =
  | Managed_sync of { base_url : string }
  | Snapshot of { token : Graph_types.Uuid.t }
  | Import_snapshot of { inbox_entry : string }
  | Synced_mirror of synced_mirror
  | Native_local_graph of native_local_graph
```

The production Flutter host does not select among these five modes. Its only
startup encoder, `LogseqDbWorkerStartupEnvelope.encode`, always emits
`managedSync`. After the managed sync reducer restores or selects a graph, the
worker effect runner creates the equivalent of the current `Synced_mirror`
payload internally and passes it directly to `Engine.open_`. The application
therefore needs only two concepts, at two different boundaries:

- `Managed_sync` is the application-level worker startup mode.
- a synced-mirror descriptor is the internal Engine attachment input for the
  selected managed graph; it is not an application startup target.

No production App path constructs `Snapshot`, `Import_snapshot`, or
`Native_local_graph`. Their remaining consumers are non-production or ancillary:

| Target | Current consumers |
| --- | --- |
| `Snapshot` | `logseq-db-worker --snapshot-token`, OCaml application and worker fixtures, Flutter golden tests, Engine tests, and protocol tests |
| `Import_snapshot` | `logseq-db-worker --import-inbox-entry`, JSON decoding, Engine startup, and a reducer target-mapping test |
| `Native_local_graph` | `logseq-db-worker --graph-name`, fixture generation, the performance benchmark, Engine tests, and CLI tests |

These modes are not isolated constructors. Keeping them requires the worker to
retain all of the following parallel policy and mechanism:

- five `Config.target` wire variants and five pure-reducer `target_kind`
  variants;
- optional sync configuration and a non-managed `Start -> Open_engine` path;
- snapshot catalog publication, import, resolution, write sessions, and recovery
  copies;
- native graph location, direct-write admission, client-history inspection,
  derived-sidecar invalidation, and the iOS native import fallback;
- snapshot/native ownership policies and backup orchestration;
- `Snapshot_write_target`, `Native_write_target`, and their mutation branches in
  `Engine`;
- `Snapshot` and `Native_read_write` graph modes and their protocol encodings;
- snapshot-, graph-locator-, and local-target-specific errors;
- a CLI whose current graph commands can only open the three non-App targets;
  and
- test and benchmark fixtures that validate modes the App cannot start.

The cost is visible even on the managed path. `Engine.resolve_target` creates a
snapshot catalog before matching the target, so opening a `Synced_mirror` still
initializes storage that only the removed local modes need. The shared reducer
also carries optional sync state and local-target branches even though the App
always creates a managed worker.

The installed `logseq-db-worker` executable and the public
`logseq_db_worker.contract` package make deletion an observable contract change.
The implemented `Pure Logseq DB Worker Reducer and Effect Runner` decision also
explicitly required preservation of all five targets. Removing the three local
targets therefore supersedes that part of the implemented architecture and is
not a behavior-preserving simplification. This document classifies the work as
an intentional architecture and product-surface contraction. Repository policy
requires obsolete paths to be deleted without compatibility decoders, aliases,
fallbacks, or migrations.

## Proposal

Retire `Snapshot`, `Import_snapshot`, and `Native_local_graph` as supported
worker targets. Remove `Synced_mirror` from the public startup configuration and
represent it as an internal-only Engine attachment descriptor. Preserve the
production App behavior for managed graph restore, selection, download,
encrypted bootstrap, attachment, local-first mutation, pull, and submission.

### Narrow the target contracts

Remove `Snapshot`, `Import_snapshot`, `Native_local_graph`, and `Synced_mirror`
from `Logseq_db_worker_contract.Config.target`. `Managed_sync` becomes its only
constructor and the only public application startup mode. Delete the `snapshot`,
`importSnapshot`, `nativeLocalGraph`, and `syncedMirror` JSON encoders and
decoders. Old startup payloads using those wire kinds must fail validation; do
not add compatibility handling.

Define a non-serializable internal Engine attachment descriptor for the current
`Synced_mirror` payload. Managed attachment continues to carry exactly the
current graph ID, display name, canonical graph directory, database path, and
checkpoint, but no public caller can start a worker with that descriptor.

Reduce the worker pure reducer to the managed lifecycle. Remove
`Snapshot`, `Import_snapshot`, `Synced_mirror`, and `Native_local` from
`target_kind`; delete the type entirely if its remaining singleton `Managed`
case carries no decision value. Remove the local-target/no-sync configuration
branch and make sync-core ownership non-optional. The outer worker is always
managed while its effect runner owns the currently attached synced-mirror
Engine.

### Delete local-target Engine machinery

Make Engine opening describe a synced mirror rather than a five-way startup
configuration. Remove snapshot and native target resolution, direct local
mutation handling, backup/write-session orchestration, derived-sidecar handling,
native client-history classification, and the iOS native import fallback.

After a final production and test consumer audit, delete modules whose complete
purpose disappears:

- `logseq_db_worker/lib/snapshot.ml` and `.mli`;
- `logseq_db_worker/lib/backup.ml` and `.mli`;
- `logseq_db_worker/lib/graph_locator.ml` and `.mli`; and
- `logseq_db_worker/lib/derived_sidecars.ml` and `.mli`.

Do not delete `Synced_snapshot_parser`: despite the similar name, it parses
downloaded managed-sync artifacts and remains required by `Synced_mirror`.
Narrow `Ownership` to synced-mirror ownership instead of deleting its exclusive
open and identity-revalidation policy.

Remove the now-unreachable `Snapshot` and `Native_read_write` graph modes. If
`Graph_types.graph_info.mode` has no remaining decision value once every graph
is `Synced_local_first`, delete the field and its protocol encoding instead of
retaining a singleton enum.

### Remove or realign ancillary consumers

The current CLI cannot simply switch its local graph commands to
`Managed_sync`: managed startup requires the sync reducer, authentication,
catalog selection, crypto, WebSocket, and worker-effect composition, while the
CLI calls `Engine` directly. Delete the `logseq-db-worker` executable,
`logseq_db_worker_cli`, its snapshot commands, local target selectors, and
`test_cli.ml`. Do not keep a CLI that accepts an apparently supported target and
fails later in `Engine.open_`.

Realign test and tool setup with the production storage model:

- replace snapshot-based application and Flutter golden fixtures with a
  deterministic managed configuration, catalog cache, and bootstrapped synced
  mirror;
- retain App behavior tests for graph reads and mutations through the managed
  worker rather than through a private local target;
- delete Engine tests that exclusively specify snapshot catalogs, native
  direct-write recovery, native history, derived sidecars, or local-target
  ownership;
- preserve general storage, mutation planning, query, pagination, lifecycle,
  error, and atomicity coverage through synced-mirror or managed worker paths;
- retarget the performance benchmark to a bootstrapped synced mirror and remove
  snapshot-copy throughput measurements unless another production consumer is
  identified;
- remove snapshot token and native graph fields from fixture-generator outputs;
  keep the encrypted managed warm-start fixture and other managed-sync fixtures;
  and
- delete the inbox-based iOS device import harness if it has no remaining
  managed scenario.

Remove obsolete package dependencies, Dune stanzas, public re-exports, error
components, protocol codecs, source-boundary expectations, and documentation
only when their last consumer disappears. Implementation must update the
canonical `.mli` files under `logseq_db_worker/spec/` explicitly; it must not
add parallel interfaces or compatibility layers.

### Preserve the managed application contract

The contraction must not change:

- the Flutter startup payload emitted for `Managed_sync`;
- cached account and graph selection restoration;
- graph picker behavior when no valid selection exists;
- encrypted graph-key loading and password recovery;
- server snapshot download and `Synced_mirror.bootstrap` activation;
- warm opening of an existing synced mirror;
- checkpoint, authoritative/projected database, and durable outbox semantics;
- managed mutation preparation, encryption, atomic local commit, submission,
  acknowledgement, and pull;
- graph switching, sign-out, foreground/background, shutdown, and stale-effect
  fencing; or
- application-visible graph responses, invalidations, startup state, and error
  diagnostics on retained paths.

## Decision

Retain `Managed_sync` as the only public worker startup target. Replace the
public `Synced_mirror` target with a non-serializable internal Engine attachment
descriptor, and delete the snapshot, import-snapshot, and native-local target
paths together with their CLI, storage policy, protocol surface, fixtures, and
tests. Preserve the complete managed-sync application lifecycle and its
synced-mirror storage behavior without compatibility decoders, aliases,
fallbacks, migrations, or test-only target implementations.

## Alternatives considered

### Keep all five targets because the CLI and tests use them

This is the strongest reason to retain the current design. The CLI is installed,
the contract library is public, and snapshot/native fixtures provide convenient
deterministic testing. However, those consumers force production worker and
Engine policy to model three graph modes that the App cannot enter. The stated
product scope prefers the actual App architecture over retaining the ancillary
surface.

### Remove only the constructors

Deleting only the three `Config.target` constructors while retaining snapshot
catalogs, native graph handling, backup machinery, graph modes, CLI commands,
and local-only tests would leave most of the complexity unreachable. It would
also make later call-site searches misleading. The decision should own the
dependent deletion rather than produce dead infrastructure.

### Keep test-only target constructors

A test-only target type or conditional production constructor would preserve
existing fixtures but keep a second runtime architecture solely for tests.
Tests should exercise the production managed and synced-mirror boundaries, not
expand the production state space.

### Decode obsolete targets and translate them to a retained mode

There is no correct translation. A snapshot or native graph lacks managed graph
identity, checkpoint, catalog authorization, and outbox semantics. Silent
translation would weaken admission and storage authority. Compatibility
decoding is also prohibited by repository policy.

### Redesign the CLI as a Managed Sync client

This would require an authentication and graph-selection host, sync effect
runner, E2EE integration, and long-lived network lifecycle. It is a new product
surface rather than cleanup and should require a separate decision if wanted.

## Acceptance criteria

- The production Flutter host continues to emit only `Managed_sync` startup
  payloads and all production App startup scenarios pass.
- `Config.target` contains only `Managed_sync`; `snapshot`, `importSnapshot`,
  `nativeLocalGraph`, and `syncedMirror` JSON wire values are rejected with no
  fallback.
- The synced-mirror Engine attachment descriptor is internal and
  non-serializable, and no public API can start a worker directly from it.
- The worker pure reducer contains no local target kind, optional no-sync mode,
  or non-managed startup/open branch; a singleton target-kind type is also
  removed if it carries no information.
- Managed graph attachment still opens the selected local mirror through one
  typed internal boundary, with checkpoint and graph identity validation.
- Engine contains no snapshot/native target resolution, local direct-write
  branch, backup/write-session branch, native history inspection, derived
  sidecar policy, or iOS native fallback.
- The local `Snapshot`, `Backup`, `Graph_locator`, and `Derived_sidecars` modules
  are deleted if the final audit confirms no retained managed consumer.
- `Synced_snapshot_parser` and `Synced_mirror.bootstrap` remain the only snapshot
  ingestion path and continue to support encrypted and unencrypted managed
  bootstrap.
- Snapshot/native graph modes and protocol values are removed; no singleton
  mode enum remains unless a retained consumer proves it carries information.
- The `logseq-db-worker` executable, `logseq_db_worker_cli` library, CLI tests,
  and their package/build declarations are deleted.
- Every fixture, benchmark, test, package, dependency, and document reference to
  the retired targets is deleted or changed to use an actual
  managed/internal-synced-mirror path.
- No alias, deprecated constructor, compatibility decoder, migration, fallback,
  or test-only target implementation is introduced.
- Existing unrelated user changes in the worktree are preserved.
- Focused reducer, effect-runner, Engine, managed E2E, encrypted warm-start,
  application integration, Flutter host-adapter, and Flutter golden tests pass.
- `rg` finds no retired constructor or wire-value reference outside historical
  decision documents, and `dune build @all`, `dune build @fmt`, `dune runtest`,
  relevant Flutter tests, `git diff --check`, and `spec-dev-tool check --all`
  pass.

## Implementation evidence

- `logseq_db_worker/contract/config.ml` now admits and serializes only
  `Managed_sync`. Contract tests reject every retired wire kind without a
  decoder fallback.
- `logseq_db_worker/lib/engine.ml` opens one non-serializable managed attachment
  carrying graph identity, mirror paths, and checkpoint state. It no longer
  resolves startup targets or owns snapshot/native write policies, and it
  restores durable outbox projection before an attachment becomes visible.
- The worker reducer, runner, Bonsai service, and Application now compose one
  mandatory managed sync core. Warm local presentation does not challenge a
  WebSocket token until the account has been authenticated.
- `Snapshot`, `Backup`, `Graph_locator`, and `Derived_sidecars`, the local target
  Engine branches, the CLI executable/library/tests, and the inbox-based iOS
  harness are deleted. Snapshot/native graph modes and the singleton graph-mode
  field are also removed.
- Application, Engine, benchmark, fixture, protocol, and source-boundary tests
  use managed catalogs and synced mirrors. The real Flutter golden fixture is a
  deterministic unencrypted managed warm start; the macOS integration lane
  retains the production encrypted warm-start fixture and Keychain provider.
- `dune runtest`, `dune build @all @fmt @install`, `git diff --check`, Flutter
  analyzer and full widget tests, all seven real OCaml runtime golden cases, and
  `logseq_db_worker/tool/test_macos_runtime_flow.sh` pass. The deployed online
  managed-sync E2E remains credential-gated; its four required environment
  variables were unavailable in this verification environment, while its
  credential and protocol support tests pass in `dune runtest`.

## Consequences

- Application startup has one public target and one storage authority: managed
  sync owns graph selection and passes a typed attachment directly to Engine.
- External users of the removed startup JSON kinds, CLI, graph modes, and local
  storage modules must stop using them; no compatibility or migration path is
  retained.
- Deterministic tests exercise the production managed lifecycle. Tests that
  require production Keychain crypto run through the macOS integration lane,
  while Flutter pixel tests stop before online authentication or encrypted text
  submission.
- Future local-file or standalone CLI products require a new decision and a new
  architecture rather than reintroducing target variants into this worker.

## Risks

- Removing the installed CLI and all public target constructors except
  `Managed_sync` intentionally breaks external consumers that are not visible
  in this repository.
- The implemented pure-worker architecture deliberately unified all five
  targets. Removing three variants must simplify that reducer without
  regressing ticket ownership, graph lifecycle, stale completion fencing, or
  shutdown ordering.
- Snapshot fixtures currently isolate tests from managed authentication and
  network behavior. Their replacements must remain deterministic and must not
  turn focused UI or Engine tests into live-network tests.
- Deleting snapshot backup/write-session code removes recovery guarantees for
  modes that are being retired. The retained synced-mirror path depends instead
  on checkpointed server state and durable outbox behavior; the audit must
  ensure it never called the local backup machinery accidentally.
- `Snapshot` and `Synced_snapshot_parser` have similar names but different
  responsibilities. A broad textual cleanup could delete managed bootstrap
  support.
- Collapsing `graph_mode` or removing error components changes public JSON
  responses in addition to target configuration. These are intentional
  removals only if no retained App behavior consumes the fields.
- Existing device scripts and tests may encode platform validation obligations
  that are broader than their obsolete inbox setup. Delete only the retired
  scenario, not unrelated device lifecycle coverage.

## Questions

- None.
