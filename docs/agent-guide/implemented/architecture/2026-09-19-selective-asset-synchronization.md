# Selective Asset Synchronization

## Problem

The application synchronizes DB graph data but has no public asset transfer or
residency API. It must render remote assets without downloading every historical
binary at bootstrap. Automatic downloads must be restricted to assets required
by visible UI, recent journals, and favorites. Metadata synchronization and binary
availability have separate lifecycles.

## Proposal

Delivery scope adjustment (2026-09-19): after a native List visibility probe,
the user chose to retain native components and defer automatic visible-attachment
triggering. Recent-journal and Favorites downloads, explicit imports, and their
remaining acceptance criteria stay in scope. Native visibility-triggered discovery,
downloads, and presentation are deferred; their owner/runtime contracts remain
tested preparation rather than a delivered UI feature.

### Verified upstream model

This design targets DB graphs, not a compatibility layer for file graphs.
Evidence was inspected in the local Logseq checkout at commit
`8cd1013809dc0b172bc841916571ad275527fcb7` and the current upstream asset sync source.

- An asset is a graph entity tagged `:logseq.class/Asset`, identified by
  `:block/uuid`. Properties include `:logseq.property.asset/type` (file extension,
  not MIME type), `size`, `checksum`, `remote-metadata`, `external-url`, and optional
  dimensions. These records travel with ordinary graph data; binary files do not.
- Node storage resolves `<repo directory>/assets/<asset UUID>.<type>`. Browser
  storage uses its graph filesystem abstraction. Do not require the native app
  to share Logseq's physical directory.
- The asset HTTP endpoint is `/assets/<graph ID>/<asset UUID>.<type>`. GET fetches
  a binary; PUT sends one with authentication and checksum/type metadata headers.
  The URL has no checksum version component.
- After a successful upload, upstream publishes `remote-metadata` containing
  `{:checksum checksum :type asset-type}` as a graph transaction. This is the
  remote version descriptor; the current entity checksum can be newer while an
  upload is pending. Plaintext checksums are SHA-256 hex strings.
- For E2EE, file bytes are AES-GCM encrypted using the graph key. The wire body
  is Transit containing `[iv, encrypted bytes]`, with a 12-byte IV. Reuse key
  ownership, but implement the asset codec explicitly rather than assuming the
  protected-title wire representation is interchangeable.
- External URLs are excluded from managed asset downloads. Upstream has both
  per-asset requests and a whole-graph missing-file download helper. Only the
  per-asset protocol belongs in this application's automatic download path.

Primary references (paths relative to the Logseq checkout):

- `src/main/frontend/worker/sync/assets.cljs`
- `src/main/frontend/worker/sync/large_title.cljs`, `asset-url`
- `src/main/frontend/common/crypt.cljs`, binary encryption/decryption
- `src/main/frontend/worker/platform/node.cljs`, `asset-file-path`
- `deps/db/src/logseq/db/frontend/asset.cljs`, checksum calculation
- `deps/db/src/logseq/db/frontend/property.cljs`, asset property definitions
- https://github.com/logseq/logseq/blob/master/src/main/frontend/worker/sync/assets.cljs

### Ownership and module boundaries

Proposed module names below describe responsibilities, not implemented APIs.

| Layer | Responsibility | Must not own |
| --- | --- | --- |
| `logseq_db_types`, `Asset_descriptor` | Asset identity, remote version, source kind, size and presentation metadata | Transfer scheduling or UI policy |
| `logseq_overlay_db`, asset reads | Resolve asset references and descriptors from the effective graph; bounded subtree/reference queries | HTTP or recent-day policy |
| `logseq_db_worker` | Expose bounded asset queries, own durable upload workflow and graph metadata publication, reconcile graph changes with transfer inputs, route completions and lifecycle invalidations | Choose N, favorites policy, or viewport demand |
| `logseq_sync` pure reducer, `Asset_transfer` | Explicit per-asset demand, deduplication, generic priorities, retry state, cancellation, version and scope fencing | Discover all graph assets, interpret journals or favorites |
| `logseq_sync` effect runner | Authenticated GET/PUT, binary Transit/E2EE codec, checksum verification, bounded IO and transfer cancellation | Mutate graph membership or decide download eligibility |
| Asset cache store, injected into effect runner | Durable cache manifest, temporary files, atomic publication, scoped file handles and eviction effects | Store cache status in synchronized graph datoms |
| app, `Journal_asset_policy` | Produce visible/recent/favorite demand and retention reasons; policy settings | Construct server URLs or handle credentials/keys |
| app views and native presentation | Report actual displayed asset needs; display local handles, placeholders and retry state | Start network requests from view construction |

Keep the cache adapter alongside the existing `logseq_sync` local-store adapters
initially. Do not introduce an extra package just for a filesystem wrapper.
Keep asset transfer state separate from the graph transaction sync state, while
sharing its account scope, graph generation, authentication and graph-key handle.
An unavailable asset must not change a current graph transaction stream to failed.

Existing integration points are `logseq_sync/spec/pure_reducer/core.mli`,
`logseq_sync/spec/effect_runner/effect_runner.mli`,
`logseq_db_worker/contract/protocol.mli`, `logseq_overlay_db/lib/overlay_read.mli`,
`app/journal_graph_runtime.ml`, and app timeline/detail/favorites reducers.
The existing worker contract has paginated journal, favorites and tree reads;
`Graph_types.Asset_value` already represents an asset UUID. These are useful
foundations, not complete asset discovery or transfer APIs.

### Download policy

The app owns the union `VisibleAssets ∪ RecentJournalAssets(N) ∪ FavoriteAssets`.
Each asset can retain multiple reasons; removing one reason does not cancel a
download still required by another. The sync API receives generic demand handles
and foreground/background priority, not a favorites flag or journal date.

Confirmed scope: default N=7, journal dates including today, complete favorite
subtrees, and no recursive ordinary-link expansion. Upload is included in this phase.

- Recent means journal dates in the local-calendar interval
  `[today - (N - 1), today]`, including all descendants, not assets created or
  modified during that period. N is configurable; N=0 disables this reason.
- A favorite page includes its content subtree. A favorite block includes itself
  and its descendants. Enumerate the complete favorites collection with cursors,
  independently of how much of the favorites UI has loaded.
