# Pure Logseq Sync Core and Effect Runner

## Problem

`logseq_sync` currently combines three different concerns behind
`Logseq_sync.Api`:

- deterministic synchronization policy, protocol state, and state projection;
- mutable orchestration state and callback-driven platform operations; and
- Eio fibers, HTTP, WebSocket, filesystem, native cryptography, timers, and
  cancellation.

The module boundary prevents downstream users from importing private sync
implementation modules, but it does not define an effect-free domain boundary.
The current core modules still contain observable mutation and execute injected
callbacks. Representative examples include:

- `Manager.t`, `Auth.t`, `E2ee_session.t`, and `Snapshot.parser` mutating their
  state in place;
- `Startup_phase` allocating witness identifiers through a process-global
  `ref`;
- `E2ee_session` invoking `has_private_key` and `unlock_private_key` callbacks;
- `Network_scope` storing and invoking cancellation callbacks; and
- `Graph_key` owning mutable plaintext bytes and invoking cryptography
  callbacks.

This makes the synchronization policy harder to replay, property-test, compare
across traces, and audit for hidden infrastructure access. It also makes the
current `Api` contract serve simultaneously as a reducer, an effect interpreter,
and a host composition API.

OCaml 5 algebraic effects do not by themselves solve this problem. A core that
calls `Effect.perform` still performs effects, depends on a dynamically installed
handler, and can fail with an unhandled effect. OCaml 5.1 does not encode an
effect row in the function type, so `state -> event -> transition` would not prove
purity if its implementation could perform arbitrary effects.

The desired boundary is instead:

```text
worker coordinator
  -> Logseq_sync.Core.step
       -> immutable next core
       -> ordered typed effect descriptions
            -> public output delivery
            -> worker-owned Engine/storage authority
            -> Logseq_sync.Effect_runner
                 -> Eio/network/files/secrets/crypto/timers
                 -> completion posted to the worker mailbox
                      -> generation fence
                      -> Logseq_sync.Core.step
```

The existing decision that `logseq_db_worker.Managed_coordinator` is the sole
authority for `Engine`, graph lifecycle, SQLite, durable outbox transitions, and
authoritative commits remains in force. Separating the sync core must not move
those capabilities into the sync effect runner.

## Proposal

### Replace `Api` with two canonical specification modules

Replace `logseq_sync/spec/api.mli` with exactly these canonical specification
files:

```text
logseq_sync/spec/
  core.mli
  effect_runner.mli
  dune
```

The supported public namespace becomes:

```text
Logseq_sync.Core
Logseq_sync.Effect_runner
```

`Logseq_sync.Api` is deleted in the same cutover. No alias, forwarding module,
deprecated constructor, or compatibility implementation remains.

`Core` owns immutable domain values, the reducer, explicit typed effect
descriptions, pure codecs, protocol planning, and public state projection.
`Effect_runner` owns every sync-intrinsic interaction with the host environment.
The worker coordinator owns interpretation of worker-authority effects.

The package retains one Dune virtual public library and one default
implementation library to preserve the `Logseq_sync.Core` and
`Logseq_sync.Effect_runner` namespace. The implementation compiles the
pure core in a dependency-restricted private library so purity is a physical
build constraint rather than only a naming convention. The effectful default
implementation may depend on that private core library; the reverse edge is
forbidden.

The intended implementation dependency graph is:

```text
logseq_db_types
      |
      v
logseq_sync_pure_core
      |
      +--------------------------+
      |                          |
      v                          v
logseq_sync_effect_runtime   logseq_db_worker
      |                          |
      +------------+-------------+
                   v
             application host
```

`logseq_sync_pure_core` must not depend on Eio, Unix, SQLite, TLS, HTTPun,
native stubs, `logseq_db_storage`, or `logseq_db_worker`. DataScript is allowed
only as an immutable input/value dependency for transaction planning and
checksum computation. If DataScript operations cannot be shown to be
observationally pure, they move behind a worker-authority effect instead.

### Define a genuinely effect-free `Core`

`Core.t` is an opaque immutable value. `initial` and `step` do not accept
callbacks, switches, clocks, environments, secret adapters, crypto adapters, or
stores. Calling either function must not mutate the supplied state or any
process-global state.

The central `core.mli` API is:

```ocaml
(** Pure synchronization policy and protocol state. *)

type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t

type account_generation = int
type graph_generation = int
type connection_generation = int
type presentation_generation = int
type lifecycle_generation = int64

type sync_phase =
  | Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed

type startup_failure_stage =
  | During_authentication
  | During_catalog
  | During_local_restore
  | During_bootstrap
  | During_e2ee

type startup_facts =
  { authenticated : bool
  ; catalog_loading : bool
  ; awaiting_selection : bool
  ; restoring_local : bool
  ; bootstrapping : bool
  ; awaiting_e2ee_password : bool
  ; failure : startup_failure_stage option
  ; account_generation : account_generation
  ; graph_generation : graph_generation
  ; presentation_generation : presentation_generation
  }

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; applied_server_t : int option
  ; timeline_presentation_pending : bool
  ; startup : startup_facts
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

type limits
type config
type config_error = Invalid_config of string

val limits
  :  maximum_response_bytes:int
  -> maximum_artifact_bytes:int
  -> submission_batch_size:int
  -> (limits, config_error) result

val config
  :  managed_sync_origin:Uri.t
  -> limits:limits
  -> (config, config_error) result

type t
type create_error = Invalid_create of string

val initial : config -> (t, create_error) result
val state : t -> state

type event
type runner_effect
type worker_effect
type output

type instruction =
  | Run of runner_effect
  | Delegate of worker_effect
  | Publish of output

type transition =
  { next : t
  ; effects : instruction list
  }

val step : t -> event -> transition
```

The ordered `instruction list` is intentional. Separate lists for runner work,
worker work, and publication would lose ordering between operations such as
closing a WebSocket, detaching a graph, deleting a mirror, and publishing the
next state.

`state` remains a reduced product and diagnostics projection. Internal phase
constructors, pending permits, recovery continuations, and protocol parser
states remain private inside `Core.t`.

### Keep commands, completions, and authority facts explicit

`event` contains only immutable input facts. It has three conceptual groups:

```ocaml
type event =
  (* Application and worker commands. *)
  | Restore_local_account of { user_id : string }
  | Account_authenticated of { user_id : string option }
  | Local_feed_acknowledged
  | Timeline_presented
  | Token_provided of token_request * string
  | Token_rejected of token_request
  | Graph_selected of graph_id
  | Graph_picker_requested
  | Catalog_refresh_requested
  | Online_recovery_requested
  | E2ee_password_submitted of string
  | Local_cache_deletion_requested of graph_id
  | Foreground_changed of
      { foreground : bool
      ; lifecycle_generation : lifecycle_generation
      }

  (* Worker-authority commit facts. *)
  | Graph_attached of graph_attachment
  | Graph_attachment_failed of scoped_error
  | Local_batch_committed of local_batch_commit
  | Authoritative_batch_applied of authoritative_commit_result
  | Authoritative_batch_failed of scoped_error
  | Outbox_transition_committed of outbox_transition_commit
  | Outbox_transition_rejected of outbox_transition_rejection
  | Snapshot_activated of snapshot_activation
  | Snapshot_activation_failed of scoped_error

  (* Effect-runner completions. *)
  | Runner_completed of runner_completion
  | Websocket_opened of connection_scope
  | Websocket_frame of connection_scope * string
  | Websocket_closed of connection_scope * string option
  | Timer_elapsed of timer_id
  | Shutdown
```

The actual constructors may be grouped behind smart constructors, but every
asynchronous completion must carry an effect identifier and its complete
account, graph, connection, presentation, and lifecycle scope where applicable.
The core is the final authority for rejecting stale completions.

The effect runner posts events to the worker mailbox. It must never invoke
`Core.step` directly or synchronously resume a core continuation.

### Use an explicit typed runner-effect algebra

Do not use `Effect.perform` in `Core`. Represent single-result operations with a
closure-free request/completion GADT and a typed ticket:

```ocaml
type effect_id
type effect_error = Effect_failed of string

type graph_key_handle
type staged_artifact
type catalog_cache

type _ runner_request =
  | Load_catalog : account_scope -> catalog_cache option runner_request
  | Save_catalog : catalog_cache -> unit runner_request
  | Fetch_catalog : authenticated_account_scope -> graph list runner_request
  | Fetch_snapshot_baseline : authorized_graph_scope -> snapshot_baseline runner_request
  | Fetch_snapshot_metadata : authorized_graph_scope -> snapshot_metadata runner_request
  | Download_snapshot : snapshot_download -> staged_artifact runner_request
  | Load_and_unlock_graph_key : graph_scope -> graph_key_handle runner_request
  | Fetch_and_unlock_graph_key : graph_key_request -> graph_key_handle runner_request
  | Unlock_private_key : private_key_unlock -> unit runner_request
  | Encrypt_protected_values : encryption_batch -> encrypted_values runner_request
  | Decrypt_protected_values : decryption_batch -> decrypted_values runner_request

type 'a effect_ticket =
  private
    { id : effect_id
    ; scope : effect_scope
    }

type runner_effect =
  | Request : 'a effect_ticket * 'a runner_request -> runner_effect
  | Start_websocket of websocket_request
  | Send_websocket of websocket_send
  | Close_websocket of connection_scope
  | Schedule_timer of timer_request
  | Cancel_effects of effect_scope

type runner_completion =
  | Completion :
      'a effect_ticket * ('a, effect_error) result -> runner_completion
```

