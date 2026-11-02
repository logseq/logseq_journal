(** Pure Worker request/observation/resource coordination, not the whole App.
    Navigation/feed/Favorites algorithms, Capture editing and media UI stay with
    their current business owners. step performs no DB/network/clock/callback IO. *)
module Worker = Worker_api

type t
type view
type 'a ticket
type change_application

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

(** Exact immutable execution provenance is recorded only when Send is emitted,
    including reads queued before baseline. Collect it before Forget; no queued
    owner or later projection may stand in for the session/budget actually sent. *)
val query_origin : view -> 'a ticket -> (Worker.session * Worker.read_budget) option

(** Reuse the coordinator's current Open-session and host-handoff fences before
    presenting buffered read data. A supplied business owner must exactly match
    the session's account/graph generations and graph UUID. This is a pure local
    eligibility check; it
    does not grant backend resource release, writer or deletion permission. *)
val validate_session
  :  ?owner:Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope
  -> t
  -> Worker.session
  -> (unit, Worker.error) result

(** A sampled read error retains the acknowledged interest. This outlet returns
    only the exact registered handle planned by this ticket, never a fabricated one. *)
val observation_handle : view -> 'a Worker.observed ticket -> 'a Worker.observation option

val observation_error : view -> 'a Worker.observation -> Worker.error option
val observed : view -> 'a Worker.observation -> 'a Worker.observed option

(** The business owner reports causal read creation, then application to its UI
    (or explicit consumer retirement). A read failure retains its window. Tokens
    bind one application attempt and reject callbacks from prior retries. *)
val owns_change_batch : view -> Worker.change_batch -> bool

val change_application_started : view -> Worker.change_batch -> bool
val change_application_ready : view -> Worker.change_batch -> bool
val change_application_error : view -> Worker.change_batch -> Worker.error option
val equal_view : view -> view -> bool

type shutdown_state =
  | Active
  | Draining
  | Stopped
  | Shutdown_failed of Worker.error

val shutdown_state : view -> shutdown_state

(** Equality includes not-ready/retry/revocation, all request/observation/asset/
    handoff facts and empty residents/no selection/local_deletion transitions.
    Confirmed applies only to its exact still-current presentation; focus change
    retains the durable receipt as Committed_pending_presentation for later readback.
    Reply storage and notice queues are bounded; retired callers must release or
    consume their entries. Durable intent outcome survives request ticket disposal. *)

(** Registration metadata is independent of sampled data success. It retains
    cleanup ownership through error/cancellation; it grants no live data authority.
    Forget disposes an Observe reply only; Cancel retires its logical interest.
    Full cleanup waits for external Capacity_available. Internal Drain advances
    bounded new work without busy-retrying refused resources. Terminal cleanup
    failures remain observable until explicit Cancel/Release retries them. *)
type event =
  | Worker_bound of Worker.binding
  | Retry_bootstrap
  | Binding_invalidated of Worker.binding
  | Admitted :
      'a ticket * Logseq_db_worker_lui.Journal_worker_ids.Worker.request_id
      -> event
  | Admission_refused : 'a ticket * Worker.admission_error -> event
  | Admission_failed : 'a ticket * Worker.error -> event
  | Bootstrap_admitted of
      Worker.binding * Logseq_db_worker_lui.Journal_worker_ids.Worker.request_id
  | Bootstrap_not_admitted of Worker.binding * Worker.admission_error
  | Binding_release_completed of Worker.binding * (unit, Worker.error) result
  | Binding_release_not_admitted of Worker.binding * Worker.admission_error
  | Capacity_available
  | Shutdown_requested
  | Bootstrap_received of Worker.binding * Worker.bootstrap_state
  | Completed : 'a ticket * 'a Worker.reply -> event
  | Projection_received of Worker.projection
  | Changefeed_notice of
      Worker.changefeed_notice
      * Logseq_db_worker_lui.Journal_worker_ids.Worker.push_sequence
  | Change_application_retired of change_application
  | Change_consumer_expanded of
      change_application * Worker.Uuid.t * Worker.Uuid.t Rrbvec.t
  | Change_consumer_applied of
      change_application * Worker.Uuid.t * (unit, Worker.error) result
  | Change_consumer_retired of change_application * Worker.Uuid.t
  | Observation_registered :
      'a Worker.observed ticket * 'a Worker.observation * Worker.observation_epoch
      -> event
  | Observation_release_completed of
      Worker.session * Worker.request_id * (unit, Worker.error) result
  | Observation_release_not_admitted of
      Worker.session * Worker.request_id * Worker.admission_error
  | Observation_notice of Worker.observation_notice
  | Observation_notices_failed of Worker.binding * Worker.error
  | Observation_received : 'a Worker.observed -> event
  | Asset_received of Worker.asset_notice
  | Cancel : 'a ticket -> event
  | Forget : 'a ticket -> event
  | Release : 'a Worker.observation -> event
  | Handoff_completed of Worker.handoff_id * Worker.handoff_state
  | Drain

type instruction =
  | Bootstrap
  | Release_binding of Worker.binding
  | Release_observation_registration of Worker.session * Worker.request_id
  | Bind_replacement
  | Send : 'a ticket * Worker.session * 'a Worker.request -> instruction
  | Cancel_request : 'a ticket -> instruction
  | Quiesce of Worker.handoff_id * Worker.host_change
  | Publish of view
  | Schedule_drain

type transition =
  { next : t
  ; instructions : instruction list
  }

(** Host supplies a fresh client identity for pure counters; durable mutation IDs
    are independent. Worker_bound enters Awaiting_baseline and schedules Bootstrap.
    Retry never reuses a revoked registration. A checked live Binding_invalidated
    fact retires old authority and awaits real unregister ACK before replacement;
    a replacement bootstrap rejecting this user remains visible, without an
    automatic retry loop. Ready/Projection is applied as one
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
  :  t
  -> Worker.session
  -> 'a Worker.request
  -> ('a ticket * transition, Worker.error) result

(** Start application of an actually delivered batch. An active successful
    attempt cannot be replaced by a duplicate pull; an explicit retry after a
    failure gets a new token. The root itself is applied only after its UI state. *)
val begin_change_application
  :  t
  -> Worker.change_batch
  -> root:Worker.Uuid.t
  -> (change_application * transition, Worker.error) result

(** Queue a business read against its exact host execution identity while the
    first registered baseline is pending. This does not construct a session:
    only a matching Open resident from that baseline may issue Send. Account or
    graph-generation replacement fails the ticket; cancellation before Send
    settles locally. The supplied byte/item ceilings are reduced to verified
    capability limits before making the sealed budget. *)
val plan_query
  :  t
  -> owner:Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope
  -> maximum_items:int
  -> maximum_bytes:int
  -> 'a Worker.query
  -> ('a ticket * transition, Worker.error) result

(** A logical dependency read retains its ticket on pre-admission Full and only
    retries after external Capacity_available. Cancellation/revocation still
    retires the request; other refusals remain visible. *)
val plan_query_when_available
  :  t
  -> owner:Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope
  -> maximum_items:int
  -> maximum_bytes:int
  -> 'a Worker.query
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
  :  t
  -> Worker.host_change
  -> (Worker.handoff_id * transition, Worker.error) result

(** Pure compressed ownership history for real mailbox-ID association. *)
module Response_ownership : sig
  type t

  val empty : t
  val add : t -> Logseq_db_worker_lui.Journal_worker_ids.Worker.request_id -> t
  val mem : t -> Logseq_db_worker_lui.Journal_worker_ids.Worker.request_id -> bool
  val spans : t -> int
end