- Include assets directly present in these subtrees and asset-valued properties.
  Do not recursively traverse ordinary page links, backlinks, or arbitrary graph
  references: a popular page could otherwise pull in the entire graph. Visible
  embeds contribute the assets they actually render as visible demand.
- Visible demand is emitted for media actually needed by the viewport or an open
  preview. A row containing an attachment filename does not necessarily require
  the original binary. Collapsed, offscreen rows do not count as visible.
- Only managed remote assets enter this queue. External links use a separate
  rendering path and are not automatically mirrored for offline use in this scope.

Use cursor-based queries with bounded result sizes and a bounded pending queue.
Backpressure pauses metadata enumeration when the queue is full, without silently
dropping eligible assets. Recent/favorite enumeration must not materialize whole
page trees in the app or issue one worker round trip per block. Prefer a worker
query for asset descriptors under explicit roots with continuation state.
Reuse graph reference/property semantics instead of an app-side regex scanner.

Start with bounded scoped graph reads rather than a new whole-graph reverse index.
Use committed change notifications to invalidate affected scopes/descriptors;
if a change cannot be mapped precisely, requery only the selected roots with
bounds. Local overlay edits also invalidate the effective read projection.
Refresh recent roots at day rollover, settings changes, graph selection, and
resume; refresh favorite roots on membership changes. Fence asynchronous query
pages by graph generation and query revision, retaining committed demand while
a replacement enumeration is incomplete.

### Transfer and cache lifecycle

The conceptual input API is demand replacement/release per consumer, descriptor
updates, retry, and scope shutdown. Output is availability and a local file handle.
Large file bytes never pass through reducer events or worker JSON responses.

1. Resolve a descriptor and a version key consisting of origin, account, graph,
   asset UUID, remote type, and remote checksum. A transfer also carries request
   identity and graph generation. Entity ID or UUID alone is insufficient.
2. Check the cache manifest and file. Coalesce all requests for the same version.
   Prefer visible jobs over background jobs and reserve foreground capacity.
   Bound active requests, queue size, byte usage and decode memory separately.
3. Without `remote-metadata`, hold eligible demand in `Waiting_remote`; do not
   treat a DB entity as proof that remote bytes are available. A current checksum
   that differs from the published checksum is a pending version, not corruption.
4. Download to a scoped temporary artifact, decrypt if required, and verify the
   plaintext SHA-256 against the selected remote version. The mutable remote URL
   can race with metadata propagation; mismatches must never publish as ready.
5. Publish through an atomic cache operation only if the request's scope and
   version remain current. A stale completion may clean up its temporary file;
   it cannot replace the current version or notify another graph's UI.
6. Notify only interested consumers. A ready result provides a local handle plus
   its version. Cache eviction must not remove a file while a renderer holds it.

Availability states should distinguish queued, downloading, ready,
waiting-for-remote, waiting-for-unlock/network, and failed-with-retry information.
Transient failures use bounded backoff. A 404 may be metadata/object propagation
delay; retain the desired version and retry with limits or upon relevant updates.
Do not spin forever on a bad object. Authentication uses existing token refresh
ownership. A locked graph does not repeatedly attempt decryption.

Persist verified cache records, not a second copy of graph metadata as authority.
On restart derive demand again and validate cache files lazily. Discard incomplete
temporary downloads initially; range resume is not assumed, particularly for the
Transit AES-GCM envelope. Streaming network-to-disk does not by itself guarantee
bounded memory during Transit parsing/decryption: use explicit size/concurrency
limits until a compatible bounded-memory codec is verified.

Cached files outside the union may remain under an LRU budget, but must not trigger
new downloads. Visible handles and currently selected recent/favorite content are
retained while required. If the desired set exceeds storage capacity, preserve
foreground access and report incomplete offline prefetch; do not evict and
redownload the same desired objects in a loop. Account logout and local graph
deletion cancel transfers, release handles, and remove the appropriate cache.
Cache eviction never deletes remote objects or graph asset entities.

### UI behavior

Render graph text immediately, including on launch of the most recently opened
graph. Asset downloads are not part of the startup barrier. Preserve media layout
using known dimensions and a placeholder. Use existing native progress and retry
components, respect the three-divider limit, and expose per-asset failure without
blocking the timeline. A cached asset remains usable offline under account policy.

### Delivery sequence

1. Review descriptor, query, transfer and cache contracts for the confirmed scope.
   Record required spec interface changes before implementation.
2. Implement explicit single-asset GET, E2EE decoding and verified atomic cache
   publication. No bootstrap-wide downloader is introduced.
3. Wire renderer demand through app policy and worker orchestration. Verify
   visible priority and lifecycle fencing.
4. Add bounded recent/favorite discovery, incremental invalidation, retained
   reasons, storage limits and restart reconstruction.
5. Verify protocol interoperability and representative UI behavior at the owning
   boundaries. Download policy and scheduler behavior belong in public pure
   reducer tests; codec/store tests own only actual binary/filesystem behavior.

### Upload architecture (included in this phase)

Uploads are triggered by explicit local import/replacement, independently of the
selective download union. An attachment added to an old journal still uploads.
Never derive upload intent from a missing local cache file or from remote graph
transactions. Reuse existing attachment bytes when the user adds another reference.

The app invokes an import command with a native source handle and target location.
`logseq_db_worker` owns the durable upload workflow and graph mutation coordination;
`logseq_sync` owns execution of an explicit upload request, auth and encryption.
`logseq_db_storage` stores upload intents/checkpoints with the worker's durable
state. The asset cache adapter stores staged files, using a non-evictable pending
namespace. These are separate from disposable downloaded cache entries.

The conceptual durable phases are `Prepared -> Local_committed -> Uploading ->
Remote_stored -> Metadata_pending -> Complete`, with retry and cancelled outcomes.
Each intent has a stable operation ID, graph/account scope, fresh asset UUID,
plaintext checksum/type/size, staged file handle, target mutation ID, and phase.

1. Copy the native source into app-owned staging, validate size/type, compute
   plaintext SHA-256 and optional dimensions, and persist a prepared intent.
   A temporary picker URL must not be the only surviving copy.
2. Apply the asset entity and its attachment reference through the graph mutation
   owner with a stable mutation ID. It has local metadata but no `remote-metadata`
   yet. Local UI can read the staged file immediately; remote clients may see a
   pending asset. Reconcile prepared intents after a crash by checking the public
   mutation outcome/entity, not by blindly duplicating the insertion.
