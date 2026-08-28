# Complete Logseq Sync Client API

## Problem

The `logseq_sync` package now owns the sync algorithms and runtime adapters, but
it does not yet behave as a complete client library. Its public facade re-exports
roughly twenty-five implementation modules, including `Manager`, `Action`,
`Startup_phase`, `Protocol`, `Http`, `Websocket_eio`, `Mirror`, `Pending`,
`Replay`, `Graph_key`, and `Platform_crypto`. A consumer must understand those
modules, run the manager state machine, interpret its capability-indexed actions,
serialize callbacks, manage cancellation, and join storage, network, crypto, and
graph execution manually.

The only complete composition currently lives in
`logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`. Its managed-sync
runtime owns a serialized Eio mailbox and interprets every manager effect. It:

- loads and persists the remote graph catalog;
- resolves, bootstraps, opens, closes, and deletes local mirrors;
- loads, verifies, saves, unlocks, and deletes E2EE material;
- issues token challenges and routes token responses;
- performs snapshot HTTP requests and artifact downloads;
- opens, drives, reconnects, and closes the WebSocket;
- applies authoritative frames, recovers uncertain submissions, and wakes
  pending transaction submission;
- fences stale work by account, graph, presentation, connection, and lifecycle
  generations; and
- publishes manager state, bootstrap progress, and graph invalidation events.

Consequently, `logseq_sync` is a toolkit while `logseq_db_worker` remains the
actual sync client. This weakens the package boundary established by the earlier
`Extract Logseq Sync Package Boundary` decision: another consumer cannot start a
sync client by depending on `logseq_sync`, and changes to sync orchestration still
require editing a Bonsai-specific worker service.

The current packaging also makes implementation detail part of the supported
surface. `logseq_sync.core`, `logseq_sync.storage`, `logseq_sync.eio`,
`logseq_sync.platform`, and `logseq_sync.spec` are public Dune libraries, and the
root `Logseq_sync` module aliases their modules directly. Internal manager events,
wire messages, pending-file operations, storage paths, raw HTTP requests, secret
operations, and transport handles are therefore all nameable by downstream code.
There is no single canonical interface that distinguishes client API from
implementation API.

The requested end state adds `logseq_sync/spec/client.mli` as the canonical public
contract and exposes only the API declared there. This exploration determines
what “complete client” means at the graph boundary, which runtime model the
contract uses, and which application interactions remain public. It does not
authorize production, Dune, or specification edits while the document remains in
the exploring lifecycle.

## Proposal

### Make one client own the complete sync session

Introduce an opaque `Logseq_sync.Client.t`. A client instance owns exactly one
serialized sync session and is the only component allowed to drive the existing
manager, interpret actions, mutate the catalog cache, control the mirror
lifecycle, use local secrets, perform HTTP requests, own the WebSocket, schedule
reconnects, apply remote frames, and coordinate pending submission.

The intended ownership is:

```text
application / Bonsai worker adapter
  |-- identity changes, token replies, lifecycle and presentation acknowledgements
  |-- local graph mutations
  `-- public client events
          |
          v
Logseq_sync.Client                    virtual API from spec/client.mli
  |-- serialized mailbox
  |-- manager and capability interpreter
  |-- catalog, bootstrap and mirror lifecycle
  |-- HTTP/WebSocket, reconnect and cancellation
  |-- E2EE and local-secret lifecycle
  `-- pending submission and authoritative replay coordination
          |
          v
graph backend                         narrow public integration contract
  `-- open/close graph, apply remote input, inspect pending work
          |
          v
Logseq_db_worker.Engine               remains worker-owned
```

The client must not expose an operation that lets callers feed arbitrary
`Manager.event`, interpret `Action.t`, send raw WebSocket messages, apply raw
protocol frames, edit pending files, or call mirror activation directly. Those
operations become private implementation details behind the serialized owner.

The application still owns user identity and presentation. It tells the client
when a local account is available, when authenticated identity changes, when the
local feed and Timeline have been presented, and when the process moves between
background and foreground. The client requests an ID token through a typed event;
the application answers through a matching public operation. Generation fields
and challenge IDs remain client-minted and opaque to normal callers.

### Preserve the package direction with one graph backend

The prior package decision keeps general graph queries, outliner mutation
planning, and `Engine` in `logseq_db_worker`. Moving `Engine` into `logseq_sync`
would turn the sync package into the complete database worker and recreate the
monolith under a different name.

The selected boundary is therefore a narrow `'graph graph_backend` record in
the public API. The worker supplies `Engine.t` as the hidden type parameter. The
backend supports only operations required by sync orchestration:

