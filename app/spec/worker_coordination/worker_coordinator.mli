(** Pure Worker request/observation/resource coordination, not the whole App.
    Navigation/feed/Favorites algorithms, Capture editing and media UI stay with
    their current business owners. step performs no DB/network/clock/callback IO. *)
module Worker = Worker_api

type t
type view
type 'a ticket
val initial : client_id:Worker.Uuid.t -> t
val view : t -> view
val bootstrap : view -> Worker.bootstrap_state
val projection : view -> Worker.projection option
val mutation_progress : view -> Worker.append_intent -> Worker.mutation_progress option
val intent_progress : view -> Worker.mutation_intent -> Worker.mutation_progress option
val import_progress : view -> Worker.asset_import_intent -> Worker.import_progress option
val handoff : view -> Worker.handoff_id -> Worker.handoff_state option
val asset_notices : view -> Worker.asset_consumer -> Worker.asset_notice list
val session_asset_notices : view -> Worker.session -> Worker.asset_notice list

(** Exact consumer facts and session-level capacity/upload facts are separate;
    upload state is keyed by its checked operation ID. Polling either outlet does
    not acknowledge/release the other; latest-fact retention is bounded. *)
val ticket_id : 'a ticket -> Worker.request_id
val reply : view -> 'a ticket -> 'a Worker.reply option
val observed : view -> 'a Worker.observation -> 'a Worker.observed option
val equal_view : view -> view -> bool

(** Equality includes not-ready/retry/revocation, all request/observation/asset/
    handoff facts and empty residents/no selection/local_deletion transitions.
    Confirmed applies only to its exact still-current presentation; focus change
    retains the durable receipt as Committed_pending_presentation for later readback.
    Reply storage and notice queues are bounded; retired callers must release or
    consume their entries. Durable intent outcome survives request ticket disposal. *)

type event =
  | Worker_bound of Worker.binding
  | Retry_bootstrap
  | Bootstrap_received of Worker.binding * Worker.bootstrap_state
  | Completed : 'a ticket * 'a Worker.reply -> event
  | Projection_received of Worker.projection
  | Observation_received : 'a Worker.observed -> event
  | Asset_received of Worker.asset_notice
  | Cancel : 'a ticket -> event
  | Forget : 'a ticket -> event
  | Release : 'a Worker.observation -> event
  | Handoff_completed of Worker.handoff_id * Worker.handoff_state
  | Drain

type instruction =
  | Bootstrap
  | Send : 'a ticket * Worker.session * 'a Worker.request -> instruction
  | Cancel_request : 'a ticket -> instruction
  | Quiesce of Worker.handoff_id * Worker.host_change
  | Publish of view
  | Schedule_drain

type transition = { next : t; instructions : instruction list }

(** Host supplies a fresh client identity for pure counters; durable mutation IDs
    are independent. Worker_bound enters Awaiting_baseline and schedules Bootstrap.
    Retry never reuses a revoked registration. Ready/Projection is applied as one
    version before admitting Open sessions; all older binding callbacks (including
    not-ready/failure states without a projection) are ignored, even on the same
    unchanged mailbox incarnation.
    request below returns its indexed ticket to the initiating caller directly;
    Send acceptance is tracked by runner, not assumed by the pure transition.

    Cancel requests cooperative stop, not rollback or forgetting ownership. Forget
    retires presentation of the result; runner retains Accepted IDs/tombstones,
    orphan leases/observations and durable unknown/committed outcomes until safely
    reconciled. Cancel racing Observe/Acquire cannot leak a resource. Release is
    encoded with a unit ticket, retried until ACK; late updates cannot reactivate
    it. A query error never unregisters an interest or ACKs a change window.

    prepare_host_change immediately fences affected scopes, queues Quiesce and
    waits for its exact matching handoff result; unrelated resident execution may
    continue. Only one host handoff is active; overlap gets an explicit failure,
    not replacement of its cleanup ledger. Runtime identity and owner checks remain
    required beyond GADT result correspondence. All input-derived batches contain
    fewer than 1000 instructions; remaining work is retained and Schedule_drain
    posts Drain on a later turn. Callbacks only queue events, never call step
    recursively. No new/legacy owner may both consume one terminal response. *)
val step : t -> event -> transition

(** Pure admission planning. Apply exactly the returned transition to this state
    before planning another operation; host serializes this with step. The caller
    obtains the precise typed ticket even for identical concurrent queries, then
    executes instructions through the runner. No existential ticket recovery,
    inference from instruction order or unchecked cast is required. A planning
    refusal sends nothing; Worker queue refusal is a typed Not_admitted reply. *)
val request
  : t -> Worker.session -> 'a Worker.request
  -> ('a ticket * transition, Worker.error) result

(** Return the exact correlation ID to the host. Overlap returns
    Host_change_in_progress without replacing the active handoff/cleanup ledger.
    Retry allocates a new ID; late prior ACKs cannot complete it. Applying the
    returned transition is serialized with request and step. Outcome queries use
    this ID, never just a graph UUID or the most recent unrelated handoff.
    Awaiting_baseline/Bootstrap_not_ready/Bootstrap_failed and absence of an Open
    resident do not forbid prepare using the verified logical host binding. Worker
    checks independent resource/local-copy identity and generations; an unreachable
    owner or unprovable identity stays pending or fails explicitly, never fake Safe.
    Host ordinary deletion/auth/catalog/confirmation policies still apply. *)
val prepare_host_change
  : t -> Worker.host_change
  -> (Worker.handoff_id * transition, Worker.error) result