3. Schedule an immutable upload job through `logseq_sync`, using the correct graph
   key for E2EE and upstream checksum/type headers. Pending source files remain
   protected even when not visible or within the recent/favorite scopes.
4. After successful PUT, persist `Remote_stored` before requesting graph metadata
   publication. Through the worker's normal mutation/outbox path, publish the
   matching remote checksum/type only if this intent/entity is still current.
   Persist that mutation's identity and await its synchronization acknowledgement.
5. Mark complete and release pending-file protection only when the remote object
   upload and graph publication are both durable. The verified local file can
   then become a normal cache entry. An offline edit can therefore be locally
   saved while still displaying upload-pending status.

Recovery is a forward-recoverable workflow across filesystem, local DB and server,
not a distributed atomic transaction. A crash after copying but before persisting
an intent leaves only an orphan staging file for bounded cleanup. A crash after
local mutation or metadata mutation is resolved using the stable mutation identity
and graph state. An uncertain PUT may be retried for the same immutable asset;
an acknowledged PUT with pending graph publication resumes only that publication.
Lost acknowledgements never cause a second asset entity to be created.

For binary replacement, this app creates a new asset UUID and updates the intended
reference, instead of overwriting another device's object under the same UUID.
Changes to title/dimensions that do not change bytes remain ordinary graph edits.
The inspected server handler writes to a mutable object key and does not perform
an If-Match/CAS check; client scheduling alone cannot guarantee conflict-free
cross-device in-place replacement. External Logseq clients may still overwrite
existing objects, so downloads retain checksum verification and mismatch recovery.
Do not claim server-level version history or strong conflict resolution.

If a reference is removed during upload, distinguish reference removal from asset
entity deletion: other references may still need the object. If the entity/intent
is cancelled, fence its completion so it cannot recreate metadata. A completed
remote PUT can leave an unreferenced remote object; do not issue eager DELETE from
this workflow, since it may race with another reference/device. Remote garbage
collection and destructive asset deletion are outside this phase. Pending local
uploads remain durable across restart; ordinary cache pressure cannot delete them.
Explicit local graph deletion applies the existing destructive-data UX to these
files as well and must not silently report a pending upload as completed.

Use bounded upload concurrency under the same overall IO budget as downloads,
with foreground downloads prioritized and fair progress for durable uploads.
Retry network/auth failures; classify size rejection, missing source, revoked
access and invalid content separately. No historical graph scan creates upload
jobs. Upstream currently limits plaintext assets to 100 MiB; verify deployed
server limits and encrypted envelope overhead before accepting an import.

Delivery adds the durable import/upload workflow after single-asset transfer and
before final end-to-end verification. Public worker reducer tests cover crash
recovery, duplicate completions, cancellation, metadata publication ordering and
outbox acknowledgement. Protocol checks prove that a Logseq client can download
and decrypt an uploaded fixture and that this app can read a Logseq upload.
These checks have distinct ownership from scheduling tests.

Implementation is authorized, including the necessary `.mli` files under `spec/`
and dune declarations. The bonsai_flutter repository remains outside this change.
Contract additions are required before behavior can be exercised through public
interfaces: a shared validated asset descriptor, a separate asset transfer reducer
with scoped demand and completions, cache and binary transport dependencies,
bounded worker asset reads, and durable worker import/upload transitions.
The transfer reducer must expose backpressure instead of discarding demands;
worker upload transitions must expose persistence acknowledgements separately
from HTTP and graph mutation acknowledgements.

### Implementation checkpoint

This decision is still proposed: the application feature is not complete.

Implemented foundations:

- `logseq_db_types/Asset_descriptor` separates the published version from the
  current entity checksum and validates checksums, types, sizes and dimensions.
- `logseq_sync/Asset_transfer` is a separate public pure reducer. Its tests cover
  demand reasons, coalescing, foreground active/pending reservations, explicit
  backpressure, finite retry, offline cache, locking and stale completions.
- `logseq_sync/Asset_codec` implements the raw-binary Transit AES-GCM envelope,
  explicit plaintext/wire limits and plaintext checksum verification. Current
  codec tests use injected crypto; they are not upstream interoperability proof.
- `logseq_sync/Asset_cache` provides scoped verified files, atomic publication,
  lazy restart validation, retained handles and an eviction budget. The runner's
  explicit asset GET path uses the existing token/key owners. Independent TLS
  peer tests cover successful GET, checksum mismatch and token refresh.
- Public overlay queries discover descriptors under explicit roots with bounded
  continuation work, including direct properties and effective subtree deletion.
  They do not expand ordinary links. Tests include more than 200 references.
  Worker `getAssetDescriptors` and `listAssets` commands expose these queries.
- `logseq_db_worker/Asset_upload` models durable phase acknowledgements and crash
  recovery separately from PUT and graph publication. `Asset_upload_store` supplies
  SQLite checkpoint compare-and-set and scoped paginated recovery. The native import entry point now submits durable explicit imports.

- The worker now owns a scoped live asset session, exact transfer-ticket checks,
  lifecycle cancellation and independent asset notices. Bonsai service ports connect
  the verified cache/GET runner and expose retained file leases to presentation.
- `Journal_asset_policy` enumerates recent journal roots and complete favorites in
  bounded pages, waits for demand acknowledgement, pauses/resumes on backpressure,
  retains committed demand during replacement and fences stale query revisions.
  Public reducer tests cover local-calendar boundaries, continuation pages, demand
  replacement, visible priority, external exclusions and page bounds.
- Application graph opening, graph change notifications and foreground calendar
  refresh now drive the background policy through bounded worker requests. Asset
  queries do not participate in the graph text startup barrier. The runtime retains
  unsent instructions when the worker queue is full and separates asset read errors
  from the graph transaction stream.

- Account logout and local graph deletion now remove the appropriate verified
  cache namespace; deletion failures propagate through the existing lifecycle.
  Filesystem tests verify graph/account/origin isolation and idempotent cleanup.

- The runner exposes an explicit immutable staged-file PUT operation. It checks
  source size/checksum before IO, uses scoped graph-key ownership and the binary
  codec, sends upstream checksum/type headers, refreshes authentication and rejects
  upload redirects. Independent TLS peer tests verify actual bytes/headers, token
  refresh, revoked access, size rejection and transient failures. Staging validation
  also rejects missing/changed sources, locked graphs and cancelled intents.
  Worker upload effects now invoke this transport operation after durable staging checkpoints.