- open and close the selected local graph;
- read the applied server transaction and the next pending submission batch;
- apply an authoritative server frame atomically;
- requeue transaction IDs whose submission outcome is uncertain; and
- return display-safe invalidation metadata after authoritative application.

The client owns when these operations occur. The backend owns how they are
implemented. It must not expose the complete worker request/response protocol to
`logseq_sync`, and `logseq_sync` must continue to have no dependency on
`logseq_db_worker`.

Local application mutations continue through the worker. After a committed local
mutation, the worker calls a wake-only operation such as
`Client.notify_local_change`; the client then obtains the pending batch through
the backend. This avoids putting an encoded WebSocket payload in the caller-facing
method and prevents the application from submitting raw transport data.

### Define `Client` as a Dune virtual module

`logseq_sync/spec/client.mli` becomes the only hand-written source of public API.
The root `logseq_sync` library declares `Client` in `virtual_modules` and selects
`logseq_sync.impl` as its default implementation. `logseq_sync/lib/client.ml`
implements that contract directly. Dune generates the `Logseq_sync` wrapper, so
there is no copied or second `logseq_sync.mli` contract that can drift.

The package exposes one supported OCaml namespace, `Logseq_sync.Client`, with all
public types owned beneath that module. Dune also installs the required
`logseq_sync.impl` implementation library so the public virtual library can
select it at link time; it is a linking implementation, not an alternative API.
The existing toolkit libraries and paths are removed:

```text
logseq_sync.core
logseq_sync.storage
logseq_sync.eio
logseq_sync.platform
logseq_sync.spec

Logseq_sync.Manager
Logseq_sync.Action
Logseq_sync.Protocol
Logseq_sync.Http
Logseq_sync.Websocket_eio
Logseq_sync.Mirror
Logseq_sync.Pending
Logseq_sync.Replay
Logseq_sync.Platform_crypto
...and the remaining implementation aliases
```

Core, storage, Eio, platform, specification, and test-support libraries may
remain as private Dune libraries if useful for build organization. They must not
have `public_name` entries, and their compiled modules must not be installed as
consumer-visible interfaces. No deprecated aliases, compatibility facade, or
fallback public sublibrary is retained.

The following sketch is the approved architectural shape rather than a
compilation-ready signature. The canonical `client.mli` may refine field names and
typed errors, but it must preserve this ownership and abstraction level:

```ocaml
module Client : sig
  type graph_id = Logseq_db_types.Graph_types.Uuid.t
  type graph = Logseq_db_types.Managed_graph.t

  type phase =
    | Signed_out
    | Loading_catalog
    | Awaiting_selection
    | Restoring_local
    | Bootstrapping
    | Awaiting_e2ee_password
    | Opening_graph
    | Graph_open
    | Sync_paused
    | Failed

  type snapshot =
    { phase : phase
    ; catalog : graph list
    ; selected_graph : graph_id option
    ; applied_server_t : int option
    ; timeline_presentation_pending : bool
    ; last_error : string option
    }

  type diagnostic_group =
    { title : string
    ; entries : (string * string) list
    }

  type diagnostics =
    { groups : diagnostic_group list
    ; history : string list
    }

  type state =
    { snapshot : snapshot
    ; diagnostics : diagnostics
    }

  type token_request

  type bootstrap_progress =
    { graph_id : graph_id
    ; received_bytes : int64
    ; total_bytes : int64 option
    }

  type invalidation =
    { basis : int64
    ; changed_uuids : graph_id list
    ; changed_uuids_truncated : bool
    }

  type event =
    | State_changed of state
    | Token_requested of token_request
    | Bootstrap_progressed of bootstrap_progress
    | Graph_invalidated of invalidation

  type graph_open_request
  type authoritative_result

  type 'graph graph_backend =
    { open_graph : graph_open_request -> ('graph, string) result
    ; close_graph : 'graph -> (unit, string) result
    ; pending_batch : 'graph -> string option
    ; apply_authoritative :
        'graph -> string -> (authoritative_result, string) result
    ; requeue_submitted :
        'graph -> transaction_ids:string list -> (unit, string) result
    }

  type platform

  type config =
    { application_support_directory : string
    ; managed_sync_origin : Uri.t
    ; platform : platform
    }

  type 'graph t

  val create :
    sw:Eio.Switch.t ->
    environment:Eio_unix.Stdenv.base ->
    config ->
    graph_backend:'graph graph_backend ->
    on_event:(event -> unit) ->
    ('graph t, string) result

  val state : _ t -> state
  val restore_local_account : _ t -> user_id:string -> unit
  val reconcile_authenticated_user : _ t -> user_id:string option -> unit
  val acknowledge_local_feed : _ t -> unit
  val acknowledge_timeline_presented : _ t -> unit
  val provide_token : _ t -> token_request -> token:string -> unit
  val reject_token : _ t -> token_request -> unit
  val select_graph : _ t -> graph_id -> unit
  val return_to_graph_picker : _ t -> unit
  val refresh_catalog : _ t -> unit
  val begin_online_recovery : _ t -> unit
  val submit_e2ee_password : _ t -> string -> unit
  val delete_local_cache : _ t -> graph_id -> unit
  val set_foreground : _ t -> bool -> unit
  val notify_local_change : _ t -> unit
  val shutdown : _ t -> unit
end
```

