# Local Timeline Startup Must Not Wait for Network

## Problem

The application already has a partial local-first startup path for a managed sync
graph. After the authenticated user is known, the worker loads the account-scoped
catalog cache, restores its selected graph, inspects the local mirror, and can open
that mirror before the online catalog request completes. After the local engine
reports `Graph_opened`, the Bonsai application can start its graph runtime without
waiting for the WebSocket to become live.

This behavior is not yet an explicit startup invariant. Several independent paths
can still delay, preempt, or tear down the local startup path:

- `Sync_manager.Authenticated_user` creates a catalog-discovery token challenge
  before `Logseq_db_worker_bonsai_service` loads and dispatches the cached catalog;
- `Sync_manager.Graph_opened` immediately creates a WebSocket-connect token
  challenge;
- online catalog, authentication, WebSocket, pull, and error events return to the
  same serialized manager and engine owner used by local graph open and feed reads;
- an online result can clear the selected graph or change the manager phase before
  the first Timeline frame is presented;
- catalog-cache event handling can synchronously save, `fsync`, rename, and
  directory-`fsync` advisory cache state before local graph work continues;
- the initial feed waits for page trees from as many as seven journal days in
  strict request-response order before emitting one `Feed_loaded` result;
- the application sends an initial `Graph_info` request before a managed graph is
  open, receives a predictable failure, then resets and sends it again after graph
  selection;
- calendar, account identity, and typography are separate application-platform
  startup requests, and typography currently gates the entire Bonsai body;
- an encrypted mirror is not locally usable when its graph key or private-key
  unlock material still requires a remote E2EE request.

The required product behavior is not network quiescence. Network work may start in
parallel with local startup. The requirement is instead that, when a usable local
graph exists, no network result is a dependency of Timeline presentation:

> A delayed, failed, reordered, or permanently unresolved network operation must
> not increase time to the first locally resolved Timeline frame.

The product accepts that this policy can display locally retained graph data before
the server confirms that access has not just been revoked. If later online
reconciliation reports revocation or a different authenticated account, the
application may close the graph after the local Timeline has been presented and
show an appropriate authentication or authorization state.

## Proposal

### Define the warm-start contract

Treat a graph as locally startup-ready only when all required local capabilities
are available:

- a locally restored account identity scopes the catalog cache;
- that cache contains a selected graph for the same account and managed-sync
  origin;
- the selected graph has an existing mirror that passes normal ownership,
  admission, storage, and sync-metadata validation;
- the mirror can be opened without obtaining a network result;
- for an encrypted graph, all key material needed to open the plaintext local
  mirror is available through local secure storage and local unlock policy.

Define `Timeline_presented` as successful Flutter presentation of a frame in which
the Journal Timeline has applied its first local feed result. The result may contain
entries or a truthful locally resolved empty state. A frame that still says
`Loading journal` does not satisfy this milestone.

Define time to Timeline, or TTFT, as the monotonic duration from the production
Dart entrypoint beginning application launch to `Timeline_presented`.

### Run local startup and online reconciliation as independent lanes

Use one local critical path and one parallel online path:

```text
Local critical path
  local account identity
  -> cached selected graph
  -> inspect local mirror
  -> open local engine
  -> graph info and first local feed chunk
  -> Timeline_presented

Parallel online path
  Amplify session reconciliation
  -> fresh ID-token challenges
  -> catalog refresh
  -> WebSocket handshake
  -> authoritative pull and pending submission
  -> post-presentation reconciliation
```

The online lane may begin before `Timeline_presented`, but the local lane must not
await a future, promise, token challenge, HTTP request, WebSocket state, reconnect
timer, or online manager phase owned by the online lane.

This decision does not require network requests to start on every warm launch. It
permits them to start early when their prerequisites are available. The observable
guarantee is independence of the local Timeline milestone from their outcome.

### Make startup presentation an explicit state

Represent the presentation boundary explicitly rather than deriving it from a
network or manager phase. One possible closed state is:

```text
Restoring_local
Local_feed_ready
Timeline_presented
Reconciled
```

The exact public type remains an implementation decision, but it must distinguish
local data readiness from online reconciliation readiness. `Graph_open`,
`Sync_paused`, `Loading_catalog`, and WebSocket readiness are sync-manager facts;
none of them is a substitute for `Timeline_presented`.

Online results that would replace, close, or invalidate the locally selected graph
must be generation-fenced and held as pending reconciliation while startup remains
before `Timeline_presented`. Examples include:

- the refreshed catalog omits the cached selected graph;
- Amplify reports a different account or a signed-out session;
- an online error would otherwise change the root route from the Timeline to a
  manager error page;
- a transport event requests graph replacement or local-cache reset.

After `Timeline_presented`, apply the current-generation pending reconciliation in
the serialized manager. Revocation may then close the graph and show an
authorization message. Stale account, graph, connection, lifecycle, and
presentation generations must be ignored.

Non-destructive online status may be recorded before presentation, but it must not
change graph readiness, feed readiness, the selected local graph, or the root
presentation route.

### Prioritize local restore before emitting online work

On locally restored authentication, schedule work in this order:

1. load the account- and origin-scoped catalog cache;
2. restore its selected graph;
3. inspect and open the local mirror;
4. publish local graph availability to the Bonsai application;
5. independently emit the catalog-discovery ID-token challenge;
6. independently begin online catalog refresh and, once the local graph is open,
   WebSocket setup.

The token challenge and catalog request may overlap engine open. Reordering gives
local work deterministic priority and makes it impossible for token acquisition to
become an accidental prerequisite.

The production entrypoint must continue to configure Amplify before mounting
`Authenticator`, as required by the implemented macOS configuration-deadlock
decision. Amplify configuration is distinct from awaiting a fresh ID token or an
online catalog response. The local fast path must not call `freshIdToken` or await
token refresh to identify the cache owner.

### Use a local account binding for the fast path

The local path needs an account identity before it can safely select a cached graph.
It must not guess from the newest catalog file or expose a graph before account
scoping is known.

Persist a bounded local account binding when a Cognito session is successfully
authenticated. At minimum it identifies:

```text
user_id
managed_sync_origin
```

Store this binding as an application-owned Apple Keychain generic-password item,
separate from both Amplify's internal session records and the existing E2EE
private-key item:

```text
kSecClass: kSecClassGenericPassword
kSecAttrService: com.logseq.journal.local-account-binding
kSecAttrAccount: current-managed-sync-account
kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
kSecValueData: bounded versioned encoding of user_id and managed_sync_origin
```

The item is not synchronizable through iCloud and uses the signed application's
default Keychain access group. On macOS it follows the existing Journal E2EE
Keychain query behavior rather than opting into a different Keychain backend. It
must not reuse, inspect, or depend on Amplify's private storage keys.

Native platform code owns Keychain reads, writes, and deletion. Flutter receives a
bounded local binding through a narrow platform capability and supplies it to the
OCaml application-platform path; it does not add the binding to the `LDB1` worker
startup envelope. The binding contains no ID token, refresh token, password, graph
key, selected graph identifier, or Timeline data. The selected graph remains in the
account- and origin-scoped catalog cache below Application Support.

The selected graph remains owned by the scoped catalog cache rather than duplicated
as an independent source of truth. Explicit sign-out clears the binding and local
E2EE unlock material according to the selected security policy. Online Amplify
session reconciliation runs in parallel and can invalidate the binding only through
the post-presentation reconciliation boundary during a qualifying warm start.

If no valid local account binding exists, the local fast path is unavailable. The
application follows the normal Authenticator and online recovery flow; this case is
outside the warm-start guarantee.

### Keep network activity away from the local engine critical path

Network waits must remain in supervised Eio fibers and must never occupy the serial
worker handler. Their completions return typed, generation-scoped events to the
serialized owner.

Before `Timeline_presented`, the serialized owner prioritizes:

1. mirror inspection and engine open;
2. `Graph_info`;
3. initial journal page discovery;
4. the first journal page-tree read;
5. application of the first local feed chunk.

Catalog completions, WebSocket frames, authoritative pull application, reconnect,
pending submission, and advisory cache persistence must not starve these operations.
An implementation may use separate high- and normal-priority event queues or an
explicit startup barrier. It must preserve the existing invariant that network
fibers never call `Engine.execute`, DataScript, `Storage_session`, or SQLite
concurrently.

The WebSocket handshake may run before Timeline presentation. To avoid graph work
preemption, authoritative pull results and other engine-mutating sync events remain
pending until the first local feed chunk is applied. A simpler valid implementation
may connect the socket early but defer the initial `pull` until
`Timeline_presented`.

### Remove synchronous advisory persistence from the critical path

The catalog cache is advisory startup state. Preserve its atomic and durable file
format, but do not synchronously rewrite unchanged cache state during warm restore.

- compare old and new cache values and mark dirty only for a semantic change;
- coalesce repeated catalog, selection, and mirror-status changes;
- perform the file write and both `fsync` operations outside the serial graph
  critical path;
- flush dirty cache state after Timeline presentation and during orderly shutdown;
- do not make current-session graph availability depend on successful advisory
  cache persistence.

A user-selected graph must still become durable, but its cache write need not
precede opening or presenting that graph.

### Make the initial feed progressive

The local Timeline should not wait for every configured startup day. After journal
page discovery, enqueue the bounded page-tree reads without making each next request
depend on the preceding response. Apply the most recent usable day as the first feed
chunk and present the Timeline. Continue loading and inserting older days locally
afterward while preserving stable keys, descending day order, slot budgets, cursor
semantics, and the single Journal scroll owner.

The first implementation may retain the existing worker protocol and queue all
bounded `Get_page_tree` requests after `List_pages`. A later protocol decision may
introduce one bulk Journal-feed read if measurements show that worker request and
reactive-frame overhead remains material. Any change to an OCaml `.mli` under
`spec/` requires separate explicit authorization under repository policy.

An empty graph satisfies the milestone when local page discovery proves that the
feed is empty. It must not wait for online catalog or sync activity to decide that
the local Timeline is empty.

### Remove the pre-engine managed `Graph_info` request

Do not start `Journal_graph_runtime` for a managed target before the sync manager
has selected and opened a graph. Start it when the current graph generation has a
selected graph and durable local sync status. Typed local graph targets that own an
engine at service initialization may retain immediate startup.

When both the local graph and calendar context are available, schedule graph-info
validation and initial feed loading in the same local startup batch. Continue to
withhold writes until `Graph_info` succeeds.

### Prefetch local platform facts without adding network dependencies

Application Support path, initial calendar facts, and persisted typography are
local platform facts. Fetch them together or cache the first native environment
result so that the OCaml application does not require redundant MethodChannel
round trips. The first calendar request should be able to consume the retained
initial snapshot, and the first typography request should consume the retained
native preference.

Typography must retain its no-flash behavior, but reading a local preference should
run in parallel with engine startup rather than serializing it. This optimization
must not put Amplify token acquisition or any online result into the application
startup payload.

### Require encrypted graphs to be locally decryptable

An encrypted mirror cannot meet the non-blocking guarantee when opening it requires
an ID token, a remote graph-key response, or a remote user-key response. The selected
definition of an existing graph therefore requires that all key material needed to
open the mirror is already available locally. An encrypted mirror without locally
available key material is outside this fast-path contract even when its mirror files
exist.

Persisting additional wrapped graph-key material in Keychain is not part of this
decision. It requires a separate security decision before it can broaden the
fast-path population.

Never place graph keys, private keys, passwords, or tokens in the catalog cache,
startup payload, preferences, diagnostics, or logs. Sign-out, graph deletion,
account replacement, and key rotation require explicit secure-key invalidation.

