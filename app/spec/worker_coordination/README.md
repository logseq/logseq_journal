# App/Worker coordination contracts

This independent wrapped Dune virtual library is the target boundary for migrating
App/Worker interaction. Its explicit implementation lives in
`app/impl/worker_coordination/`: `worker_api`, `worker_pure_coordinator` and
`worker_effect_runner`. The App uses it for graph reads, durable writes, observation and resources.
The runner borrows the existing Service/client and the host's single event pump;
there is no adapter, second client or extra `Mailbox.on_event` subscription.
Navigation, feed/Favorites planning, Capture editing and media UI remain with their
business reducers.

The implementation now connects bounded typed reads, durable writes and atomic
Append, presentation-bound Confirm/readback, mutation and Import recovery/ACK,
observations/changefeed, asset demand/file leases, and host handoff to the real
Service/DB/Sync owners. Application uses those paths while retaining UI planning,
authentication/catalog, client lifetime and its serial event pump. This coverage
does not by itself establish final GUI acceptance; the remaining migration and
validation work is recorded in the task's evidence.

The pure coordinator receives actual admission IDs, refusals, terminal replies,
resource cleanup and registration-release ACKs as explicit events. It decides
cancellation races, bootstrap retry, revocation and nonblocking stop. The runner
encodes/sends, associates only actual in-flight Mailbox IDs, decodes and queues
later events. Mailbox filters duplicate terminal events before subscriber delivery;
completed requests do not consume a lifetime ownership quota.

## Construction, consumption and ownership

1. The host creates `Worker_pure_coordinator.initial` and borrows its verified existing
   client through `Worker_effect_runner.create`. The existing pump remains the only
   `Mailbox.on_event` owner. Runner callbacks enqueue later serialized Core turns.
2. `Worker_bound` identifies a fresh **binding** within the real mailbox
   epoch/generation. Its pure transition emits `Bootstrap`. Registration plus an
   authoritative baseline/replay yields `Bootstrap_received(binding, Ready p)`.
   Not-ready, failed, revoked and empty-ready are distinct; even an old failure on
   the same mailbox cannot overwrite a replacement binding.
3. The baseline issues usable Open sessions, per-session capability/byte limits,
   all resident phases, selection and deletion progress at one version. The
   client obtains its first session here, never from a test-supplied sealed value.
4. `Worker_pure_coordinator.request` returns the exact typed ticket **and** transition.
   Apply that transition before planning another request, then interpret its
   instructions. This also works for identical concurrent requests; there is no
   existential ticket recovery or inference from emitted instruction order.
5. Runner records the actual Accepted mailbox ID before the next pump drain.
   Its `delivery` always retains disposition, including owned failures/cancels.
   The shared host router routes each terminal response to exactly one registered
   owner. Unregistered IDs never fall through to Application's generic failure
   branch. Push/Terminal fanout is separate and must not double-process this runner.
6. Typed replies expose bounded existing Graph_types/Protocol DTOs. Their full
   revisions, parent/page/order, timestamps, properties, task status and reference
   data can feed the current Journal_graph_projection functions. Normalized UUIDs
   and checked budgets do not grant graph execution authority.
7. Query, observation and changefeed ownership are distinct. Empty data is
   observable. Ordinary read failure does not release an interest, supersede
   retained reconciliation or ACK a change window. A migrated interest has one
   invalidation owner; the legacy runtime and new runner cannot both rehydrate/ACK
   it. Release/registration races and orphan file acquisitions retain cleanup.
   Observation support is per query kind, not the coarse feature flag alone;
   Changes is rejected before Observe allocates a handle, keeping pull/ACK ownership
   unique. Admission observation may be supported independently.
8. Persist complete mutation/import intent before first send. Cancellation,
   Not_admitted on a retry, reply loss and confirmation read failure are not proof
   an earlier accepted operation did not commit. Exact receipts and explicit
   presentation-bound Confirm distinguish local durability from current rendering
   and cloud acceptance. Confirmation exposes its actual canonical readback to
   the existing projection without another redundant query; child continuations
   remain bounded. Partial children carry More/Partial, never a false exact count;
   large intent/target/readback collections use the existing Rrbvec dependency.
   A -> B -> A creates separate stable choice intents.
9. Host keeps authentication/token/catalog/startup/unlock, resident configuration,
   focus/select, deletion policy/confirmation and shared client lifetime. Before
   close/removal/account replacement/stop it calls `prepare_host_change`, obtaining
   its exact handoff ID. Overlap is refused without replacing the active cleanup
   ledger. The host joins other legacy owners, then validates/consumes the sealed
   safe receipt with `authorize_host_change` immediately before its actual action.
   Retried/reopened/rebound targets cannot reuse an old safe receipt. This is a
   coordination handoff, **not** an execution API for deleting local/remote graphs.
   Bootstrap failure/no Open DB cannot itself forbid preparing cleanup from a
   verified logical host binding and independent Worker resource ledger; missing
   identity evidence or an unreachable owner stays pending/failed, never fake Safe.
