# Porting Login and Upstream-Compatible Graph Sync to Logseq Journal

## Problem

`logseq_journal` currently starts directly against one local Logseq graph chosen by
the native host. It has no account session, authorized graph catalog, remote snapshot
bootstrap, replay cursor, or continuous graph transport. The requested change is to
reuse the login, graph-selection, snapshot, and local-first lessons from `../chat`
while making the sync wire protocol match upstream Logseq. The result must not move
graph protocol decisions into Flutter or duplicate the OCaml graph engine.

This is not a file-for-file port. Logseq Chat is a Skip application whose platform
shell, app metadata store, and OCaml graph runtime were designed together around
sync. Logseq Journal is a Bonsai Flutter application whose OCaml worker opens a
fully resolved graph target during runtime startup, owns that SQLite graph
exclusively, and exposes a typed worker protocol to the journal UI. The port must
preserve the latter architecture while introducing an authentication and sync
lifecycle before and alongside the Bonsai runtime.

## Research scope

The source implementation was inspected at Logseq Chat commit
`37c034e4b80c1a0a8e554e02188177ffc42ffaa2` (2026-08-17), Logseq Journal commit
`44f798328ae6463a1b35edf1bfecb780e2e11000` (2026-08-21), and upstream Logseq
commit `fab27740975dcda1e93dbca718d1f620eda543c7` as the initial E2EE and db-sync
compatibility reference.

Repository instructions in `../chat/AGENTS.md` were treated only as operational
guidance for inspecting that repository. They are not product requirements for this
decision. The implementation evidence comes from source, tests, scripts, and
`../chat/docs/adr/001-real-time-graph-sync.md`. Where that ADR and current source
disagree, this document records the disagreement instead of silently treating the
ADR as current behavior.

The external feasibility check used AWS-maintained documentation and primary source
from `logseq/logseq`. Amplify Flutter provides Cognito Auth and the Authenticator
component on both iOS and macOS, and Amplify owns secure session persistence and
token refresh. The exact package versions must be selected and locked during
implementation rather than copied from the Swift dependencies in Logseq Chat.

## Findings: Logseq Chat

### Authentication and graph selection

The production login screen is the native Amplify `Authenticator`, configured with
`AWSCognitoAuthPlugin` and a public Cognito User Pool client. The custom
`LogseqAuthenticationStore` does not render the production challenge flow; it
restores the session, obtains a fresh User Pool access token, reports signed-in
state, and signs out. Amplify persists and refreshes the session. The app does not
persist the access token itself.

Relevant sources:

- `../chat/Sources/LogseqChat/LogseqChatApp.swift` configures Amplify, wraps the app
  in `Authenticator`, and constructs the runtime.
- `../chat/Sources/LogseqChat/CognitoAuthProvider.swift` extracts the Cognito access
  token from the current Amplify session.
- `../chat/Sources/LogseqChatModel/Authentication.swift` owns the application-level
  authentication state machine.
- `../chat/Sources/LogseqChat/Resources/logseq-auth.json` contains the region, User
  Pool ID, and public app-client ID.
- `../chat/core/logseq_chat_api.ml` defines authenticated `GET /graphs` discovery.
- `../chat/core/logseq_chat_rpc.ml` persists/restores the complete graph catalog and
  validates graph readiness when selecting a graph.

The selected graph ID and base URL are stored independently of the Cognito session.
On cold start, the app first tries to open the last selected local graph without a
token, then restores authentication, refreshes the catalog, and reconnects. This is
what allows offline launch to remain useful.

### Snapshot bootstrap and local layout

Each selected graph has a dedicated directory containing `graph.sqlite` and
`sync.checkpoint`. If both exist, the graph is opened locally. Otherwise the app:

1. calls `GET /sync/:graph-id/snapshot/download` with a Cognito access token;
2. downloads the returned artifact to a temporary file;
3. accepts identity or gzip content encoding;
4. feeds the decompressed, length-framed Transit stream into OCaml;
5. validates row ordering, advertised row count, root row, tail row, graph ID,
   schema version, and baseline server `t`;
6. stages a new Logseq-layout `kvs` SQLite database and atomically activates it;
7. persists the graph ID, schema version, and applied server `t` in a versioned
   Transit checkpoint.

Relevant sources are `GraphSyncHTTP.swift`, `GraphLocalStorage.swift`,
`logseq_chat_snapshot.ml`, `logseq_chat_graph_store.ml`,
`logseq_chat_sync_checkpoint.ml`, and `logseq_chat_sync_session.ml`.

### Incremental receive path

Foreground sync opens
`GET /sync/:graph-id/events?since=<applied-server-t>` as an authenticated SSE stream.
Platform code owns the network task, cancellation, byte buffering, and reconnect
loop. OCaml owns SSE decoding, Transit decoding, graph/schema/cursor validation,
complete-entity upsert or deletion, and checkpoint advancement.

The event payload is latest entity state, not raw DataScript transaction data. An
upsert replaces all known attributes of an entity, so an omitted attribute is a
retraction. Events are accepted only when `t-before` exactly matches the committed
cursor. A `reset` event or schema mismatch requires a new snapshot. HTTP submission
acknowledgement never advances the receive cursor.