If the selected encrypted mirror is not locally decryptable, show a bounded unlock
or recovery state. Network key retrieval may proceed in parallel, but this case does
not satisfy the proposed warm-start contract unless the product explicitly broadens
the definition of an existing graph.

### Measure the invariant rather than network absence

Add monotonic milestones for at least:

- production Dart entrypoint start;
- Amplify configuration complete;
- native startup facts available;
- runtime started;
- local account binding loaded;
- catalog cache loaded;
- mirror inspection start and completion;
- engine open start and completion;
- graph info complete;
- first local feed chunk applied;
- Timeline frame presented;
- first ID-token request, catalog request, WebSocket connect, and online
  reconciliation application.

Measure release/profile builds separately from debug builds. Report warm-start TTFT
at p50 and p95 for online, delayed-network, failed-network, and never-resolving
network fixtures. Record graph size and encrypted/unencrypted status with each
sample.

## Decision

Implement managed warm startup as two independently progressing lanes separated by
an explicit, generation-fenced presentation barrier. The local lane restores the
account- and origin-scoped catalog from an application-owned, device-only Keychain
binding, opens a locally usable mirror, and applies the first progressive feed chunk
without awaiting Amplify reconciliation or any sync-network result. The online lane
may start concurrently, but destructive account, catalog, pull, and transport
reconciliation remains pending until Flutter acknowledges the first Timeline frame.

Keep the serial worker as the sole engine owner. Run network operations and advisory
catalog persistence in supervised fibers, coalesce semantic catalog changes, and
flush them only after presentation or during orderly shutdown. Managed targets start
graph runtime work only after the selected graph is open. Startup platform facts are
retained from one native snapshot, and the initial feed reads bounded page trees
concurrently while publishing cumulative, generation-scoped chunks in descending
day order.

## Alternatives considered

### Prohibit all network until Timeline presentation

This creates the strongest isolation but unnecessarily delays catalog refresh and
WebSocket readiness. The requested behavior permits useful network overlap as long
as it cannot block or preempt local presentation. A hard network gate is therefore
not selected.

### Wait for online authentication and catalog authorization before local open

This prevents briefly displaying a graph after remote revocation, but makes warm
startup latency and offline availability depend on Cognito and the sync service.
The product explicitly accepts post-presentation revocation reconciliation, so
online authorization is not a local Timeline prerequisite.

### Start all work concurrently without a presentation barrier

This minimizes explicit lifecycle state but permits a fast catalog revocation,
account change, sync replay, cache `fsync`, or dense WebSocket event stream to alter
or starve the local startup path. Concurrency without ordering does not provide the
required non-blocking guarantee.

### Render a persisted Timeline projection before opening SQLite

A bounded projection cache could reduce TTFT below engine-open latency, but it adds
another invalidation, mutation, basis, account, locale, and schema boundary. First
remove critical-path persistence, make feed loading progressive, and measure the
remaining engine-open cost. A projection cache remains a later decision if those
changes do not meet the selected TTFT target.

### Treat an existing mirror as sufficient without account scoping

Selecting a mirror by recency or filesystem presence could expose another locally
retained account's data. The local path must know the account and origin that own
the cached selection before rendering any graph content.

## Acceptance criteria

- A production-equivalent warm start with a locally startup-ready graph presents a
  locally resolved Timeline without awaiting a fresh ID token, catalog HTTP result,
  WebSocket state, authoritative pull, reconnect, or pending submission.
- A fixture in which every network future starts and then remains unresolved still
  reaches `Timeline_presented` and produces the same local entries or truthful empty
  state as a normal-network fixture.
- Delaying catalog, ID-token, WebSocket, and pull outcomes by at least 30 seconds
  does not change the local startup state sequence. The never-resolving-network p95
  TTFT must not exceed normal-network p95 TTFT by more than
  `max(50 milliseconds, 5% of normal-network p95 TTFT)`.
- A never-resolving-network fixture presents its locally resolved Timeline within
  three seconds of the production Dart entrypoint starting.