10. Shutdown is nonblocking: `Draining` requires continued pump/ACK delivery;
    `Stopped` proves this owner's resources are quiescent or explicitly transferred.
    It never stops the shared client. Ordinary Delete policy remains intact;
    Force deletion belongs to its existing host owner and truthfully reports any
    isolated pending cleanup. Durable unknown intents are not silently discarded.

## Current App capability coverage

The result types below deliberately reuse storage-independent DTOs rather than
copying the full Service command set or introducing App UI models into Worker.

| Current consumers / source | Target contract |
| --- | --- |
| journal_graph_feed_plan: list journals, root tree, child preview, cursor/revision scan | Journals (including initial revision), Tree, Children/Child_members, typed continuations and bounded budgets |
| journal_graph_reference_plan, journal_copy, detail/confirmation | Graph_info, Page/Outline_block UUID lookup, atomic Block_summary, full page/block DTO and per-target revision |
| journal_graph_favorites_plan and status load in journal_graph_runtime | Favorites, Task_statuses, Task_status_definitions, membership/order/revision/missing result slots |
| journal_graph_runtime admission/Capture/create child/source/status/delete | Admission; complete Append child/status payload; typed durable Save/Insert/Delete/Create_journal/Set/Clear/Set_asset_reference intents; receipt and Confirm |
| journal_media_runtime and Application imports/uploads | asset descriptors/list, scoped consumer demand/release, Import identity/outcome, Retry_asset/Retry_upload, imported/available file Acquire and tracked lease Release ACK |
| journal_graph_runtime Pull_changes/Ack_changes and structure interests | Changes/Acknowledge_changes preserve generation/chain/window identity; no ACK before consumer application; resync and stale-read errors distinct |
| current runtime interest reconciliation and empty-day refresh | Observe/Refresh/Release retain query/epoch/session, registration baseline and release ACK obligations; typed observation identity witness |
| Application account/resident/focus/retired runtimes and graph removal | host ownership table, versioned projection and fresh binding, correlated prepare/handoff/consume, exact target fencing and nonblocking shutdown |

`Journal` and `Children` are bounded convenience queries for simple clients.
`Page`, `Outline_block`, `Child_members`, `Block_summary` and `Tree` expose the
richer existing protocol shapes needed by the actual planners. A summary's page,
canonical root and child slice share one DB snapshot; sequential calls cannot be
labelled a summary. Descriptor lookup has no continuation; list queries alone may
return one. Page/tree/children continuation ownership includes the query's exact
parameters and snapshot, beyond the static result-item index.

## Backend ownership and migration coverage

| Required guarantee | Implemented ownership |
| --- | --- |
| Registered baseline/version stream | Sync/Worker supply one immutable lifecycle snapshot; registration/sample is atomic, versions precede effects, and unregister has an exact ACK. |
| Typed reads and DTOs | Existing Protocol V2 queries keep their real DTOs, revisions, bounded continuations and projection conversion. Copy retains its before/after revision checks. |
| Atomic Append | Overlay resolves or creates today's page, appends the complete block tree/statuses, outbox and original commit evidence in one transaction. An existing Web page is reused. |
| Durable mutation and Import recovery | Stable immutable intents and original receipts survive restart. Recovery is read-only and paginated; unknown outcomes do not replay or ACK. Confirm requires actual canonical readback in the bound presentation. |
| Observations/changefeed | Initial sampling subscribes against its predecessor snapshot and replays invalidations. Empty results remain interests; derived consumer application precedes change ACK. |
| Resources | Typed demand rounds and actual file leases retain their originating owner. Checked release waits for physical settlement; ordinary media versions do not relabel old Ready files, and previews retain old leases until released. |
| Host changes | Real writer/callback/resource settlement precedes a one-use backend permission. Application joins still-live legacy owners before quiescence and keeps unknown outcomes for readback. |

Capabilities are supplied by the checked baseline. An unsupported capability fails
before enqueue; no fake session, receipt or cleanup ACK establishes support.
Pure reducer tests prove decisions, while Service, persistence, mounted App and GUI
evidence have separate acceptance scopes.

## Validation and independent review

`dune build @app/spec/worker_coordination/all` compiles the interfaces without an
implementation. `dune build @test/worker-coordination-contracts` compiles sealed
clients and rejects illegal clients. The rule also belongs to `dune runtest`.
Clients start with a concrete client/binding/bootstrap, carry typed tickets through
query results into **the current Journal_graph_projection**, observe an empty or
nonempty page, persist/send a mutation, confirm with its presentation, and release
resources. Additional cases cover every query/mutation/asset family, handoff and
representative rejection/error/cancellation branches. Tests use the actual public DTO CMIs and
only a test dependency on the existing App projection; the spec library does not
depend on App.