- The cache adapter has an explicit durable staging API in a non-evictable pending
  namespace. It copies with bounded buffers, computes SHA-256, enforces per-file,
  pending-byte and file-count limits, fsyncs and atomically publishes immutable
  operation files. Restart removes partial copies while preserving completed staged
  sources. Existing graph/account cleanup removes this namespace too. Tests cover
  picker-file removal, restart, cache pressure, immutable operation IDs, limits,
  release and graph deletion. Upload checkpoints now persist the attachment title.

- Ordinary `Insert_blocks` mutations now support validated asset metadata for one
  explicitly imported block. Effective reads expose that pending asset immediately,
  without remote metadata. `Publish_asset` is a separate mutation with a public
  `publish_asset_metadata` entry point; it requires the live checksum/type to match
  the uploaded version. Replanning fences removed/replaced entities. Both operations
  use the existing outbox and restart path; public database tests cover import,
  duplicate identity, subtree discovery, publication and reopening pending mutations.
  Outbox format v15 replaces v14 because the persisted mutation shape changed; no
  compatibility reader or migration was added. Asset insertion satisfaction now
  checks asset metadata as well as tree structure, and publication satisfaction
  checks the remote descriptor independently of title changes.

- The worker owns bounded upload sessions with exact completion tickets and cancels
  retired graph sessions. Its effect runner persists intent checkpoints in a private
  SQLite sidecar, applies asset mutations through the public overlay API, executes
  one PUT at a time, and waits for the metadata mutation to leave the pending outbox
  before acknowledging publication. Recovery inspection distinguishes durable mutation
  receipts from pending publication. IO tests reopen the sidecar independently and
  verify stale tickets cannot publish completions. Cleanup failures remain observable
  and retain terminal checkpoints for later recovery. Source-boundary checks permit
  only the upload intent store, not raw graph storage access, from the worker.

- Graph attachment now starts scoped upload recovery from the actual SQLite store.
  Public reducer tickets fence each page by graph lifetime, cursor and serial.
  Recovery reads at most 16 rows per page and reserves capacity in the 32-session
  queue; enumeration pauses when full and resumes after terminal sessions release
  capacity. It rejects invalid ordering, duplicate identities and foreign owners
  before restoring any row. Explicit online recovery retries failed enumeration
  and failed active uploads. Pure tests cover paging, backpressure, invalid pages,
  late completions and retry fencing.
- Account secret deletion and local graph deletion now clear scoped intent records
  as well as staged/cache files. Storage tests verify idempotent graph cleanup,
  account/origin isolation and persistence after reopening.

- The native detail toolbar now provides an Attach file button backed by SwiftUI
  `fileImporter`. Security-scoped access is retained until the worker acknowledges
  durable staging and intent persistence, or the native owner is disposed. Each
  selection uses fresh asset and mutation identities. The bounded worker command
  validates the current graph/capacity before staging, restores repeated operation
  identities without recopying picker files, and connects to the existing recovery
  reducer. Import errors are shown in a native alert. IO tests verify persistence
  before success, duplicate requests and stale admission. The macOS native build
  passes; rendered/native interaction verification is still outstanding.

- Asset discovery now requires an explicit recursive flag. Visible-content queries
  read only the supplied entities and their direct asset references/properties;
  background policy still traverses the selected subtrees. Continuation cursors
  bind the discovery mode, so a subtree cursor cannot expand a visible query.
  Public database tests verify hidden descendants and ordinary page links are
  excluded from direct queries.
- `Journal_media` owns the presentation lease lifecycle through public pure events.
  It requests demand only for shown managed assets and exposes a file path only
  after retaining its cache handle. Hiding or replacing a version releases the
  lease; stale acquisitions are released and duplicate completion cannot release
  the displayed lease. Lease-acquisition retry is distinct from network retry.
  External URLs remain outside managed download demand. The owner is tested but
  now connects to the worker adapter and native detail media view.

- The detail view now queries direct assets through `Journal_media_runtime` and
  displays them through a native SwiftUI extension. Metadata alone does not issue
  GETs. The adapter accepts foreground demand events, but native automatic
  visibility delivery is deferred by the user decision below.
  The adapter retains and releases worker file leases, fences late query/file
  responses by owner lifetime, and clears leases on navigation or graph changes.
  Cached metadata retains placeholder dimensions while a row is offscreen. Queries
  and rendered attachment pages are limited to 16 items, with at most 64 root owners.
  Capacity notices retry only demands that actually received backpressure.
- Native image display uses serialized ImageIO thumbnails capped at 1024 pixels,
  a 32 MiB thumbnail cache, shared placeholder/image sizing, and native Quick Look
  for opening files. External attachments use explicit links. The macOS native
  build passes. Adapter tests verify metadata/download separation and retained-path
  delivery. Native list verification and its limitation are recorded below.

- Timeline and Favorites now provide media roots for their displayed sources,
  including each Timeline child summary. Native widget identity and event admission
  include graph/route scope so retired surfaces cannot submit current demand.
  The Timeline source-target test was observed failing before implementation and
  passes afterward.
- A standalone macOS probe using production `JournalMedia.swift` reproduced a
  native delivery limitation: `onScrollVisibilityChange` reports all twenty list
  attachments as visible on initial construction, including offscreen rows, and
  does not update on scrolling. Initial callbacks also precede interactive native
  presentation. The same probe's Retry button successfully reaches OCaml, isolating
  the failure from the event bridge. No pure reducer can reproduce native viewport
  measurement; the reproduction therefore exercises the renderer boundary only.
- The user explicitly chose to keep native components and defer visible-attachment
  triggering rather than authorize custom AppKit/UIKit visibility coordination.
  The unsupported scroll callbacks have been removed. Automatic foreground demand
  from native list visibility is **not delivered** and is excluded from this
  delivery's acceptance until that decision is revisited. The pure owner/runtime
  remain available, but native rows currently do not initiate media discovery or
  foreground download. Background recent-journal/Favorites demand is independent.

- Downloaded remote cache filenames are now audited and fixed. The asset cache
  records each version's validated `file_type` and stores payloads as
  `<checksum>.<file_type>`, so deferred remote presentation hands native viewers
  a correctly suffixed path, matching the staged-import filename fix. Legacy
  `.bin` payloads are evicted on cache open. Filesystem tests cover extension
  naming and legacy cleanup.