The exact contract must improve on this sketch in three ways when implementing
`spec/client.mli`:

1. public constructors should represent only states and input that an application
   can legitimately observe or provide;
2. opaque values should prevent callers from forging token challenges, graph-open
   requests, authoritative results, or generation fences; and
3. error values should become typed variants where callers can recover, while
   diagnostics that are only displayable may remain bounded strings.

### Move orchestration out of the Bonsai service

After the client exists, the managed branch of
`Logseq_db_worker_bonsai_service` becomes an adapter instead of the sync runtime.
It should:

- construct a `Client.t` with an Engine-backed graph backend;
- translate manager-facing worker requests into public client calls;
- translate client events into worker pushes;
- continue to execute ordinary graph requests through `Engine`; and
- call `Client.notify_local_change` after a local commit produces pending work.

It should no longer contain manager action interpretation, catalog persistence,
snapshot transport, E2EE bootstrap, WebSocket ownership, reconnect scheduling,
pending recovery, or sync-frame application policy. Bonsai worker types and push
topic IDs remain outside `logseq_sync` so the client library stays usable without
`bonsai_flutter`.

### Migration and validation direction

The eventual proposal should use a direct cutover because the repository does
not preserve backward compatibility:

1. add the selected virtual `Client` contract and public API contract tests;
2. move the serialized runtime and action interpreters into a private client
   implementation under `logseq_sync`;
3. introduce the graph backend and replace direct `Engine` calls in the moved
   runtime;
4. reduce the Bonsai service to a client adapter;
5. replace application uses of `Logseq_sync.Manager.*` with the public client
   commands and state;
6. make all implementation modules private behind the required default
   implementation library and remove every old facade alias in the same cutover;
   and
7. update source-boundary tests to enforce the installed API, not the old module
   list.

Validation must include focused client lifecycle tests, stale callback fencing,
offline startup, snapshot bootstrap, E2EE, reconnect, pending submission,
authoritative replay, shutdown cancellation, application integration, installed
package inspection, macOS/iOS builds, `dune build @all`, `dune runtest`, formatting,
and `spec-dev-tool check --all`.

## Decision

- Define a complete sync client as the complete synchronization lifecycle, not
  as the general graph query and mutation engine. Keep `Engine` in
  `logseq_db_worker` and integrate it through the narrow graph backend.
- Make the public client Eio-native. It owns its fibers under a caller-provided
  `Eio.Switch.t` and uses a caller-provided `Eio_unix.Stdenv.base`.
- Keep authentication asynchronous and typed. The client emits an opaque token
  request, and the host answers with `provide_token` or `reject_token`.
- Expose one supported namespace, `Logseq_sync.Client`, and remove the flat
  implementation-module aliases and toolkit sublibraries. Retain only the Dune-
  required `logseq_sync.impl` default implementation library.
- Expose an injectable platform capability for local secrets and private-key
  operations so non-Apple hosts can implement the same client contract.
- Expose a reduced product snapshot and a separate display-safe diagnostics
  record. Do not preserve every internal manager phase or generation field in
  the product snapshot.
- Treat `logseq_sync/spec/client.mli` as the virtual `Client` interface and only
  hand-written source of public API. `logseq_sync/lib/client.ml` is its default
  implementation; all other implementation modules remain private.

These decisions were approved by the user on 2026-08-27.

## Alternatives considered

### Keep the public toolkit and add a convenience client

Adding `Client` while retaining all current modules would permit incremental
migration, but it would preserve two supported ways to perform sync. Consumers
could bypass serialization and lifecycle fencing through low-level APIs, and the
package would still expose implementation details. This conflicts with the
requested single public API and the repository rule to remove obsolete paths.

### Move `Engine` and general graph operations into `logseq_sync`

This would make one library own both synchronization and all graph queries and
mutations. It would also move outliner planners, read models, backup, request
budgets, and worker protocol behavior into sync. The result would be a renamed
database worker rather than a focused sync client, and it would reverse the
previously approved ownership boundary.