- Immediate network failure does not replace the local route with an authentication,
  catalog, graph-open, or sync error before Timeline presentation. The error may be
  shown as non-blocking sync status afterward.
- An online catalog result that omits the cached selected graph is held until after
  `Timeline_presented`; current-generation reconciliation then closes the graph and
  presents an authorization result.
- A different-account or signed-out Amplify reconciliation result is similarly
  fenced until after presentation for a qualifying warm start, then applied without
  retaining the previous account's graph.
- Network fibers do not call the engine concurrently, and catalog or transport event
  volume cannot starve mirror open, graph info, or the first local feed chunk.
- Warm restore does not synchronously rewrite an unchanged catalog cache and does
  not await cache `fsync` before opening the graph or presenting the Timeline.
- Initial feed loading presents the most recent locally resolved chunk without
  waiting for all seven startup days; older local days fill progressively with
  stable ordering, keys, cursors, slot budgets, and one scroll owner.
- A managed target sends no predictable pre-engine `Graph_info` request. It starts
  graph runtime work once for the current opened graph generation.
- Calendar and typography startup facts remain local, bounded, and available
  without any online dependency or visual typography flash.
- A missing or corrupt mirror does not masquerade as a successful warm start. It
  enters explicit recovery while any allowed network bootstrap proceeds separately.
- Account, graph, connection, lifecycle, and startup-presentation generations fence
  late local and online completions.
- Tests cover normal, delayed, failed, never-resolving, and immediate-revocation
  network behavior; offline local restore; empty and populated feeds; account
  replacement; graph switching; application termination; and locally decryptable
  and non-locally-decryptable encrypted mirrors.

## Risks

- The application may briefly display locally retained data for a graph whose
  server authorization was revoked immediately before launch. The product accepts
  this offline-access trade-off and applies current-generation revocation after the
  Timeline presentation boundary.
- A separate local account binding becomes security-sensitive state. Incorrect
  clearing or scoping could expose the wrong retained graph, while overly aggressive
  clearing could disable valid offline startup.
- Deferring destructive reconciliation needs bounded pending state. Unbounded
  WebSocket or catalog buffering could trade startup latency for memory growth.
- Priority queues or barriers can introduce starvation in the opposite direction.
  The presentation boundary must be bounded and must always release online work on
  success, local failure, cancellation, graph switch, account switch, or shutdown.
- Progressive feed results can reorder or duplicate Timeline slots if generation,
  continuation, day ordering, and stable-key rules are incomplete.
- Deferring cache persistence can lose the latest selection on a crash before the
  background flush. The current session remains correct, but the next launch may
  return to graph selection.
- Secure local E2EE key availability changes the offline threat model and requires
  an explicit Keychain lifetime and invalidation policy.
- Optimizing MethodChannel and authentication ordering must not reintroduce the
  previously fixed Amplify/Authenticator configuration deadlock.

## Consequences

- Warm Timeline presentation is independent of token refresh, catalog HTTP,
  WebSocket readiness, authoritative pull, and pending submission outcomes.
- A current locally retained graph may be visible briefly before a later online
  revocation, sign-out, or account replacement is applied.
- The native hosts own an additional bounded Keychain item and must clear it on
  explicit sign-out while preserving account and managed-origin scoping.
- Advisory catalog durability is asynchronous during normal operation, so a crash
  may lose the newest selection even though orderly shutdown waits for the active
  flush and persists the latest dirty snapshot.
- Timeline consumers receive progressive cumulative feed results and must retain
  generation, continuation, ordering, slot-budget, and stable-key fences until the
  final chunk is complete.
- Encrypted mirrors without all required local key material remain outside the warm
  startup contract and continue through bounded unlock or online recovery.

## Questions

- None. The fast path covers only locally decryptable mirrors. The application may
  persist the specified application-owned Keychain account binding and reconcile it
  with Amplify after Timeline presentation. TTFT uses the selected combined p95
  tolerance and three-second never-resolving-network bound.