- Binary transfers now share a bounded byte budget in addition to the lane and
  codec semaphores. Each admitted download or upload reserves its worst-case
  wire-plus-plaintext footprint in 64 KiB units against a shared 64 MiB budget,
  so the transfer lanes bound request counts while the semaphore bounds
  in-flight bytes. Reservation sits inside the lane slot and shares the codec
  permit ordering, so no new deadlock order exists. A public runner test
  observes the three download slots admit only two concurrent 16 MiB
  reservations under the budget and admits the rest after release.

- Binary replacement and reuse-existing-reference flows are now wired to native
  UI. The detail media group exposes a native `Menu` with "Replace file…" and
  "Reuse existing…" when the group is the editable detail root. Replace first
  reads the holder block through the worker (`V2_get_block`) and arms the
  import picker with the holder's current asset reference — the durable import
  intent's `replace_reference` must equal the reference the holder currently
  carries, because the commit rejects the whole mutation on a stale expected
  value — and picker dismissal clears the armed state. A holder with no current
  asset reference arms the picker with no expected reference, degrading to a
  plain import. Reuse reads the holder block through the worker for its page
  and expected reference, enumerates managed assets under that page through
  `V2_list_assets {recursive}`, and commits `V2_set_asset_reference` with the
  holder's block-revision precondition; a successful commit re-queries the group
  through the ordinary completion path. Media-runtime boundary tests cover
  holder lookup, page-scoped candidate enumeration, atomic repointing with the
  exact previous reference, and picker teardown.

- Representative native UI verification is now complete on the adhoc-signed
  iOS Simulator against graph `ocaml-sync-test` (lldb-traced): the
  `journal-media-actions` menu exposes Replace file… and Reuse existing… on the
  editable detail-root group, Attach shows the staged local preview
  immediately, Reuse enumerates/selects/cancels candidates and commits
  `V2_set_asset_reference`, and cached filenames carry the real extension.
  The run exposed and fixed three iOS defects: `URL.path` binding the
  `path(percentEncoded:)` method reference crashed every pick; the replace
  auto-present guard dropped the armed request; iOS `fileImporter` never
  invokes its completion on cancel, so closing an armed picker is now
  detected and reported as dismissal. Follow-up verification exposed
  three more: the armed replace picker sent the attachment holder's uuid
  as `replaceReference`, so the local commit rejected the mutation as a
  stale expected reference and the upload failed non-retryably — the
  runtime now resolves the holder's current asset reference
  (`Entity_value` under `logseq.property/asset`, the variant
  `asset_reference_matches` requires) through `V2_get_block` before
  arming; the reference reader previously matched `Asset_value`, which the
  store never writes, so reuse-select's `previous` fence was always
  `None` and `set_asset_reference` rejected on referenced holders; and
  media groups only registered through the import-completion path, so
  replace/reuse actions were inert on cold-open detail views — menu
  actions now lazily register the group through the ordinary
  root-visibility path. Media-runtime tests cover arming with the
  expected previous reference and cold-open lazy registration. macOS
  interactive sign-in remains environment-blocked (-34018 keychain
  entitlement; no development
  certificate on the verification machine) — iOS is the representative path
  since the widget and runtime code are shared. Deployed server import
  limits remain unverified (no live-server access); code-level caps are
  verified — the application admits 8 MiB files, the runner rejects PUTs
  above 100 MiB, and encrypted envelope overhead is fixture-verified.

Remaining delivery work:

- Audit every acceptance criterion and complete the lifecycle transition.

Real asset E2EE interoperability now passes in both directions. The native lane
executes the unchanged upstream crypt namespace with WebCrypto, the standard
Transit Uint8Array handler, the public OCaml asset codec, the production C bridge,
and production Swift CryptoKit implementation. Synthetic fixtures cover 0, 1, 256,
and 4097 bytes; wrong keys, wrong checksums, and corrupt ciphertext/tag bytes are
rejected. See `docs/test-reports/2026-09-19-asset-interop/README.md` for exact
boundary coverage, saved fixtures, source hashes, and the reproducible command.
This proves raw binary interoperability and measured envelope overhead, not live
server limits or large-file memory behavior.

Upload PUT admission now follows the worker's foreground/network and graph-key
availability, matching the existing download admission facts. The upload owner
retains its durable Uploading checkpoint while paused, cancels an active PUT by
exact ticket, ignores its late completion, and issues a fresh ticket on resume.
Local persistence and explicit cancellation still run while paused. Recovery and
manual retry cannot bypass the transfer gate. Three public pure-owner tests were
observed failing before the behavior was implemented and passing afterward; they
cover paused recovery, an active PUT with stale completion and cancellation, and
availability changing during durable checkpoint persistence. No duplicate runner
or transport regression tests were added for these owner transitions.

The Account menu now exposes Attachment settings through a native grouped Form
and Stepper. Device-local UserDefaults persist recent journal days (default 7,
range 0–3660; zero disables only recent-journal downloads). Favorites retain their
complete subtree policy. Invalid persisted values use the documented default and
invalid changes are rejected. Background asset enumeration waits for the native
preference delivery; text/graph startup does not. A setting change refreshes the
current graph's asset policy through the existing replacement-demand protocol.
Preference persistence and event validation tests were observed failing before
implementation, then passing. An isolated macOS native probe verified initial
delivery, opening the form, changing 7 to 8, closing it, and delivering 8 after
process restart. The final grouped layout has no clipped text and at most three
dividers. iOS interactive verification remains outstanding.

Attachment settings now shows separate recent-journal and Favorites offline
status. Policy completion remains an enumeration fact: availability notifications
are tracked separately by consumer and asset version, and the UI reports complete
offline availability only when enumeration has finished and every discovered
managed version is Ready. Duplicate versions count once. Waiting, capacity limits,
enumeration failures, and failed downloads remain visibly incomplete. Replacement
scans cannot reuse the old scan's completeness claim; released consumers and late
notifications cannot resurrect a count. The pure-owner test was observed failing
before tracking was added, then passing. Runtime forwards scoped availability
notices and publishes changed summaries to the app. A native macOS probe verified
representative partial and complete labels in the existing Form without clipping
or adding separators; it did not simulate actual network transfers.