The request GADT makes a mismatched completion unrepresentable in the runner:
`Fetch_catalog` can only produce a graph list, `Unlock_private_key` can only
produce unit, and crypto requests return their corresponding typed batch result.

The runner receives the private ticket with the request and can only construct a
completion with the result type selected by that request. It posts
`Runner_completed completion` without a captured continuation. The core looks up
the ticket ID in immutable pending-effect state, validates its scope, consumes it
exactly once, and applies the operation-specific completion transition.

Request and completion traces therefore contain only data. The implementation
provides explicit equality and redacted diagnostic projections rather than using
polymorphic comparison. Streaming WebSocket events and timers remain separate
because they are not single-result requests.

### Keep secret material out of the core

The pure core must never own a plaintext graph key, private key, password beyond
the input event currently being reduced, IV generator, or mutable zeroizable
buffer.

`graph_key_handle` is an opaque identifier whose storage and zeroization are
owned by `Effect_runner`. Crypto requests carry that handle rather than key
bytes. Signing out, changing account, changing graph, deleting a cache, and
shutdown produce an explicit runner effect to destroy the associated handle.

The handler guarantees:

- a handle cannot be resolved outside its account and graph scope;
- a destroyed handle cannot be used again;
- plaintext key bytes are zeroized when the handle is destroyed;
- password and private-key package values are not retained in core history or
  diagnostics; and
- cancellation or runner shutdown destroys all owned handles.

### Preserve pure sync planning without moving policy into the runner

Transaction encoding, pending-state transitions, pull continuity, checksum
validation, rejection policy, and authoritative checkpoint planning remain core
responsibilities. The runner performs cryptographic primitives but does not
decide synchronization policy.

Local mutation preparation becomes an explicit multi-stage protocol:

```text
worker prepares normalized local mutation
  -> Core event carries mutation identity, database value, and operations
  -> Core determines protected values and emits Encrypt_protected_values
  -> runner returns encrypted values
  -> Core completes wire encoding and constructs an immutable outbox record
  -> Core emits worker effect Commit_local_batch
  -> worker atomically commits projection plus durable outbox
  -> worker posts Local_batch_committed
  -> Core may schedule submission
```

The worker treats this as an internally asynchronous request. It retains the
prepared mutation and the unresolved caller response under a worker-owned
operation ID, releases the coordinator to process other mailbox events, and
resolves the caller only after crypto and the atomic local commit finish. It
must not block the Worker Domain while waiting for the runner completion.

Authoritative application follows the reverse protocol:

```text
WebSocket frame
  -> Core validates message shape and continuity
  -> Core emits Decrypt_protected_values when required
  -> runner returns decrypted values
  -> Core decodes transactions and validates checksum
  -> Core emits worker effect Apply_authoritative_batch
  -> worker atomically commits transactions, checkpoint, and outbox
  -> worker posts Authoritative_batch_applied
  -> Core advances visible sync state
```

To avoid holding `Engine.t` or a prepared worker mutation inside the core, the
worker retains its opaque prepared mutation under a worker-owned operation ID.
The corresponding `worker_effect` carries that ID and the core-produced outbox
or authoritative plan.

The relevant pure public planning surface is expected to include:

```ocaml
type outbox_record
type local_batch_input
type local_batch_plan
type authoritative_batch
type authoritative_plan

val decode_outbox_records : string list -> (outbox_record list, string) result
val encode_outbox_records : outbox_record list -> (string list, string) result
val outbox_record_mutation_id : outbox_record -> graph_id
val outbox_record_fingerprint : outbox_record -> string

val begin_local_batch
  :  local_batch_input
  -> (local_batch_plan, string) result

val local_batch_crypto_request
  :  local_batch_plan
  -> encryption_batch option

val finish_local_batch
  :  local_batch_plan
  -> encrypted_values option
  -> (outbox_record, string) result

val begin_authoritative_batch
  :  authoritative_batch
  -> checkpoint:Logseq_db_types.Sync_checkpoint.t
  -> database:Datascript.db
  -> outbox_records:string list
  -> (authoritative_plan, string) result

val authoritative_crypto_request
  :  authoritative_plan
  -> decryption_batch option

val finish_authoritative_batch
  :  authoritative_plan
  -> decrypted_values option
  -> (worker_effect, string) result
```

The final API may integrate these plans into `step`, but no public planning
function may receive a crypto callback, store callback, mutable client, or
`Engine.t` capability.

### Keep worker-authority effects separate from runner effects

`worker_effect` describes operations that only
`logseq_db_worker.Managed_coordinator` may interpret:

```ocaml
type worker_effect =
  | Inspect_mirror of mirror_request
  | Activate_snapshot of snapshot_activation_request
  | Delete_mirror of mirror_deletion
  | Attach_graph of graph_open_request
  | Detach_graph of { graph_generation : graph_generation }
  | Commit_local_batch of local_batch_commit_request
  | Apply_authoritative_batch of authoritative_batch
  | Commit_outbox_transition of outbox_transition
```

The sync effect runner must not expose `Engine` callbacks in its dependencies
and must not interpret these constructors. The worker iterates the ordered
`Core.instruction list`, executes `Delegate` instructions under its serialized
lock, and posts committed results back as `Core.event` values.

Snapshot download, bounded decompression, streaming parsing, and artifact
validation are runner-owned. Only an opaque validated staged artifact enters the
core. Snapshot installation and mirror activation are worker-owned.

Catalog cache encoding and persistence are runner-owned because the cache is
advisory sync state rather than graph database authority. Cache persistence does
not participate in graph, checkpoint, or outbox transactions, and its failure
must not invalidate an otherwise usable local mirror.

### Define `Effect_runner` as an Eio-native interpreter

The proposed `effect_runner.mli` owns construction and lifecycle of all
sync-intrinsic handlers:

```ocaml
(** Eio-native interpreter for [Core.runner_effect]. *)

type t

type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string

type runtime

val runtime
  :  fork:(sw:Eio.Switch.t -> (unit -> unit) -> unit)
  -> sleep:(float -> unit)
  -> monotonic_ns:(unit -> int64)
  -> (runtime, dependency_error) result

type transport

val transport
  :  network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> (transport, dependency_error) result

type local_store

val local_store
  :  application_support_directory:string
  -> (local_store, dependency_error) result

type artifact_store

val artifact_store
  :  staging_directory:string
  -> (artifact_store, dependency_error) result

type wrapped_key_load_error =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

type secrets

val secrets
  :  has_private_key:
       (managed_sync_origin:Uri.t -> user_id:string -> bool)
  -> unlock_private_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> password:string
        -> private_key_package:string
        -> (unit, string) result)
  -> unlock_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> encrypted_graph_key:string
        -> (string, string) result)
  -> load_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:Core.graph_id
        -> (string, wrapped_key_load_error) result)
  -> verify_and_save_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:Core.graph_id
        -> encrypted_graph_key:string
        -> (unit, string) result)
  -> delete_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:Core.graph_id
        -> (unit, string) result)
  -> delete_account_secrets:
       (managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result)
  -> (secrets, dependency_error) result

type crypto

val crypto
  :  decrypt_private_key:
       (password:string
        -> iterations:int
        -> salt:string
        -> iv:string
        -> ciphertext:string
        -> (string, string) result)
  -> decrypt_graph_key:
       (private_key:string -> ciphertext:string -> (string, string) result)
  -> encrypt_aes_gcm:
       (key:string -> plaintext:string -> (string * string, string) result)
  -> decrypt_aes_gcm:
       (key:string -> iv:string -> ciphertext:string -> (string, string) result)
  -> (crypto, dependency_error) result

val apple_secrets : unit -> (secrets, dependency_error) result
val apple_crypto : unit -> (crypto, dependency_error) result

type dependencies

val dependencies
  :  runtime:runtime
  -> transport:transport
  -> local_store:local_store
  -> artifact_store:artifact_store
  -> secrets:secrets
  -> crypto:crypto
  -> (dependencies, dependency_error) result

val create
  :  sw:Eio.Switch.t
  -> dependencies
  -> post:(Core.event -> unit)
  -> (t, create_error) result

val submit : t -> Core.runner_effect -> unit
val shutdown : t -> unit
```