The platform stream is deliberately divided into short calls into OCaml. A live
network stream never holds the OCaml runtime lock. The main implementation is in
`GraphSyncHTTP.swift`, `ViewModel.swift`, `logseq_chat_sse.ml`,
`logseq_chat_sync_protocol.ml`, `logseq_chat_sync_state.ml`,
`logseq_chat_entity_sync.ml`, and `logseq_chat_sync_session.ml`.

This receive protocol is research evidence, not the selected Journal protocol. The
product decision is to interoperate with upstream Logseq's transaction replay:
WebSocket `hello`, `pull`, `changed`, and `tx/batch` messages, with HTTP `pull` as a
bounded alternative. Chat's SSE latest-entity events, complete-entity replacement,
and SSE cursor rules must therefore not be ported into production Journal sync.

### Local-first writes

The current source has two generations of write support. The older path sends
captures and property edits through semantic REST endpoints. The newer outliner path
persists versioned pending intents, builds an optimistic projected graph, compiles an
intent against the latest authoritative graph, encodes a typed DataScript
transaction, and submits it to `POST /sync/:graph-id/tx/batch` with `t-before`, a
stable transaction ID, and an `outliner-op` label. Accepted operations remain pending
until the authoritative SSE echo reaches the accepted server `t`.

The newer path includes save, insert, split, merge, move, status, and delete
operations. It is implemented by `logseq_chat_pending_ops.ml`,
`logseq_chat_pending_projection.ml`, `logseq_chat_graph_runtime.ml`,
`logseq_chat_sync_tx.ml`, `logseq_chat_api.ml`, and the pending pump in
`logseq_chat_rpc.ml`/`ViewModel.swift`.

This current behavior conflicts with section 7 of
`../chat/docs/adr/001-real-time-graph-sync.md`, which still says the client must not
call `tx/batch` and may only create blocks or modify block properties. Server
authorization for the reused Chat app client and the selected Journal mutation set
was therefore a research question. The deployed service has since confirmed the
required permissions. The product protocol choice is `tx/batch`; a future
authorization regression requires a server contract fix rather than a client-side
semantic REST fallback.

### Encryption and background execution

Logseq Chat contains E2EE key-package decoding, graph-key unlock, platform crypto,
secure key caching, protected-value encryption/decryption, encrypted snapshot import,
and encrypted outgoing writes. The current importer materializes and persists a
plaintext local DataScript graph for an encrypted remote graph. That is verified by
`logseq_chat_sync_session_test.ml` and conflicts with the ADR text describing a
ciphertext mirror plus an in-memory plaintext projection.

Upstream Logseq at the inspected revision confirms the interoperable building
blocks: `src/main/frontend/common/crypt.cljs` implements RSA-OAEP key wrapping,
AES-GCM graph-value encryption, and PBKDF2 password-derived private-key protection;
`src/main/frontend/worker/sync/crypt.cljs` applies crypto only to the protected
attribute set in transactions and snapshot rows; the inspected
`src/main/frontend/worker/sync/const.cljs` protected set is `:block/title` and
`:block/name`; and
`docs/agent-guide/db-sync/protocol.md` documents user-key and per-graph AES-key
endpoints together with `POST /sync/:graph-id/tx/batch`. These files are the primary
compatibility reference; the Chat implementation remains the closer porting source.

iOS foreground and bounded background sync are mutually exclusive through
`GraphSyncCoordinator`. Background execution opens the cached graph, refreshes the
access token, submits pending operations, consumes one replay frame, and exits. The
current macOS application does foreground sync but does not have an equivalent iOS
background scheduler.

### Verification already present in Chat

The behavioral evidence includes unit tests for authentication state, snapshot
framing/import, checkpoint encoding, SSE framing, protocol decoding, cursor gaps,
idempotent entity application, pending-operation persistence and rebase, encrypted
values, and foreground/background exclusion. iOS simulator scripts exercise online
bootstrap, server-to-client SSE, self-echo, restart, offline pending writes,
reconnect, cursor advancement, and encrypted graphs.

Authentication, snapshot, pending-operation, E2EE, and lifecycle tests are porting
references. SSE and complete-entity tests document the Chat-only dialect and should
instead become contrast tests proving that Journal accepts upstream transaction
messages and rejects Chat event payloads. Swift/Skip tests and Chat UI/model fixtures
cannot be copied as Logseq Journal tests.

## Findings: Upstream Logseq db-sync

### Snapshot and incremental transaction replay

The pinned upstream protocol uses the same authenticated graph catalog and framed
Transit KVS snapshot bootstrap, then switches to transaction replay. Foreground
clients connect WebSocket `ws(s)://<base>/sync/:graph-id`, send `hello`, and pull
from a durable server `t`. A successful `pull/ok` contains ordered Transit-encoded
transactions plus the resulting server `t` and entity checksum. `changed` is a hint
to pull; it is not graph data and does not advance local state.

The deployed db-sync worker authenticates these endpoints with the Cognito User
Pool ID token. The access token does not carry the identity claims consumed by the
worker. Journal therefore obtains a fresh ID token from each restored Amplify
session instead of substituting the OAuth access token.

`GET /sync/:graph-id/pull?since=<t>` exposes the same pull result over HTTP. This is
useful for bounded catch-up and later iOS background replay, but it must feed the same
OCaml decoder, transaction applier, `t`, and checksum state machine as WebSocket
pull. Journal must not combine these semantics with Chat's SSE latest-entity events.

### Transaction submission and rejection