Foreground calendar refresh now uses the app-owned Bonsai clock at a bounded
one-minute cadence. OCaml's existing sampler remains the sole calendar owner;
only a changed local day/projection installs a new calendar and refreshes the
feed/asset policy. Background and termination suppress sampling, while startup
and foreground-resume sampling remain immediate. This explicitly supersedes the
no-periodic-sampling clause in
`implemented/architecture/2026-09-04-ocaml-unix-owned-calendar.md` to satisfy this
decision's day-rollover requirement. It does not restore the removed native
calendar protocol. A headless app dispatch test
with an injected calendar clock was observed failing at foreground midnight,
then passing after the watcher was connected. It delivers a two-day preference
through the native-widget event interface and verifies that the asset interval
advances from August 30–31 to August 31–September 1. Another tick with unchanged
calendar facts does not restart enumeration.

Terminal upload cleanup is now verified through the real staging-cache and SQLite
boundaries in the existing worker IO test. Explicit import staging copies actual
bytes, and the picker source is deleted before recovery. A durable Complete
checkpoint is reopened independently and remains included in scoped recovery.
Closing the cache makes the first cleanup fail through its public API: the runner
publishes a diagnostic, retains the file, and leaves the checkpoint intact. A new
runner with a reopened cache restores that checkpoint, deletes the staged file,
and accepts repeated cleanup idempotently. This validates the existing terminal
cleanup behavior independently from orphan reconciliation.

Orphan staging reconciliation now runs before the first import or recovery page
for the active scope. The worker serializes reconciliation with the complete
stage-and-checkpoint transaction. It checks UUID-named regular staging files
against SQLite and preserves every matching intent, including terminal records.
Unknown names and symlinks remain untouched. Filesystem enumeration is limited to
4,096 entries; capacity or ownership-check failure aborts before any deletion.
The cache test verifies fail-closed behavior, the entry bound, symlink handling,
and idempotency. The real worker IO test verifies that a stale request does not
clean, a valid import removes an orphan, and restart preserves durable terminal
staging for its separate cleanup path.

Binary transfer admission now belongs to the sync effect runner. Its fixed overall
four-transfer budget reserves one permit for uploads and three for downloads
across graph scopes. The download reducer uses three active slots with one
reserved for foreground demand; the upload lane cannot be starved by background
downloads. Upload admission precedes source reading/encoding, and download
admission covers HTTP, decoding and cache publication. Failure and cancellation
release the permit. The former worker-only upload semaphore is removed. Tests
through public runner APIs observed three overlapping uploads and five overlapping
cross-scope downloads before the gates, then verified limits of one and three and
continued progress after failures. These tests own actual Eio admission rather
than duplicate pure demand scheduling. The application still caps individual
files at 8 MiB; shared codec/byte accounting remains to be completed.

Asset decoding now checks the two-string array envelope shape before invoking
the general Transit parser. This preflight scans without constructing a JSON or
Transit tree, rejects nested/wide structures and trailing data, and preserves
JSON whitespace and string escapes. Public codec allocation tests reproduced
more than 1 MiB of allocation for malformed, size-admitted structures before the
preflight, then passed the bounded-allocation check. No crypto call is made for
these shapes. Real upstream/native AES-GCM interoperability was rerun successfully
in both directions after the change; the saved report and fixtures were refreshed.
This bounds malformed structure expansion, not total process RSS.

The staging cache now exposes preview leases through its existing handle/path
lifetime. Upload completion retires a staged file but defers deletion until its
last lease is released; no new staged preview can start after retirement. Closing
the cache invalidates leases and completes deferred cleanup, while nonterminal
staging remains durable. Orphan reconciliation skips files with active preview
leases. Public filesystem tests cover two simultaneous leases, completion during
preview, repeated cleanup, close, and preservation of nonterminal staging. The
initial missing-lease test failed before implementation and all cases now pass.
The Bonsai service now exposes scoped `Acquire_imported_file` requests. The
worker reads the durable operation checkpoint, rejects cancelled or foreign
origin/account/graph ownership, and acquires a staged lease through the sync
adapter. The worker facade also fences the current graph scope. Existing
`Asset_file` responses and release requests carry the resulting lease. The real
SQLite/file test verifies successful acquisition and cross-account/graph
rejection. Import success now returns a scoped receipt with a staged lease acquired before
upload dispatch, closing the fast-upload cleanup race. The application accepts
only the current detail target, passes the receipt to the existing media runtime,
and renders its file through the native image/Quick Look component without
starting a binary demand. Reset and stale receipts release leases through the
existing backpressure-aware request queue. Duplicate receipts do not release the
live lease. Local media retains its file type separately from graph metadata and
does not pretend that remote metadata is published. Each group admits up to 16
local previews, reports preview capacity explicitly, and suppresses a duplicate
metadata item for the same asset. The native component admits the bounded union
of local previews and its existing 16 metadata items. Runtime tests cover direct
presentation, zero query/download on import, route reset, stale receipts and
duplicate receipts; macOS host compilation passes. Interactive native acceptance
is still outstanding. A deferred unlink failure leaves the terminal checkpoint recoverable
for the existing restart cleanup path.

The upload reducer now exposes a presentation status independent of the last
durable phase: preparing, waiting for availability, sending, publishing,
cancelling, uploaded, cancelled, or a typed failure. A successful PUT remains
publishing until the final checkpoint is durable. Pause/resume, retry, stale
completion, cancellation and shutdown are tested through public reducer events.
The worker publishes changed scoped upload-status notices with operation, asset,
target and title, including terminal notices before retiring the in-memory owner.
Availability changes participate in the same notification path; duplicate/stale
completions do not repeat notifications. The existing asset topic carries these
notices through Bonsai service. The native Attachment settings Form now displays these states with built-in
progress indicators and per-file Retry buttons. A pure application model retains
at most 32 entries, prioritizes active tasks over terminal history, ignores foreign
scope notices, and clears on graph lifecycle changes. Retry admission checks the
current operation's failure and graph context before emitting `Retry_upload` to
the worker owner. Missing sources, size rejection and invalid content ask for a
new attachment instead of offering an ineffective retry. The Form keeps uploads
inside its existing grouped row, so individual uploads add no dividers. Public
model tests cover scoped status, exact retry routing, terminal behavior, graph
switches, failure classification and bounded retention. A macOS native probe with
synthetic failed/publishing/uploaded rows verified layout, built-in scrolling,
three dividers, accessible Retry labeling, and the exact operation ID emitted by
the Retry button. This probe validates the native UI/event boundary, not a live
server retry. iOS and end-to-end native import/preview acceptance remain open.