`submit` starts work and returns without waiting for network, timers, or user
interaction. Every completion is posted through `post`. `post` is the only
runner-to-host callback and is invoked with immutable `Core.event` values.

The runner owns an operation registry that maps core-minted effect IDs to Eio
fiber cancellation handles. The pure core owns scope and staleness policy; the
runner owns the actual cancellation mechanism. Repeated cancellation and late
fiber completion must be harmless.

No custom OCaml 5 effect escapes the runner API. Implementations may use OCaml 5
effects internally, including those used by Eio, but callers interact only with
the explicit `Core.runner_effect` algebra.

### Make purity an enforced boundary

The architecture is incomplete unless repository checks enforce all of the
following:

- `core.mli` contains no Eio, Unix, SQLite, HTTP, TLS, filesystem path adapter,
  secret callback, crypto callback, cancellation callback, or `Effect.t` value;
- the pure core implementation contains no `mutable`, assignment, process-global
  `ref`, `Effect.perform`, `Eio`, `Unix`, `Sys`, native stub, or callback invocation;
- core input constructors and produced effects contain no function values;
- the effect runtime depends on the pure core, never the reverse;
- neither sync module imports `Logseq_db_worker` or `Engine`;
- the effect runner cannot interpret `Core.worker_effect`;
- all effect completions re-enter through the worker mailbox;
- all external results are generation-fenced by the pure core before state
  changes; and
- installed artifacts expose only `Logseq_sync.Core` and
  `Logseq_sync.Effect_runner` as supported sync modules.

Tests should include deterministic transition traces, equality of replayed
states and effects, stale-completion rejection, one-shot effect completion,
handler cancellation, key-handle destruction, local mutation atomicity, and
authoritative commit atomicity.

## Decision

Adopt the pure reducer and typed effect-runner architecture described above.
`Logseq_sync.Core` is the only synchronization policy boundary and exposes an
opaque immutable state, explicit events, ordered effects, pure codecs, and pure
transaction plans. `Logseq_sync.Effect_runner` is the only sync-intrinsic host
interpreter and owns Eio fibers, HTTP, WebSocket connections, timers, files,
secret adapters, plaintext key buffers, cancellation, and completion delivery.

`logseq_db_worker.Managed_coordinator` remains the sole interpreter of
worker-authority effects. It owns Engine lifecycle, mirror installation and
deletion, local mutation publication, durable outbox transitions, authoritative
database application, checkpoint commits, and projection restoration. Every
runner completion re-enters through its mailbox before `Core.step` can consume
it.

Delete `Logseq_sync.Api` and the old mutable Manager, Action, Auth,
E2ee_session, Graph_key, Network_scope, Pending, Replay, protocol, and storage
orchestration paths in the same cutover. Do not retain forwarding modules or
compatibility aliases.

## Alternatives considered

### Perform OCaml 5 effects directly in `Core`

The core could define extensible `Effect.t` constructors for transport, crypto,
storage, and timers and use direct-style code under a handler. This reduces
explicit continuation events but does not produce an effect-free core. Effects
are not visible in OCaml 5.1 function types, missing handlers fail dynamically,
and captured one-shot continuations complicate cancellation, generation fencing,
trace replay, and secret lifetime auditing.

### Keep callback-injected capabilities in `Core`

Passing records of functions avoids concrete Eio or Apple dependencies, but the
core still executes external effects. The API remains difficult to replay and
purity cannot be inferred from a transition signature.

### Keep one `Api` facade around the two layers

A convenience facade would hide the ownership boundary and preserve two ways to
drive the same runtime. The repository does not preserve backward compatibility;
the cutover should establish one path per concept and delete `Api`.

### Use a free monad for the complete sync program

A free monad could represent typed effects and resumptions as data. It introduces
an additional programming model and nested bind structure without solving the
multi-shot WebSocket stream or worker-authority split. The reducer plus explicit
events already provides the required resumable state machine and makes every
asynchronous boundary visible.

### Split only the Dune libraries and retain mutable core objects

Removing Eio dependencies from a library does not make its behavior pure. A
mutable `Manager.t` with injected callbacks would retain the current testing and
replay limitations even if it lived in a library named `core`.

## Acceptance criteria

- `logseq_sync/spec/api.mli` is removed and the only canonical sync
  specifications are `core.mli` and `effect_runner.mli`.