Upstream `tx/batch` carries `t-before` and ordered entries containing Transit `tx`,
an optional but recommended stable `tx-id`, and an optional `outliner-op`. Foreground
submission can use the WebSocket message; the equivalent HTTP endpoint is
`POST /sync/:graph-id/tx/batch`. A successful response returns the resulting `t` and
checksum. Rejections distinguish stale state, invalid input, snapshot upload, and
transaction failure. Transaction failure may report `success-tx-ids` plus one
`failed-tx-id`, so retry and pending-state recovery must support partial success.

### Encryption and assets

The upstream E2EE endpoints store the user RSA key package and each member's wrapped
per-graph AES key. The pinned client encrypts exactly `:block/title` and
`:block/name` in snapshot and transaction data. Other structural or property values
remain visible according to the upstream interoperability contract.

The upstream protocol also exposes asset upload, download, and deletion. Those
endpoints are independent protocol capabilities and are explicitly outside the
first Logseq Journal release.

## Findings: Logseq Journal

### Startup and host boundary

`flutter/lib/main.dart` asks `ApplicationHostAdapter` for one startup payload before
constructing `BonsaiFlutterRoot`. The adapter obtains a native environment over the
`logseq_journal/platform` method channel and encodes one `LDB1` worker configuration.
The iOS and macOS native hosts currently default the graph name to
`logseq_journal`.

`Logseq_db_worker.Config.t` requires one of three already-resolved targets:
`Snapshot`, `Import_snapshot`, or `Native_local_graph`. The Bonsai runtime therefore
cannot currently show login or graph selection and then select a graph inside the
same worker session. Changing the selected graph naturally maps to replacing the
runtime with a new startup payload.

The application platform bridge currently carries only calendar request/response
messages and calendar lifecycle events. It is suitable for bounded asynchronous
transport messages, but its application payload limit means snapshot bodies must
remain file-backed and WebSocket or HTTP pull responses must be delivered as bounded
messages.

### Graph worker and persistence

`logseq_db_worker` already has the stronger local storage implementation and should
remain the graph owner:

- exact Logseq KVS Transit decoding and schema restoration;
- exclusive ownership and identity revalidation;
- staged DataScript transactions and SQLite commit;
- recovery backup and sidecar invalidation;
- typed reads and mutations;
- mutation IDs, expected-basis conflict checks, and worker invalidation pushes.

The worker intentionally rejects `graph-remote? = true`, RTC graph identity, and
non-empty client-operation history. Its `basis` is a local application basis, not the
db-sync server `t`. Its 256-entry mutation cache is in memory and is not a durable
outgoing queue. A synced graph therefore needs an explicit target/admission mode and
must not be disguised as a native local graph.

The application already reacts to `Graph_invalidated` pushes by re-querying the
bounded journal projection. The same invalidation path can be reused after a pulled
remote transaction batch; remote sync must not bypass the worker and mutate the
SQLite file from Dart while the worker owns it.

### Important integration constraints

- A full snapshot replacement cannot occur underneath an open worker-owned SQLite
  connection. It requires a coordinated worker shutdown/runtime replacement or an
  engine-level close/import/reopen transition.
- Pulled transaction batches must be applied through `Storage_session` so graph
  persistence, the in-memory DataScript value, worker basis, checksum, server `t`,
  and UI invalidation remain coherent.
- The server cursor and local worker basis are different counters and must remain
  separate.
- The current mutation path commits directly into the worker's authoritative KVS
  graph. A local-first synced graph instead needs authoritative remote state plus a
  durable pending overlay, or a formally specified equivalent reconciliation model.
- The current source tree has no `spec/` directory. Future work must still honor the
  repository restriction if one is introduced. The product decision explicitly
  authorizes the Dune edits required for new OCaml modules and dependencies.

## Portability assessment

| Chat area | Treatment in Logseq Journal | Reason |
| --- | --- | --- |
| Cognito pool configuration and Authenticator behavior | Reimplement with Amplify Flutter | The host is Flutter, not Swift/Skip; Amplify still owns challenges, secure session persistence, and refresh. |
| Authentication state machine | Adapt | Preserve restore/token/sign-out semantics, but make it a host bootstrap concern rather than a Bonsai graph concern. |
| Graph catalog and last selection | Adapt | They must exist before the worker startup payload can be built. |
| Snapshot metadata, framing, and validation | Port OCaml logic and fixtures | The wire contract and Transit types are reusable. |
| Chat graph-store SQLite stubs | Do not port | `logseq_db_worker` already has safer ownership, staging, backup, and Logseq KVS storage. |
| Chat SSE parser, latest-entity protocol, and entity replacement | Do not port | Journal must interoperate with upstream Logseq transaction replay rather than Chat's SSE dialect. |
| Upstream WebSocket/HTTP pull protocol, tx replay, checksum, and server cursor | Implement in OCaml from pinned upstream protocol and fixtures | These rules define cross-client interoperability and must remain outside Flutter. |
| Chat transport adapters | Reimplement as Dart HTTP and WebSocket capabilities | Flutter owns network lifecycle, authentication, cancellation, and platform lifecycle on iOS and macOS. |
| Pulled transaction application | Adapt to `Storage_session` | Remote transactions must update worker state, durable server metadata, and UI invalidations atomically. |
| Pending intents and optimistic projection | Port concepts; remap to `Protocol.mutation` and `Mutation_plan` | Journal already has a richer typed mutation surface and conflict model. |
| Chat app cache, reduced models, RPC envelope, and semantic polling | Do not port | Journal reads the full local graph through its typed worker protocol. |
| E2EE modules | Port in the first foreground release and validate against upstream Logseq | The server must not receive protected values in plaintext; the initial local mirror deliberately stores decrypted graph data. |
| Asset sync and asset E2EE | Do not port in the first release | The initial release syncs graph data only and must not advertise asset convergence. |
| iOS background coordinator | Port after foreground correctness | It depends on durable selection, token restore, pending writes, and bounded replay. |