The maximum-file interoperability lane exposed and fixed a native bridge limit:
valid ciphertext for a 131057-byte asset exceeded the old 128 KiB hex input cap.
AES plaintext now admits 8 MiB and ciphertext admits 8 MiB plus its 16-byte tag;
other key-management inputs retain their smaller cap. Six real WebCrypto/CryptoKit
sizes now include the application maximum and reject an over-limit plaintext.
Swift hex conversion uses bounded byte buffers instead of per-byte strings, and
the C entry point drains Foundation temporaries in an autorelease pool. The same
native workload's measured peak RSS fell from 753287168 to 293224448 bytes and
passes a 384 MiB regression gate. This is a native codec/bridge measurement;
the production OCaml adapter is measured separately below. Concurrent application
accounting remains outstanding.
The source owner of the size failure is the native bridge, which pure upload or
transfer events cannot execute; the regression stays in the real interoperability
lane rather than duplicating it in reducer or transport tests.

Attachment GET and PUT now share one codec permit per sync runner, in addition
to their existing three-download/one-upload transfer permits. Download responses
may wait as bounded wire bodies, but parsing, decryption, checksum verification
and cache publication run inside the codec permit. Upload source reading,
checksum verification and encoding use the same permit, released before HTTP PUT.
Waiters recheck request currency before expanding buffers. The public runner test
holds an upload encoder while a real TLS GET completes; before the gate it observed
two simultaneous codec calls, and afterward one. The upload's encoding failure
releases admission and allows download decoding to complete. This verifies actual
Eio resource admission without moving download-demand scheduling out of its pure
owner. Production-adapter measurements follow below; whole-application memory
measurements remain outstanding.

The existing TLS test peer's readiness file is now published atomically and its
dual-stack ephemeral port reservation retries collisions. Both test-harness races
were observed during the full suite before any production asset request began.

A native macOS preview probe reproduced a staging filename defect: Quick Look
classified a valid PDF staged as `.bin` as a MacBinary archive and offered
Uncompress instead of displaying its content. Staging now requires the validated
attachment file type and uses `<operation>.<file_type>` throughout copying,
checkpoint ownership reconciliation, preview leases, and orphan pruning. Public
filesystem tests first failed for the missing extension and invalid file types,
then passed with the fix; existing lease cleanup and restart coverage still pass.
The production state owner for this defect is the filesystem cache: pure upload
reducers neither choose preview filenames nor invoke Quick Look, so no duplicate
pure or transport regression was added. A native probe using the unchanged
production JournalMedia component now displays the PDF text "Local staged preview".
This verifies the native filename boundary, not a complete live import session.
Downloaded cache filenames and deferred remote presentation remain to be audited.

The full unsigned iOS application build also passes and its Mach-O platform is
IOS. Interactive iOS acceptance remains open: the paired iPhone was unavailable
and no simulator was booted during this check.

The production OCaml adapter allocation check now executes an 8 MiB upload through
the public runner with `apple_crypto`, using a graph context obtained from public
reducer events and the actual key-load completion. Synthetic secrets avoid
Keychain access; token acquisition stops the request only after successful asset
encoding, before networking. The former per-byte hex formatting/parsing allocated
3140152650 OCaml bytes; direct byte conversion reduces this to 229294405 bytes,
passing a 256 MiB cumulative allocation gate. The isolated production-adapter
process peaks at 256786432 bytes RSS, below its 384 MiB gate. Small production
adapter encrypt/decrypt roundtrips and maximum-size upstream interoperability
also pass. The reproducible command and source hashes are in the interoperability
report. Whole-application and concurrent-download/image memory remain unverified.

The subsequent binary ABI removes AES payload hex/JSON conversions entirely.
C copies bounded input bytes before releasing the OCaml runtime, Swift returns
malloc-owned ciphertext/plaintext, and C validates the exact output length before
publishing an OCaml string and freeing native buffers. Empty files, malformed key
and nonce lengths, truncated tags, authenticated rejection, and the 8 MiB boundary
are covered by the native interoperability lane. Key-management JSON remains;
the old AES JSON operations were removed. The same production upload now allocates
86685706 OCaml bytes and peaks at 125616128 bytes RSS, passing tighter 128 MiB
allocation and 192 MiB process RSS gates. The previous 229294405-byte implementation
fails the new allocation gate. The wire protocol is unchanged. Full unsigned macOS
and iOS builds pass, and both native products export the binary entry point.

The graph mutation owner now provides `Set_asset_reference` and the public
`Database.set_asset_reference` entry point. It sets one holder block's
`logseq.property/asset` to an existing asset, with a mandatory expected previous
reference plus the ordinary revision precondition. It does not change attachment
bytes or asset metadata. Its stable identity, normalized transaction, receipt,
outbox encoding, dependency ordering, logical projection, acknowledgement checks,
and remote replanning participate in the existing mutation machinery. A queued
reference to a locally introduced asset depends on the asset insertion. Replanning
blocks the operation if the intended reference changed or the asset disappeared.

Bounded asset enumeration now includes local property overrides, including targets
without authoritative entity IDs. Public database tests cover adding/replacing a
reference, retaining other holders and old asset metadata, duplicate identity,
invalid destinations, local-only asset targets, restart, and remote reference
conflicts before and after restart. The initial public reference operation failed
before implementation; enumeration then exposed and fixed omission of new local
properties. These tests execute the graph mutation owner, not an upload simulator.
Native selection/replacement UI and binary replacement workflow integration remain
open; this graph primitive alone does not complete those flows.

The worker protocol now exposes `setAssetReference` with mutation ID, holder,
expected previous reference, asset UUID and ordinary write preconditions. It uses
the same graph request admission and mutation execution path as other edits.
Wire tests first rejected the missing command, then passed roundtrips for empty
and populated previous references plus malformed UUID rejection. A real worker
fixture restores a locally introduced asset, submits the public command, observes
the change push and queries the new reference. Its byte IO capabilities reject
unexpected calls, proving this route does not stage, download or upload bytes.
The existing macOS mutation-runtime suite also passes with current runner
capabilities and reducer-owned currency checks. Native UI wiring remains open.