Independent review also found and corrected three new contract holes: Confirm
needed an explicit presentation generation for focus-away/back; host handoff needed
a returned ID, per-ID outcomes and a binding/target-scoped single-use safe receipt;
asset notices needed exact opaque consumer association and a separate session/
upload outlet. Worker-side cleanup must also settle resources whose successful
outcome is replaced by Mailbox Cancelled/Shutdown before App sees the handle.

These are **compile/type and source-boundary checks**, not executable behavior or
backend conformance tests. The current set has 22 sealed positive clients, three
additional compile-only integration modules using the real App projection, and
22 negative clients. Before enabling a runtime capability, its owner needs
at least the following deterministic integration acceptance:

- Bootstrap: graph changes between sample/registration/replay, empty membership,
  retry/rebind on the same client, delayed old not-ready/failure, exact byte limits.
- Router: interleaved legacy/new IDs, reverse/duplicate/late replies, owned failure
  and cancellation without legacy UI errors, malformed/foreign receipts, no second
  pump handler and cleanup after revocation.
- Reads: current projection conversion including refs/status/time/properties,
  present/missing/recycled targets, every continuation family, stale cursor and
  oversized singleton rather than silent truncation.
- Mutations: Web-first day page, concurrent creation, lost accepted reply/restart
  and same durable replay, A -> B -> A choice IDs, status/child suboperation order,
  confirmation read failure and focus-away/back rejecting stale confirmation.
- Assets: duplicate/late import and file acquisition, orphan preview/lease release,
  demand release ACK, upload retry identity, other graph/account isolation, and
  backend orphan retain settlement when cancellation suppresses the success reply.
- Observation/changefeed: empty interest, register/Release races, sample/replay gap,
  epoch ordering, read error retaining suffix reconciliation, ACK only after every
  affected owner applies, no old/new duplicate invalidation owner.
- Handoff/shutdown: overlap preserves first ledger, failed id1/retry id2 and late
  id1 ACK, reopened same UUID/rebound client rejecting old safe receipt, last graph
  empty projection, partial Force cleanup remains explicit, shared client/other
  owners survive and pump keeps delivering cleanup until terminal fence.

## Executable read-slice checks

- `test/worker_coordination_pure_test.ml` checks deterministic state transitions,
  input immutability, cancellation/admission reordering, terminal duplication,
  retired bindings, cleanup ACKs and stopping failures. It runs 500 fixed-seed
  state traces and 250 queued-read traces with a counterexample shrinker, plus
  100 generated ownership-range
  traces and a 16,384-ID compression check. Generators and seeds are outside the
  pure state machine; no clock/random/IO or host callback is read by `step`.
- `test/worker_coordination_runtime_test.ml` uses the actual Service and isolated
  synthetic mirrors/catalogs. It exercises baseline to Open session, bounded typed
  reads and continuations, DTO conversion through the actual App projection,
  focus A -> B -> A, rebinding, old reply ownership and cancellation/shutdown ACKs.
  A held real writer also exercises read -> graph close while the read awaits its
  snapshot; outer writer cancellation does not roll back the accepted DB write,
  and the Service must recheck exact scope/Open phase before returning the read.
- The existing mounted `application_view_test` Copy case drives Timeline,
  Favorites and Detail menus, replacement and clipboard acknowledgement through
  the new host/coordinator/runner. Its synthetic Service implements the declared
  baseline protocol and ordinary single-graph mode without a resident-scopes
  broadcast. A validated native account permits binding; the atomic baseline
  still supplies all execution authority. The case also holds unregister ACK
  while the legacy manager closes, proving that graceful termination waits and
  emits termination-ready once. Direct forced disposal requests Worker stop and
  tears down UI without this graceful join. Mounted fixtures remain separate
  from actual Service conformance evidence.
- `plan_query` queues exact host identities in the pure coordinator until a
  verified Open baseline matches. Future identities are not falsely retired by
  an older queued snapshot; a known removed execution has retained retirement
  evidence, including Opening -> removed. The host watch stores callback outlets
  and queues Forget before delivering a business callback. The legacy mailbox-ID
  table no longer owns these five one-shot read families.
- Existing Copy reducer tests use the compatibility entry to the same generic
  pure engine. Production Copy passes sealed continuations directly; its old
  mailbox-ID request table and cancellation path have been removed. Buffered
  subtree children, cursor history and text fragments use Rrbvec.

These checks do not establish mutation/import recovery, observation/resource
ownership, writer fences, full-layer migration or real-device acceptance.