## Decision

Adopt the following product and protocol decisions:

- Reuse Logseq Chat's Cognito User Pool public app client and its Amplify
  configuration. Logseq Journal does not receive a distinct Cognito client.
- Authenticate db-sync catalog, snapshot, E2EE, HTTP, and WebSocket requests with a
  fresh Cognito User Pool ID token from Amplify.
- The deployed db-sync environment has confirmed that the reused Chat client may
  access WebSocket sync, HTTP pull, snapshot download, E2EE key endpoints, and
  `tx/batch` for the first-release mutation allowlist.
- Match upstream Logseq's db-sync protocol rather than Chat's SSE receive dialect.
  Foreground sync uses WebSocket `/sync/:graph-id` with `hello`, `pull`, `changed`,
  and `tx/batch`; bounded catch-up may use `GET /sync/:graph-id/pull?since=<t>`.
  Snapshot bootstrap continues through
  `GET /sync/:graph-id/snapshot/download`.
- Submit outgoing writes as upstream `tx/batch`: over the foreground WebSocket in the
  first release, with the equivalent HTTP endpoint reserved for bounded transport
  contexts. The first enabled mutation set is exactly capture/insert, title or status
  save, child creation, and subtree delete. Every enabled operation still needs an
  explicit typed-transaction mapping and convergence test; other mutations remain
  unavailable in synced mode.
- Ship E2EE in the first foreground-sync release. Follow the wire formats and crypto
  semantics in the pinned upstream Logseq sources, using Chat as the porting
  reference.
- E2EE protects data from the service: protected values are encrypted before upload
  and decrypted after download. The protected attribute set is exactly
  `:block/title` and `:block/name`, matching pinned upstream Logseq. The initial local
  graph mirror stores plaintext, matching the local block-data model and the current
  Chat importer.
- Journal only unlocks existing E2EE keys. The user enters the E2EE password, Journal
  decrypts the existing user private key, and stores that private key in app-local
  platform secure storage scoped to the authenticated user. The password is not
  persisted. Missing-key initialization, password change/reset, and access grants
  remain the responsibility of another Logseq client.
- Debug integration tests may explicitly replace platform secure storage with a
  user-scoped, process-memory private-key store. This mode exists only to prevent an
  unattended macOS test from blocking on the Keychain UI, is rejected by Release
  builds, and loses every stored private key when the test host exits. It does not
  change the production Keychain contract or permit password persistence.
- Explicit sign-out retains cached graph mirrors, graph metadata, and the last graph
  selection, but the retained plaintext data is not readable in Journal until the
  next successful sign-in. Sign-out cancels transport, clears in-memory keys, and
  returns to authentication without deleting the mirror or securely stored private
  key.
- Production startup is login followed by synced-graph selection. The hard-coded
  native graph path is removed from production; native and snapshot targets remain
  only for tests, fixtures, and explicit developer entry points.
- When the authorized catalog contains no synced graph, show an empty state that
  directs the user to create one in another Logseq client. Logseq Journal does not
  create, delete, or rename synced graphs in the first release.
- Asset upload, download, deletion, encryption, and background reconciliation are
  outside the first release. Graph sync must not claim that referenced assets have
  converged.
- A stale `tx/reject` automatically pulls, rebases, and retries with the stable
  transaction ID. Partial success displays the accepted and failed transaction
  details; permanent failure displays the server error. Both non-stale failure paths
  stop automatic recovery and offer an explicit action to delete the local graph
  mirror and download it again. This action never deletes the remote synced graph.
- An incompatible graph schema blocks opening and prompts for an app upgrade. A
  checksum mismatch displays a sync error but leaves the current local graph usable;
  it does not automatically replace the mirror. The first release never evicts graph
  caches automatically and provides a per-graph local-cache deletion action.
- The first release requires iOS and macOS foreground parity. iOS bounded background
  replay is later work and may only catch up the cursor when the operating system
  grants execution time; it has no real-time guarantee.
- Required Dune file changes are authorized for the implementation.

## Architecture

The following architecture minimizes duplicated graph logic and gives each runtime
one clear owner.

### 1. Make Flutter the account and runtime bootstrap shell

Replace the current always-running `BonsaiFlutterRoot` shell with a host state machine
that configures Amplify once with the same public Cognito User Pool client used by
Logseq Chat, renders the Amplify Authenticator, restores the last selected graph,
fetches the authorized graph catalog, and chooses whether to open a cached mirror or
bootstrap a new one. The Bonsai runtime is constructed only after a specific graph
directory is ready.

If the authorized catalog is empty, render a non-runtime empty state that explains
that a synced graph must be created in another Logseq client. Do not expose graph
creation, deletion, or rename controls in the first Journal release.