- The only supported public sync modules are `Logseq_sync.Core` and
  `Logseq_sync.Effect_runner`; no `Logseq_sync.Api` compatibility path remains.
- `Core.initial` and `Core.step` are deterministic and return immutable values;
  replaying an event trace from the same initial value produces structurally
  equal states and structurally equal effect requests in the same order.
- The pure core implementation has no infrastructure dependencies, mutable
  state, global counters, callbacks, or performed OCaml effects.
- Runner operations are represented by a typed effect algebra, and mismatched
  operation results cannot be constructed by the effect runner.
- Runner requests and completions are closure-free values with explicit equality
  and redacted diagnostic projections.
- The runner executes only sync-intrinsic effects and posts completions to the
  worker mailbox; it never calls `Core.step`, `Engine`, or SQLite directly.
- Worker-authority effects remain ordered with runner effects and public outputs,
  and only `Managed_coordinator` interprets them.
- Plaintext graph and private keys are owned and zeroized by the effect runner;
  core state and diagnostics contain only scoped opaque handles.
- Local mutation publication still occurs only after atomic projected-database
  and durable-outbox commit.
- Crypto-dependent local mutations remain pending asynchronously without
  blocking the Worker Domain, and completion always re-enters through the worker
  mailbox.
- Authoritative cursor advancement still occurs only after atomic database,
  checkpoint, and outbox commit.
- Local Timeline presentation remains independent of online reconciliation.
- Stale HTTP, WebSocket, timer, crypto, and worker completions cannot mutate the
  current core state.
- Package, source-boundary, reducer trace, runner integration, worker
  coordinator, and application tests pass with the obsolete API and
  implementation paths deleted.

## Implementation evidence

- `logseq_sync/spec/core.mli` and `effect_runner.mli` are the only virtual public
  specifications; `api.mli` and `api.ml` are removed.
- `logseq_sync/lib/pure_core.ml` and `pure_tx.ml` compile in the dependency-
  restricted `logseq_sync_pure_core` library, while `effect_runner.ml` compiles
  in the effectful default implementation.
- `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` owns the mailbox
  reducer loop, Engine lifecycle, mirror authority, atomic local publication,
  authoritative commits, and durable outbox transitions.
- Reducer and runner contracts cover deterministic replay, generation fencing,
  one-shot completions, cancellation, snapshot activation, authoritative pull
  continuity, commit-before-send ordering, and E2EE password isolation.
- `dune build @all`, `dune runtest`, the install/source boundary check,
  `git diff --check`, and `spec-dev-tool check --all` pass.

## Consequences

- Synchronization policy is replayable data transformation rather than mutable
  callback orchestration.
- Runner requests and completions are typed, closure-free values whose scope and
  diagnostics can be compared without exposing secrets.
- Plaintext graph keys remain in zeroizable runner-owned buffers; core state
  retains only scoped opaque handles, and passwords cross only a transient typed
  runner request.
- Local mutation visibility and remote submission remain separated by a
  worker-owned durable commit fact. Authoritative cursor visibility remains
  separated by the worker's atomic data, checkpoint, and outbox commit fact.
- Mirror installation and deletion now live with worker-owned SQLite and graph
  lifecycle authority; downloaded and boundedly decompressed artifacts remain
  runner-owned until delegated for activation.
- Future sync capabilities must extend the explicit event/effect algebra and
  mailbox loop instead of introducing callbacks, global counters, mutable core
  objects, or direct Engine access.

## Risks

- Making `Manager` immutable is a large state-model rewrite and may expose
  transitions that currently rely on mutation order inside one function.
- A closure-free completion algebra is more verbose and can duplicate scope
  fields across request and completion constructors.
- Crypto turns local mutation preparation and authoritative replay into
  multi-stage asynchronous workflows. The worker must retain prepared mutation
  authority until the crypto completion returns or is cancelled.
- Runner-owned snapshot parsing preserves bounded mutable streaming performance
  but places mechanical artifact validation outside the pure domain library.
- Opaque key handles improve secret ownership but require careful cleanup on
  every account, graph, lifecycle, cancellation, failure, and shutdown path.
- Keeping both public modules in one wrapped Dune library preserves the desired
  namespace but may retain Eio as a transitive link dependency for consumers
  that use only `Core`, even though the private pure-core implementation has no
  Eio dependency.
- Explicit effect descriptions are more verbose than direct-style custom OCaml
  effects.

## Questions

None.