### Keep orchestration in `logseq_db_worker` behind a smaller facade

A smaller facade alone would hide tools but would not produce a reusable client.
The package would still require a Bonsai-specific worker to interpret its state
machine and perform network and storage effects.

### Expose the existing `Manager.command` and `Manager.snapshot` unchanged

This would reduce call-site work, but those values contain internal generation
fields and startup-state-machine details. A complete client can mint and validate
those values internally. The public contract should expose intent-oriented
operations and stable observations instead of an internal command/event bus.

### Make every runtime effect a public callback

Injecting HTTP, WebSocket, filesystem, clock, sleep, crypto, storage, and task
spawning individually would maximize portability. It would also reproduce the
current toolkit at construction time and make callers responsible for assembling
a correct client. The preferred boundary injects only capabilities genuinely
owned by the host: graph execution, identity/token acquisition, event delivery,
and any platform secret implementation that cannot live portably in the package.

## Acceptance criteria

- `logseq_sync/spec/client.mli` is the single canonical, public-only contract.
- Installing `logseq_sync` exposes only the approved `Logseq_sync.Client` module;
  no `logseq_sync.core`, `.storage`, `.eio`, `.platform`, or `.spec` toolkit
  library is installed. The required `logseq_sync.impl` library exposes no
  additional supported OCaml module.
- A consumer can create, drive, observe, and shut down a complete sync session
  without importing `Manager`, `Action`, `Protocol`, transport, mirror, replay,
  pending, catalog-store, or platform implementation modules.
- One serialized client owner performs all sync state transitions and effects.
- `logseq_sync` has no direct or transitive dependency on `logseq_db_worker` or
  `bonsai_flutter`; the graph backend is the only worker integration boundary.
- The Bonsai service contains only public-client adaptation plus ordinary graph
  request execution, not sync orchestration.
- Internal generation fencing, presentation-gated startup, WebSocket-only pull
  and submission, offline startup, atomic replay, pending recovery, E2EE, and
  local-secret custody preserve their current behavior.
- Old public paths are deleted without aliases, compatibility layers, or
  fallback libraries.
- Contract tests reject accidental public additions and inspect the installed
  package to prove that private compiled modules are not exposed.
- Focused sync tests, worker/application integration tests, macOS/iOS builds,
  the full Dune build and test suites, formatting, and all decision-document
  checks pass.

## Risks

- The graph backend can become a disguised copy of the worker protocol if its
  operations are not limited to sync-owned needs.
- Making internal libraries private may reveal hidden downstream dependencies
  in tests, tools, or the application that currently rely on low-level modules.
- Moving the action interpreter changes cancellation and serialization ownership;
  an incomplete move could permit callbacks after shutdown or apply stale work.
- An Eio-specific public API is simpler and matches the implementation, but it
  prevents use from a runtime that cannot host Eio without an additional adapter.
- A runtime-neutral API may require exposing so many scheduling and transport
  capabilities that the library again feels like a toolkit.
- Simplifying public snapshots can omit state required by the proposed sync
  diagnostics UI; that UI and the client API must share one deliberate,
  display-safe diagnostic projection.
- A public platform capability can expose too much crypto detail, while an
  Apple-only built-in platform prevents the package from being a general OCaml
  sync client.
- The current worktree has overlapping uncommitted extraction and sync-test
  changes. Implementation must preserve those changes and begin only after this
  decision is proposed.

## Consequences

- Consumers integrate synchronization exclusively through `Logseq_sync.Client`.
  They no longer own manager transitions, transport handles, mirror activation,
  pending-file operations, reconnect scheduling, or generation fences.
- Each client requires an Eio switch and environment, owns one serialized session,
  and must be shut down before its enclosing switch is released.
- `logseq_db_worker.Engine` remains worker-owned and implements the narrow graph
  backend. Ordinary local mutations continue through the worker and wake the
  client only after they commit.
- Platform-specific secret custody is injected through the opaque client platform
  capability. Apple hosts use the default implementation; portable tests and
  non-Apple hosts can supply another implementation without importing platform
  internals.
- The cutover is intentionally breaking. Old public sublibraries and root aliases
  are unavailable, and downstream code must migrate directly to the Client API.
- Public API changes start in `logseq_sync/spec/client.mli`; Dune compiles it as
  the virtual `Client` module and links `logseq_sync/lib/client.ml` through the
  default `logseq_sync.impl` implementation. Other implementation interfaces
  remain package-private.

## Questions

- None. The graph boundary, Eio runtime, authentication handshake, public
  namespace, platform injection, and snapshot shape were approved on 2026-08-27.