The ID token remains ephemeral. Every HTTP request and WebSocket connection asks
Amplify for the current Cognito session and attaches a fresh ID token in Dart.
Tokens are never written to the startup payload, graph SQLite, checkpoint, pending
store, logs, or Bonsai model.

Persist a versioned, non-secret app metadata record containing the base URL, graph
catalog, selected graph ID, schema/encryption metadata, and local mirror status. A
cached selected graph may open without network access after Amplify confirms a
locally restorable signed-in session. Sign-out stops transport and returns to
authentication; the cached mirror, graph metadata, and last selection remain on the
device but are not opened again until a later successful sign-in.

Selecting a different graph produces a new synced-graph startup target and replaces
the Bonsai runtime. Remove the hard-coded native graph path from production startup
instead of retaining a compatibility fallback. Snapshot and native targets remain
reachable only from tests, fixtures, and explicit developer entry points.

### 2. Introduce one versioned application-platform transport contract

Replace the calendar-only application-platform wire contract with one tagged,
bounded envelope covering calendar operations and sync transport operations. Do not
add a compatibility decoder for the old envelope. Sync operations include graph
catalog fetch, snapshot metadata/download-to-file, authenticated HTTP pull and
`tx/batch`, WebSocket open/send/close, and bounded WebSocket message events. Asset
transport operations are deliberately absent from the first contract.

Dart owns URLs, HTTP and WebSocket status, redirects, timeouts, gzip file decoding,
ID-token attachment, connection cancellation, app lifecycle, and retry timing.
OCaml owns Transit, snapshot row framing, upstream message encoding/decoding,
transaction validation/application, checksum rules, server-`t` continuity, and
pending-operation state.

Transport messages carry a runtime/graph generation so late messages from a
cancelled connection cannot reach a replacement runtime. Only one foreground
connection may own the selected graph. Later iOS background replay uses HTTP pull
and the same exclusion coordinator, never a concurrent second sync owner.

### 3. Add an explicit synced graph mode to `logseq_db_worker`

Add a `Synced_graph` target whose identity is the server graph ID and whose directory
is an application-owned mirror. This mode expects sync metadata and admits the
server snapshot's remote identity. It must remain distinct from native graph
ownership and from imported developer snapshots.

Port the compatible Chat snapshot parser, but implement the incremental protocol
from the pinned upstream Logseq contract behind narrow `.mli` files in
`logseq_db_worker`. The OCaml state machine sends `hello` and `pull`, decodes
`hello`, `pull/ok`, `changed`, `tx/batch/ok`, `tx/reject`, and error messages, and
applies the Transit transactions contained in `pull/ok`. Do not port Chat's SSE
parser or latest-entity replacement logic. Adapt transaction application to
`Storage_session`; do not copy `logseq_chat_graph_store_stubs.c` or open a second
SQLite connection from Flutter.

Store the graph ID, schema version, applied server `t`, and entity checksum in a
versioned `sync_meta` table. A `pull/ok` batch, resulting KVS writes, server metadata,
and local basis advancement commit in one SQLite transaction. Reject gaps, invalid
Transit, or failed transaction application without advancing server `t`. A checksum
mismatch rolls back the pulled batch, preserves the last valid local graph and
server `t`, records a visible sync error, and pauses further remote apply and
submission. The local graph and optimistic pending layer remain usable, so new local
operations may queue durably until recovery. A successful pulled batch emits the
existing `Graph_invalidated` push. `changed` is only a signal to pull from the
durable local `t`; it does not itself advance state.

Check schema compatibility before opening a mirror or activating a snapshot. An
unsupported schema blocks the graph and displays an app-upgrade requirement; neither
rebootstrap nor a compatibility decoder is attempted.

Full snapshot bootstrap stages a new mirror outside the active directory, validates
it through the same Logseq codec and worker admission path, writes its initial
`sync_meta`, and atomically activates it before runtime launch. A protocol or
checksum error does not automatically replace a usable mirror. Recovery occurs only
after the user chooses the local-cache deletion action, which closes the connection
and runtime, deletes the local mirror and its pending intents, downloads and stages a
fresh snapshot, and launches a new runtime. Partial snapshots are never visible, and
the remote synced graph is never deleted.

### 4. Preserve Journal's typed mutation surface with a durable pending layer

Do not send a local Journal mutation directly to both the local KVS store and the
server. For a synced target, persist a versioned intent before publishing optimistic
success, build a projected read database from the authoritative mirror plus ordered
pending intents, and compile the intent against the latest authoritative state when
the transport pump runs.

Reuse `Protocol.mutation`, `Mutation_plan`, and stable mutation IDs as the source
intent model where possible. Add an explicit mapping from every supported Journal
mutation to a typed Transit transaction submitted as a foreground WebSocket
`tx/batch`. Server acceptance changes pending state but does not directly mutate the
authoritative mirror. Record the accepted `t` and checksum, pull from the durable
local `t`, and remove or rebase the pending intent only after transaction replay
reaches the accepted server state. Handle stale rejection and partial batch success
through `success-tx-ids` and `failed-tx-id`; never retry an already accepted
transaction ID as a new operation.

On stale rejection, automatically pull from the durable `t`, rebase pending intents,
and retry the same stable transaction ID. On partial success, stop the graph's
submission pump and show the successful IDs, failed ID, and server reason. On a
permanent rejection, stop the pump and show the server error. Partial and permanent
failures both offer `Delete local copy and download again`; after explicit
confirmation it performs the local-only recovery described above and warns that
unconfirmed pending operations will be lost.