Binary replacement now travels in the durable import intent as an expected old
asset UUID. Preparing an intent rejects reusing that UUID for the new bytes, and
idempotent import recovery compares the replacement parameter too. The upload
checkpoint stores the field explicitly; its SQLite restart tests include a
replacement target. The native append picker explicitly sends no replacement
until the replacement action is wired.

The graph insertion's asset metadata carries this parameter. One normalized
transaction creates the new asset and redirects the holder's asset property;
its projection, affected-block revisions, acknowledgement checks and replan guards
include both changes. Thus there is no second reference-mutation checkpoint to
lose after a crash. A stale expected reference rejects the whole commit without
leaving a new entity. Public graph tests cover old bytes/metadata and other-holder
preservation, idempotent retry, local query visibility, restart, and a remote
reference edit blocking both insertion and redirection. Outbox format v16 replaces
v15 and the obsolete serializer module is removed; no migration path is added.
The existing upload phase machine remains unchanged and uses this atomic local
mutation before PUT. Native replacement/reuse UI and its end-to-end acceptance
remain outstanding.

## Decision

Implement selective asset synchronization as proposed. The application owns the
download-demand policy — N recent journal days (default 7, configurable, zero
disables) plus complete Favorites subtrees without recursive ordinary-link
expansion — delivered through the sync package's explicit demand protocol rather
than in-view downloads. Metadata synchronization stays comprehensive; binary
transfers run only for admitted demand.

Binary transfers admit through bounded lanes: three download slots, one upload
slot, one codec permit, and a shared 64 MiB byte budget reserving each
transfer's worst-case wire-plus-plaintext footprint. The staging and download
caches keep real file extensions, preview leases survive upload completion, and
orphan reconciliation runs before each import or recovery page.

Attachments are `logseq.class/Asset` children of their holder block, referenced
by the holder's single-valued `logseq.property/asset`. Upload stages locally,
imports atomically create the asset entity and redirect the reference inside one
transaction, and the durable import intent carries the expected previous
reference for replacement. `set_asset_reference` repoints a holder to an
existing asset under the ordinary revision preconditions; native UI exposes
Attach, Replace, and Reuse flows on the editable detail-root media group.

Native automatic visible-attachment demand is deferred by explicit user
decision: no scroll-visibility workaround or custom AppKit/UIKit coordination
was added. Remote garbage collection and destructive asset deletion remain out
of scope, and no server-CAS claims are made.

## Alternatives considered

### Download all missing files after bootstrap

Rejected because it violates selective download requirements even with low
concurrency. All metadata can be synchronized without fetching all binaries.

### Put journal and favorites policy inside logseq_sync

Rejected because these are application decisions. A reusable sync package should
accept explicit asset demand and provide transport/cache primitives.

### Let each view download its own assets

Rejected because it duplicates transfers, loses lifecycle ownership, and cannot
prefetch recent/favorite assets independently of mounted views.

## Acceptance criteria

The native visible-attachment clauses below are deferred by the explicit scope
adjustment above. All other clauses remain required for this delivery.

- Opening a graph with many historical assets issues zero binary GETs outside
  the app demand union; metadata arrival alone never queues a GET.
- Multiple visible and background consumers share one transfer for a version;
  foreground demand takes priority over queued background work.
- Complete recent/favorite scope enumeration works beyond the first page and
  across collapsed UI content, with bounded queue and query memory.
- Day rollover, favorite removal, graph edits and version replacement update
  demand without cancelling another active reason or publishing stale bytes.
- Local imports survive restart and upload even outside download scope; remote
  metadata is never published before a successful PUT. Duplicate completions and
  recovery do not duplicate assets or revive cancelled entities.
- E2EE fixtures from Logseq decode and verify correctly; corrupt ciphertext,
  wrong checksums and interrupted writes never become ready cache entries.
- Offline, 404, logout, graph switch and cache pressure preserve coherent states
  and do not block text synchronization or graph startup.
- Deterministic policy/reducer tests use public events, completions, state and
  effects. IO and interoperability checks cover distinct boundary behavior rather
  than duplicating scheduler scenarios at every layer.

## Risks

- The remote object URL is mutable, so metadata and bytes can temporarily disagree.
  Server-side CAS/version history is unavailable in the inspected upload handler;
  new UUIDs avoid this app initiating in-place binary replacement conflicts.
- Reference discovery must cover the admitted schema's asset-valued properties and
  rendered references; a title-only search would miss assets.
- Complete favorites may exceed available storage. Offline completeness must be
  observable instead of silently narrowing the favorite set.
- Encrypted binary Transit interoperability and memory limits need fixture-based
  verification before promising large-file support or resumable downloads.
- OS background execution is limited. Prefetch initially runs while the app can
  execute and resumes later; this is not a promise of perpetual background work.

## Consequences

- All binary traffic now travels through admitted, bounded lanes. Concurrent
  transfers can no longer exceed the shared byte budget even when lane slots
  would admit them, and a single oversized operation reserves the whole budget
  rather than deadlocking.
- Downloaded and staged cache payloads carry real file extensions, so native
  viewers classify deferred and previewed files correctly; legacy `.bin`
  payloads are evicted on cache open rather than migrated.
- Attachment references can be repointed atomically from native UI. Replace
  flows reuse the durable import intent so a crash mid-replacement cannot
  strand a half-updated holder, and Reuse commits through the ordinary
  mutation machinery with previous-reference and block-revision fences.
- The editable detail-root media group now exposes replace/reuse actions; the
  menu appears only where the import target is current, keeping foreign or
  read-only surfaces inert.
- Native automatic visible-attachment demand remains undelivered by explicit
  decision. Rows still initiate media discovery through the explicit query
  path; scroll-driven foreground demand requires revisiting that decision with
  a sanctioned visibility mechanism.
- Deployed server-side import limits are unverified; the application's 8 MiB
  file cap, the runner's 100 MiB PUT rejection, and the encrypted-envelope
  overhead are the only verified bounds.
- Representative native verification ran on iOS Simulator; macOS interactive
  sign-in needs a development certificate unavailable on the verification
  machine. The verified widget/runtime code is shared across platforms, but
  macOS-specific behavior (e.g. fileImporter cancel semantics there) has not
  been exercised end to end.