This is the largest adaptation. Chat's `Pending_ops` and `Pending_projection` cannot
replace Journal's engine wholesale because Journal supports pages, properties,
structural validation, expected local basis, recovery backups, and bounded worker
responses. The first write milestone covers exactly capture/insert, title or status
save, child creation, and subtree delete. Other worker mutations remain unavailable
in synced mode until a later product decision gives them an explicit server mapping
and convergence tests.

Because Logseq Journal reuses the Chat Cognito client and `tx/batch`, implementation
must test the already-confirmed deployed permissions against every enabled mutation
before the write UI is released. An unexpected authorization regression is a server
contract failure, not a reason to introduce a semantic REST fallback.

### 5. Include E2EE in the foreground release and defer background replay

Support both encrypted and unencrypted graphs in the first foreground release. For
an encrypted graph, fetch the existing user RSA key package, ask the user for the
E2EE password when no usable local private key exists, decrypt the private key, and
persist the decrypted private key in platform secure storage scoped to the Cognito
user. Do not persist the password. Use the private key to unlock the existing
per-graph AES key, encrypt protected transaction attributes before `tx/batch`, and
decrypt protected snapshot and pulled-transaction values before applying them to the
worker. The encrypted attribute set is exactly `:block/title` and `:block/name`;
structural attributes and other values follow the pinned upstream behavior. Validate
packages and fixtures against the pinned upstream Logseq `common/crypt.cljs`, worker
sync crypto, protected attribute set, and protocol.

The server-facing snapshot and transactions must not expose protected plaintext.
After decryption, the worker persists the ordinary plaintext graph in its local
SQLite mirror. The decrypted user private key is the only unwrapped long-lived key
persisted by Journal and belongs only in platform secure storage; graph AES keys stay
in memory. Passwords, private keys, and graph AES keys must not appear in app
metadata, sync metadata, pending-intent records, startup payloads, diagnostics, or
logs. Sign-out clears in-memory graph keys but retains the securely stored private
key for the next successful sign-in. If required existing keys are missing or cannot
be unlocked, Journal displays an error and directs the user to another Logseq client;
it does not initialize, reset, rotate, or grant keys.

After foreground restore, snapshot, WebSocket pull, pending writes, reconnect, and
rebootstrap are stable, add iOS bounded background replay using the same selected
graph metadata and transport coordinator. macOS continues foreground reconnect.
Background execution does not refresh the graph catalog or download a missing
snapshot. It performs bounded HTTP pull catch-up only when iOS grants execution time
and must not be described as real-time sync.

### 6. Keep initial graph management and asset scope narrow

The first release lists and selects ready graphs but does not create, rename, or
delete them. An empty catalog renders guidance to create a synced graph in another
Logseq client and then refresh or sign in again.

Do not add asset API calls, an asset queue, asset encryption, or asset background
work. Synced block data may retain asset references, but Journal must not report the
referenced binary as available or synchronized unless it already exists through an
unrelated local developer or fixture path. Asset sync requires a later exploring
decision.

Retain every downloaded graph cache until the user explicitly clears it. Do not add
automatic size limits, age-based eviction, or least-recently-used removal in the
first release. The per-graph clear action is local-only, requires confirmation,
states whether pending operations will be lost, stops the graph runtime, removes its
mirror and pending state, and leaves the remote graph and user private key intact.

## Suggested implementation sequence

1. Freeze representative Chat snapshot fixtures and pinned upstream Logseq protocol
   fixtures. Write failing Journal tests for framed snapshot rows, WebSocket `hello`,
   `pull/ok`, `changed`, `tx/batch/ok`, every `tx/reject` form, HTTP pull parity,
   server-`t` gaps, checksum mismatch, E2EE key packages, and encrypted
   `:block/title`/`:block/name` values.
2. Add the synced target, sync metadata schema, staged snapshot importer, and
   read-only worker open path. Verify byte-for-byte graph/schema parity and atomic
   rejection of corrupt or incomplete snapshots.
3. Add pulled transaction replay through `Storage_session`, atomic server `t` and
   checksum commits, local basis advancement, worker invalidation pushes, and the
   non-blocking local-use state for checksum errors.
4. Add the Flutter Amplify shell, app metadata store, graph catalog/picker, offline
   cached open, empty-catalog guidance, file-backed snapshot transport, WebSocket and
   HTTP pull transport, runtime generation fencing, reconnect, schema-upgrade block,
   retained-but-locked sign-out state, and confirmed per-graph local-cache deletion
   and redownload.
5. Add the unlock-only E2EE lifecycle and platform crypto boundary: password prompt,
   existing private-key decryption, user-scoped secure private-key persistence,
   in-memory graph-key handling, missing-key guidance, protected-value crypto, and
   plaintext graph persistence. Verify that secrets never cross non-secret
   persistence or diagnostic boundaries.
6. Add durable pending intents and optimistic projection for the Journal UI mutation
   allowlist, compile encrypted or plaintext Transit transactions according to graph
   mode, submit them through `tx/batch`, and confirm them through authoritative pull
   replay. Cover automatic stale pull/rebase/retry, detailed partial/permanent error
   states, pump suspension, and confirmed local-copy deletion with pending-loss
   disclosure.
7. Add foreground end-to-end tests against db-sync for encrypted and unencrypted
   bootstrap, remote transaction replay, each enabled mutation, offline restart,
   reconnect, token refresh, authorization regression, non-blocking checksum errors,
   graph switching, incompatible schema, sign-out cache locking, manual cache clear,
   empty catalogs, and the absence of asset network calls on iOS and macOS.
8. After foreground parity ships, add iOS bounded background replay and lifecycle
   tests without a real-time delivery guarantee.

Each implementation step must follow test-first development and keep the runtime
usable at the end of the step. The necessary Dune changes for new OCaml modules and
libraries are explicitly authorized.

## Alternatives considered

### Run all sync logic in Dart

Rejected because it would duplicate schema-sensitive Transit decoding, transaction
application, server-`t` and checksum rules, pending rebase, and E2EE orchestration
outside the OCaml graph engine. Dart should provide transport capabilities, not a
second graph client.

### Copy the Chat OCaml runtime and SQLite stubs wholesale

Rejected because it would create two graph owners and discard Journal's stronger
storage session, backup, admission, typed mutation, and invalidation design. Only
protocol/state logic and behavioral fixtures are portable without adaptation.

### Mutate the authoritative mirror directly and enqueue the same local transaction

Not recommended. It conflates local basis with server `t`, makes restart and conflict
rebase ambiguous, and allows an optimistic change to masquerade as authoritative
state before pull replay confirms the accepted server state. A durable pending
overlay gives local-first behavior without corrupting the receive cursor's source of
truth.

### Keep the worker fixed and periodically replace its SQLite file from Flutter

Rejected because the worker owns an exclusive open connection and an in-memory
DataScript value. External file replacement would bypass ownership, transaction,
basis, and invalidation guarantees.

### Launch the existing hard-coded local graph and add login inside the Bonsai UI

Rejected because graph discovery and snapshot bootstrap must occur before the worker
can resolve its startup target. It would also make graph switching and offline cached
selection unnecessarily stateful inside a graph-specific runtime.

### Keep a ciphertext mirror on the device

Rejected for the initial port. The E2EE requirement is that the service cannot read
protected content; local block data is already an ordinary plaintext graph, and the
current Chat importer follows that model. A ciphertext mirror plus a separate
plaintext query projection would add another authoritative representation and more
recovery states without satisfying a current product requirement.

### Ship iOS background replay with the first foreground release

Deferred because iOS scheduling is opportunistic and the foreground storage,
cursor, key, and pending-write lifecycle must be stable first. This is a rollout
order, not a production compatibility path.

## Acceptance criteria

- A signed-in user can restore an Amplify Cognito session, list only authorized
  graphs, select a ready graph, sign out, and recover from an expired ID token
  without the application persisting tokens. Authentication uses the same public
  Cognito User Pool app client as Logseq Chat, and integration tests exercise the
  confirmed deployed permissions for every required endpoint and mutation.
- An authorized user with no graph sees an empty state directing them to another
  Logseq client for graph creation. Journal exposes no create, rename, or delete
  graph action in the first release.
- A previously selected valid mirror opens offline once Amplify restores a signed-in
  session, without waiting for network recovery. Explicit sign-out retains the
  mirror, catalog metadata, and last graph selection while cancelling authenticated
  transport and clearing in-memory graph keys, but the retained graph is unreadable
  in Journal until the next successful sign-in.
- First open downloads and atomically validates the existing db-sync snapshot format;
  no partial graph is observable.
- A graph with an unsupported schema never opens and presents an app-upgrade message.
- The local mirror preserves the server schema and every supported Transit value
  without coercion.
- Foreground sync connects to upstream Logseq's WebSocket endpoint, completes
  `hello`, pulls from the durable server `t`, applies ordered Transit transactions
  through the worker, and commits graph state, `t`, checksum, and local basis
  atomically. `changed` only triggers another pull.
- Duplicate transaction replay is idempotent; graph, server-`t`, and transaction
  mismatch is rejected. A checksum mismatch rolls back the batch, shows a persistent
  sync error, and pauses remote synchronization without blocking reads, local edits,
  or durable pending capture. HTTP pull has the same apply semantics.
- Capture/insert, title/status save, child creation, and subtree delete are durable
  before optimistic presentation, survive process and network failure, retry with
  stable transaction IDs, and clear only after authoritative pull replay. Stale
  rejection automatically pulls, rebases, and retries. Partial success displays
  successful and failed IDs; permanent rejection displays the server error. Both
  stop automatic submission and offer confirmed local-copy deletion and redownload.
  No other synced mutation is enabled.
- Switching graphs cancels the old connection, rejects late messages by generation,
  and replaces the Bonsai runtime without cross-graph state leakage.
- Encrypted graphs interoperate with the pinned upstream Logseq key packages and
  protected-value format. Exactly `:block/title` and `:block/name` are ciphertext at
  the server boundary and plaintext in the local worker-owned mirror; encrypted and
  unencrypted snapshot, pull, and write paths all pass end-to-end tests.
- E2EE unlock accepts a user password for an existing key package, persists only the
  decrypted user private key in user-scoped platform secure storage, keeps decrypted
  graph AES keys in memory, and never persists the password. Missing keys and
  reset/change/grant requests direct the user to another Logseq client.
- Debug integration tests can opt into user-scoped process-memory private-key storage
  without opening Keychain UI. The option is unavailable in Release builds, is empty
  on each process start, and does not weaken the production secure-storage behavior.
- The first release makes no asset upload, download, delete, encryption, or
  background reconciliation request and never reports remote assets as synchronized.
- iOS and macOS pass equivalent unit, integration, Flutter host, compiled runtime,
  and real db-sync foreground tests in the first release.
- Production cannot start the hard-coded native graph. Native and snapshot targets
  remain available only in tests, fixtures, and explicit developer entry points.
- Graph caches are never evicted automatically. A per-graph local-cache action
  requires confirmation, discloses pending-operation loss, removes only local mirror
  and pending data, and then permits a fresh snapshot download; it never deletes the
  remote graph or user private key.
- No ID token, access token, refresh token, graph password, or plaintext
  cryptographic key is written to logs, startup payloads, graph metadata, or
  pending-operation records.

## Consequences

- The deployed db-sync permissions are confirmed, but an environment/configuration
  regression could still break an endpoint or mutation and must fail visibly without
  enabling a fallback protocol.
- Snapshot activation and runtime replacement cross Dart, Bonsai runtime, worker,
  filesystem, and SQLite ownership boundaries; incomplete cancellation could deliver
  a late WebSocket message to the wrong graph.
- A durable optimistic projection is a substantial change to the worker's current
  direct-commit model and needs exhaustive crash/rebase tests.
- Chat and Journal currently pin different revisions of DataScript and related codec
  dependencies. Fixtures may expose wire or storage incompatibilities that must be
  resolved before copying algorithms.
- Large snapshots and pull batches can exceed memory or platform payload limits
  unless downloads remain file-backed and pull responses remain bounded.
- Cached mirrors intentionally remain after sign-out, so device storage and OS-level
  data protection are part of the accepted local threat model. This application
  decision must be stated clearly in privacy and sign-out UX.
- The decrypted user private key intentionally survives sign-out in platform secure
  storage. Incorrect user scoping, access-control attributes, backup behavior, or
  diagnostics could expose every graph key wrapped for that user.
- Persisting plaintext for encrypted graphs protects against a service-side reader,
  not a reader who can access the unlocked local database. Moving to ciphertext at
  rest would require a separate product decision and query/storage architecture.
- Matching upstream encryption means structural attributes and all attributes other
  than `:block/title` and `:block/name` remain visible to the service. This is an
  explicit interoperability tradeoff rather than full-record encryption.
- Continuing local use after a checksum mismatch can accumulate pending operations
  while sync is paused. The error state and eventual local-copy reset must make the
  potential loss of unconfirmed work explicit.
- Local-cache deletion is destructive to pending operations. The action must never be
  confused with remote graph deletion and must require informed confirmation.
- iOS background scheduling is opportunistic and cannot promise continuous real-time
  delivery.

## References

- `../chat/docs/adr/001-real-time-graph-sync.md`
- `../chat/Sources/LogseqChatModel/Authentication.swift`
- `../chat/Sources/LogseqChat/LogseqChatApp.swift`
- `../chat/Sources/LogseqChatModel/GraphSyncHTTP.swift`
- `../chat/Sources/LogseqChatModel/ViewModel.swift`
- `../chat/core/logseq_chat_snapshot.ml`
- `../chat/core/logseq_chat_sync_protocol.ml`
- `../chat/core/logseq_chat_sync_session.ml`
- `../chat/core/logseq_chat_pending_ops.ml`
- `../chat/core/logseq_chat_pending_projection.ml`
- `../chat/core/logseq_chat_sync_tx.ml`
- `flutter/lib/application_host_adapter.dart`
- `app/application.ml`
- `logseq_db_worker/lib/engine.ml`
- `logseq_db_worker/lib/storage_session.ml`
- [AWS Amplify Flutter Auth setup](https://docs.amplify.aws/flutter/build-a-backend/auth/set-up-auth/)
- [AWS Amplify Flutter session management](https://docs.amplify.aws/flutter/frontend/auth/manage-user-sessions/)
- [Amplify Auth token and credential behavior](https://docs.amplify.aws/flutter/build-a-backend/auth/concepts/tokens-and-credentials/)
- [Upstream Logseq db-sync protocol at the inspected revision](https://github.com/logseq/logseq/blob/fab27740975dcda1e93dbca718d1f620eda543c7/docs/agent-guide/db-sync/protocol.md)
- [Upstream Logseq Web Crypto primitives at the inspected revision](https://github.com/logseq/logseq/blob/fab27740975dcda1e93dbca718d1f620eda543c7/src/main/frontend/common/crypt.cljs)
- [Upstream Logseq sync E2EE orchestration at the inspected revision](https://github.com/logseq/logseq/blob/fab27740975dcda1e93dbca718d1f620eda543c7/src/main/frontend/worker/sync/crypt.cljs)
- [Upstream Logseq protected sync attributes at the inspected revision](https://github.com/logseq/logseq/blob/fab27740975dcda1e93dbca718d1f620eda543c7/src/main/frontend/worker/sync/const.cljs)
- [Upstream Logseq optional graph-encryption ADR at the inspected revision](https://github.com/logseq/logseq/blob/fab27740975dcda1e93dbca718d1f620eda543c7/docs/adr/0003-optional-sync-graph-encryption.md)
