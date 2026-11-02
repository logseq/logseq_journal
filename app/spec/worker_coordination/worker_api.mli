(** Target App/Worker coordination boundary. No production implementation satisfies
    it yet. DTOs reuse today's protocol; sealed authority is issued by the trusted
    Worker runner. Abstraction is not authentication: every message, continuation,
    receipt and resource is validated against its actual channel and owner. *)
module Graph = Logseq_db_types.Graph_types

module Uuid = Graph.Uuid
module Protocol = Logseq_db_worker.Protocol
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

type account_generation
type graph_generation
type presentation_generation
type worker_incarnation
type binding

val binding_incarnation : binding -> worker_incarnation
val equal_binding : binding -> binding -> bool

type session
type presentation

val account_generation : session -> account_generation
val graph_generation : session -> graph_generation
val presentation_generation : presentation -> presentation_generation
val presentation_session : presentation -> session
val graph_id : session -> Uuid.t
val equal_session : session -> session -> bool
val compare_session : session -> session -> int
val same_logical_graph : session -> session -> bool
val matches_scope : session -> Service.timeline_scope -> bool
val matches_asset_scope : session -> Service.asset_scope -> bool
val presentation_matches_scope : presentation -> Service.timeline_scope -> bool

val worker_incarnation
  :  runtime_epoch:Logseq_db_worker_lui.Journal_worker_ids.Runtime.epoch
  -> worker_generation:Logseq_db_worker_lui.Journal_worker_ids.Worker.generation
  -> worker_incarnation

(** Sessions survive focus changes while resident. Close/reopen, account changes,
    removal and rebinding revoke execution authority. Presentation has a separate
    lifetime. Admission and completion recheck all identities, not just UUID. *)
type error =
  | Revoked_session
  | Invalid_input of string
  | Response_budget_exceeded
  | Stale_read of string
  | Resync_required of string
  | Host_change_in_progress
  | Protocol_mismatch of string
  | Db_error of Logseq_db_worker.Error.t
  | Service_failed of string
  | Unsupported_operation of string

type request_id

val request_id : Uuid.t -> request_id
val equal_request_id : request_id -> request_id -> bool
val compare_request_id : request_id -> request_id -> int

type capabilities = private
  { limits : Protocol.v2_capability_limits
  ; atomic_append : bool
  ; durable_mutations : bool
  ; durable_import : bool
  ; observations : bool
  }

val capabilities : session -> capabilities

type read_budget

(** Validate positive item/encoded-byte bounds against this session's advertised
    limits. Every final enriched result, including summary/refs/properties, fits
    both bounds. An oversized singleton fails explicitly; no silent truncation.
    Requests also validate Protocol limits on IDs, roots, depth, payload and lists. *)
val read_budget
  :  session
  -> maximum_items:int
  -> maximum_bytes:int
  -> (read_budget, error) result

type journal_day

val journal_day : int -> (journal_day, error) result

type page
type block

val page_uuid : page -> Uuid.t
val page_title : page -> string
val block_uuid : block -> Uuid.t
val block_title : block -> string

(** Full storage-independent DTOs retain timestamps, parent/page/order, properties,
    source title, refs/tags, rendered titles and task status used by current App
    projections. Missing/recycled objects remain distinguishable in lookup queries.
    Values grant no execution authority. Revisions are scoped opaque protocol text,
    never parsed or compared lexically as counters. *)
val page_data : page -> Graph.page

val page_revision : page -> string
val block_data : block -> Protocol.v2_block_record
val block_revision : block -> string

type 'a continuation

type 'a slice = private
  { items : 'a list
  ; next : 'a continuation option
  }

(** At most Protocol.maximum_page_size items (<1000). A continuation is bound to
    session, query kind, parameters, budget and revision. Only its item type is a
    static guarantee; runtime rejects a different parent/range/depth/filter or
    stale snapshot. Ordinary reads do not change an observation epoch. *)

type graph_info = private
  { graph_uuid : Uuid.t
  ; graph_name : string
  ; schema : Graph.schema_version
  ; admission_facts : Graph.admission_fact list
  ; journal_title_format : string option
  ; limits : Protocol.v2_capability_limits
  ; generation : string
  ; projection_revision : string
  }

type block_summary = private
  { lookup : Protocol.v2_block_lookup
  ; page : Protocol.v2_page_lookup option
  ; items : Protocol.v2_child_member list
  ; next : Protocol.v2_child_member continuation option
  ; scope_revision : string
  ; generation : string
  ; projection_revision : string
  }

(** Canonical target, owning page and direct children share one DB snapshot,
    as in today's V2_get_outline_block_summary. Count is exact only at next=None.
    No sequential page/children calls may masquerade as this atomic summary. *)
type favorites = private
  { favorites_page : Uuid.t option
  ; generation : string
  ; projection_revision : string
  ; items : Protocol.v2_favorite_item list
  ; next : Protocol.v2_favorite_item continuation option
  }

type task_status_catalog = private
  { property_uuid : Uuid.t option
  ; default_status : Uuid.t option
  ; items : Graph.task_status_definition list
  ; next : Graph.task_status_definition continuation option
  }

type asset_listing = private
  { generation : string
  ; projection_revision : string
  ; items : Logseq_db_types.Asset_descriptor.t list
  ; next : Logseq_db_types.Asset_descriptor.t continuation option
  }

type children = private
  { parent : Uuid.t
  ; revision_scope : Protocol.v2_revision_scope
  ; scope_revision : string
  ; items : Protocol.v2_child_member list
  ; next : Protocol.v2_child_member continuation option
  }

type change_batch = private
  { change_owner : session
  ; generation : string
  ; from_exclusive : string option
  ; through : string
  ; windows : Protocol.v2_change_window list
  ; next : string option
  }

type change_ack

(** Typed forms of the existing App query families, not an untyped command escape
    hatch. Journal is a bounded single-day convenience; it preserves page revision
    and never creates a page. Children serves simple consumers; Child_members also
    exposes the exact scope revision required by current planners/confirmation.
    Typed results preserve present/missing and full metadata without UI layout
    types. List/lookup result ordering matches input IDs, including missing slots. *)
type _ query =
  | Graph_info : graph_info query
  | Admission : Protocol.v2_admission_inspection query
  | Journal : journal_day -> page option query
  | Journals :
      { from_day : journal_day
      ; through_day : journal_day
      ; revision : string option
      ; after : Protocol.v2_journal_item continuation option
      }
      -> Protocol.v2_journal_item slice query
  | Page :
      { uuid : Uuid.t
      ; revision : string option
      }
      -> Protocol.v2_page_lookup query
  | Outline_block :
      { uuid : Uuid.t
      ; revision : string option
      }
      -> Protocol.v2_block_lookup query
  | Block_summary :
      { block : Uuid.t
      ; after : Protocol.v2_child_member continuation option
      }
      -> block_summary query
  | Children :
      { parent : Uuid.t
      ; after : block continuation option
      }
      -> block slice query
  | Child_members :
      { parent : Uuid.t
      ; revision : string option
      ; after : Protocol.v2_child_member continuation option
      }
      -> children query
  | Tree :
      { page : Uuid.t
      ; maximum_depth : int
      ; revision : string option
      ; after : Protocol.v2_tree_member continuation option
      }
      -> Protocol.v2_tree_member slice query
  | Favorites : Protocol.v2_favorite_item continuation option -> favorites query
  | Task_statuses :
      Graph.task_status_definition continuation option
      -> task_status_catalog query
  | Task_status_definitions :
      Uuid.t list
      -> Graph.task_status_definition option list query
  | Asset_descriptors : Uuid.t list -> asset_listing query
  | Assets :
      { recursive : bool
      ; roots : Uuid.t list
      ; after : Logseq_db_types.Asset_descriptor.t continuation option
      }
      -> asset_listing query
  | Changes :
      { generation : string
      ; after : string option
      }
      -> change_batch query

val supports_observation : session -> 'a query -> bool

(** Derived from the verified baseline's per-query support. observations=true is
    not permission to Observe every query. Changes is explicitly unsupported for
    Observe before registration/handle allocation; Query Changes and its ACK keep
    their single owner. Other unsupported kinds fail before enqueue as well. *)

(** Legacy changefeed and target observations are alternative invalidation owners
    for a migrated interest. The host must not let both independently rehydrate or
    ACK it. A batch belongs to one session/generation/chain. ACK only after all
    affected consumer state is applied (or explicitly retired); a normal read
    failure cannot discard a window. Gaps/resync require a fresh baseline, not an
    invented acknowledgement. next retains the exact pull chain. *)
val change_batch_session : change_batch -> session

val change_ack_session : change_ack -> session
val change_ack_generation : change_ack -> string
val change_ack_through : change_ack -> string

type capture_node =
  { block_id : Uuid.t
  ; title : string
  ; task_status : Uuid.t option
  ; children : capture_node Rrbvec.t
  }

type append_intent

(** Persist the complete bounded root/child/status payload and normalized stable
    identity before first send. Retries reuse it; a changed choice creates a new
    intent even for A -> B -> A. Worker resolves an existing Web-created journal
    page by day; it must not assume the App's candidate UUID became the page. *)
val append_intent
  :  session
  -> mutation_id:Uuid.t
  -> block_id:Uuid.t
  -> day:journal_day
  -> title:string
  -> task_status:Uuid.t option
  -> children:capture_node Rrbvec.t
  -> (append_intent, error) result

val append_intent_id : append_intent -> Uuid.t
val encode_append_intent : append_intent -> bytes
val restore_append_intent : session -> bytes -> (append_intent, error) result

type mutation_command =
  | Save_block of
      { block : Uuid.t
      ; title : string
      ; preconditions : Protocol.v2_preconditions
      }
  | Insert_blocks of
      { parent : Uuid.t
      ; roots : Protocol.v2_block_tree list
      ; preconditions : Protocol.v2_preconditions
      }
  | Delete_blocks of
      { root : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }
  | Create_journal of
      { page : Uuid.t
      ; day : journal_day
      ; title : string
      ; preconditions : Protocol.v2_preconditions
      }
  | Set_task_status of
      { block : Uuid.t
      ; status : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }
  | Clear_task_status of
      { block : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }
  | Set_asset_reference of
      { block : Uuid.t
      ; previous : Uuid.t option
      ; asset : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }

type mutation_intent

val mutation_intent
  :  session
  -> mutation_id:Uuid.t
  -> mutation_command
  -> (mutation_intent, error) result

val mutation_intent_id : mutation_intent -> Uuid.t
val encode_mutation_intent : mutation_intent -> bytes
val restore_mutation_intent : session -> bytes -> (mutation_intent, error) result

(** General mutations preserve today's exact preconditions and mutation IDs.
    Restores validate logical origin/account/graph and all bytes, allowing fresh
    execution sessions only for the same logical graph. Same ID/different payload
    is a conflict. Suboperations of a logical action have stable distinct IDs and
    dependency order; a lost reply never creates a replacement status intent or
    replays a destructive operation under a fresh ID. The business reducer owns
    ordering/choice changes; this layer owns identity, admission and receipts. *)

type receipt
type confirmation

val receipt_intent : receipt -> mutation_intent
val receipt_mutation_id : receipt -> Uuid.t
val receipt_revisions : receipt -> string * string * string

type confirmed_target = private
  | Confirmed_block of block_summary
  | Confirmed_page of Protocol.v2_page_lookup
  | Confirmed_absence of
      { uuid : Uuid.t
      ; revision : string
      ; generation : string
      ; projection_revision : string
      }

val receipt_targets : receipt -> Uuid.t Rrbvec.t
val confirmation_primary : confirmation -> confirmed_target
val confirmation_additional : confirmation -> confirmed_target Rrbvec.t

(** At least one exact canonical target is exposed without another read. Additional
    readback fragments are bounded by the original operation and final response-
    byte budget; they need not include every target. receipt_targets is the complete
    canonical identity set; omitted readback is not absence and remains queryable.
    Block snapshots include owning page, status/refs, revisions and the first
    bounded child slice; their continuation retains the same snapshot contract. A caller needing
    further children paginates, rather than forcing full-page confirmation reads.
    Missing/deleted targets are explicit. These DTOs preserve the readback already
    performed by Confirm for current App projection consumers; a second query is
    not required just to render that same evidence. *)
val confirmation_receipt : confirmation -> receipt

val confirmation_presentation : confirmation -> presentation

type mutation_progress =
  | Rejected of error
  | Outcome_unknown
  | Committed_pending_presentation of receipt
  | Confirmed of confirmation

(** Rejected requires evidence that this intent did not apply. Confirmation uses
    exact intent/targets, commit revision and presentation session, not Timeline
    membership or text. Later changes may supersede the visible value; never mark
    an old intent confirmed solely because A -> B -> A looks equal. A remote sync
    rejection is a separate fact and cannot undo the locally committed outcome.
    Confirm runs bounded read-back, including atomic summary when required; read
    failure preserves the receipt and permits retry. It does not write again.
    Confirm explicitly binds the initiating presentation, checked at planning,
    admission and completion. Focus away/back creates a different presentation
    even if the execution session survives; its old in-flight confirmation cannot
    confirm the new view. An explicit new Confirm may use the new presentation. *)
type admission_error =
  | Full
  | Not_ready
  | Stopping
  | Unsupported_request of string

(** Recovery is read-only and returns complete immutable payloads. Its independent
    artifact byte ceiling accommodates a full legal intent and proof; ordinary
    query read_budget limits do not apply. Cursors bind session and both budgets. *)
type mutation_recovery_cursor
type recovered_mutation = private { intent : mutation_intent; progress : mutation_progress }
type mutation_recovery = private
  { items : recovered_mutation Rrbvec.t; next : mutation_recovery_cursor option }

val maximum_mutation_recovery_bytes : int

type interruption =
  | Cancelled
  | Transport_lost
  | Worker_stopped

type 'a reply =
  | Not_admitted of admission_error
  | Answered of ('a, error) result
  | Interrupted of interruption

(** Refusal before reservation applies to this attempt only. After acceptance,
    interruption/unvalidated error is not proof of rollback: retain the receipt or
    unknown state and reconcile the same durable intent. V2_failed without known
    non-commit evidence cannot become Rejected. Replay must be durable/idempotent
    across restart, not merely a process-local duplicate cache. *)

type changefeed_notice = private
  { notice_session : session
  ; notice : Protocol.push
  }

type observation_epoch

val compare_observation_epoch : observation_epoch -> observation_epoch -> int

type 'a observation
type (_, _) equality = Refl : ('a, 'a) equality

val observation_session : 'a observation -> session
val observation_id : 'a observation -> request_id
val observation_query : 'a observation -> 'a query
val observation_budget : 'a observation -> read_budget
val same_observation : 'a observation -> 'b observation -> ('a, 'b) equality option

(** Equality requires the exact owner/registration identity, not only compatible
    query result types. Refl permits typed existential storage without casts;
    runtime still checks registration, scope, query and epoch. *)
type 'a observed = private
  { observation : 'a observation
  ; epoch : observation_epoch
  ; value : 'a
  }

(** Observe registers and samples atomically, or registers replay from the sample's
    version with a proven gap-free boundary. Missing/empty data is observable.
    Refresh retains handle ownership; only invalidation/explicit refresh advances
    its epoch. Failed reads do not release it or supersede retained reconciliation.
    Release is idempotent but incomplete until ACK; it survives revocation solely
    for cleanup. Registration racing Release must either never allocate or return
    a tracked handle which is released before the ticket retires. Late updates
    match exact owner/epoch and cannot resurrect interest. *)

(** Authenticated invalidation facts carry the exact binding and logical owner.
    They do not grant ownership or create a session; Core matches an existing
    planned registration before deciding whether to refresh. *)
type observation_notice = private
  | Observation_invalidated of
      { binding : binding
      ; owner : Service.timeline_scope
      ; id : request_id
      ; epoch : observation_epoch
      }
  | Observations_resync of binding

type asset_consumer
type asset_file
type file_lease
type upload_operation
type imported

val asset_consumer : session -> name:string -> (asset_consumer, error) result
val asset_consumer_session : asset_consumer -> session
val equal_asset_consumer : asset_consumer -> asset_consumer -> bool
val compare_asset_consumer : asset_consumer -> asset_consumer -> int

(** Coordinator-owned replacement round, separate from logical consumer identity.
    Requests and Ready facts must match this exact round; a later descriptor
    replacement never adopts the old consumer's queued file capability. *)
val bind_asset_consumer : asset_consumer -> round:request_id -> asset_consumer
val asset_consumer_round : asset_consumer -> request_id option
val file_lease_session : file_lease -> session
val file_lease_id : file_lease -> request_id
val imported_session : imported -> session
val file_path : file_lease -> string
val file_type : file_lease -> string
val import_data : imported -> Logseq_db_worker.import_receipt
val import_preview : imported -> file_lease option
val without_import_preview : imported -> imported

(** Checked durable source adoption, bound to the complete logical intent bytes.
    It grants no lease, data-session or destructive authority. It may retire an
    old host's identical Unknown picker-source obligation after reconciliation. *)
type import_source_proof
val import_source_proof : imported -> import_source_proof
val import_source_proof_id : import_source_proof -> Uuid.t

type asset_import_intent

val asset_import_intent
  :  session
  -> Logseq_db_types.Asset_import.t
  -> (asset_import_intent, error) result

val asset_import_intent_id : asset_import_intent -> Uuid.t
val encode_asset_import_intent : asset_import_intent -> bytes
val import_source_proof_matches : asset_import_intent -> import_source_proof -> bool
val restore_asset_import_intent : session -> bytes -> (asset_import_intent, error) result

(** Stable import/metadata/local mutation IDs, exact target, descriptor and source
    are preserved. A lost import reply is not absence. Before retry after restart,
    backend must reconcile the same operation and source ownership; a missing
    source fails explicitly. It must not import a duplicate asset or patch a new
    target. Imported preview handles are adopted as owned leases, never leaked. *)
type import_progress =
  | Import_rejected of error
  | Import_unknown
  | Imported of imported

type asset_priority =
  | Foreground
  | Background

type asset_notice

val asset_notice_session : asset_notice -> session
val asset_notice_data : asset_notice -> Service.asset_notice
val asset_notice_consumer : asset_notice -> asset_consumer option

(** Availability/demand-accepted/backpressure notices identify the exact registered
    consumer, not an App-reconstructed namespaced string. Capacity and Upload_status
    are session-level facts (None); they have a separate session read outlet in
    Core. Unknown consumer/operation names are rejected, never broadcast to every
    consumer as a guessed association. *)
val ready_asset_file : asset_notice -> asset_file option

(** Pure identity facts for matching a Ready capability to its still-registered
    demand. These do not expose its physical handle or grant acquire authority. *)
val asset_file_consumer : asset_file -> asset_consumer
val asset_file_asset : asset_file -> Uuid.t

val upload_operation : asset_notice -> upload_operation option

(** File capabilities/consumer names are namespaced to this binding/session and
    issued only from checked notices/imports. Raw path/handle strings are not
    authority. Acquire creates one tracked lease; duplicate/late acquire replies
    must release orphan retains even after their UI consumer retires. Notices are
    bounded latest facts per consumer/operation and arrival ordered where needed,
    not an unbounded event log. A command ACK is not download/upload completion. *)

(** Worker must reclaim orphan retains even when Mailbox cancellation/Shutdown
    replaces an underlying successful resource result and App never receives the
    handle. App-only late-reply cleanup cannot prove this; backend acquisition/
    import ledger or atomic rollback must settle every Accepted operation. *)
type _ request =
  | Query : read_budget * 'a query -> 'a request
  | Observe : read_budget * 'a query -> 'a observed request
  | Refresh : 'a observation -> 'a observed request
  | Release : 'a observation -> unit request
  | Append : append_intent -> mutation_progress request
  | Mutate : mutation_intent -> mutation_progress request
  | Confirm : presentation * receipt -> mutation_progress request
  | Recover_mutations :
      { after : mutation_recovery_cursor option; maximum_items : int; maximum_bytes : int }
      -> mutation_recovery request
  | Acknowledge_intent : mutation_intent -> unit request
  | Acknowledge_changes : change_batch -> change_ack request
  | Import : asset_import_intent -> import_progress request
  | Replace_asset_demand :
      asset_consumer * asset_priority * Logseq_db_types.Asset_descriptor.t list
      -> unit request
  | Release_asset_demand : asset_consumer -> unit request
  | Retry_asset : Uuid.t -> unit request
  | Retry_upload : upload_operation -> unit request
  | Acquire_asset_file : asset_file -> file_lease option request
  | Acquire_imported_file : imported -> file_lease option request
  | Release_file : file_lease -> unit request

(* Pure request shape, ownership and budget validation. *)

(** No implicit-current fallback. Every request checks live session plus all
    nested resource/intent/continuation owners. Cleanup of a previously tracked
    retired observation/consumer/lease is the only exception to live admission.
    Atomic Append does not fetch all children: it resolves/creates page and inserts
    the complete payload/statuses under Worker transaction/outbox coordination.
    Today's separate operations do not implement it. Unsupported capabilities
    fail before enqueue, without a fabricated receipt/registration/lease ACK. *)
val validate_request : session -> 'a request -> (unit, error) result

type observation_update = Update : 'a observed -> observation_update
type projection_version

val compare_projection_version : projection_version -> projection_version -> int

type resident_phase =
  | Opening
  | Open
  | Closing
  | Failed of error

type network_phase =
  | Offline
  | Connecting
  | Current
  | Network_failed of error

type resident = private
  { session : session
  ; phase : resident_phase
  ; network : network_phase
  }

type removal_mode =
  | Ordinary
  | Force

type removal_stage =
  | Closing_graph
  | Deleting_local
  | Clearing_selection

type local_deletion = private
  | Removing of Uuid.t * removal_mode * removal_stage
  | Removal_failed of Uuid.t * removal_mode * removal_stage * error

type projection

val projection_incarnation : projection -> worker_incarnation
val projection_binding : projection -> binding
val projection_version : projection -> projection_version
val residents : projection -> resident list
val selected : projection -> presentation option
val local_deletion : projection -> local_deletion option
val equal_projection : projection -> projection -> bool

(** Positive evidence from a newer account or same-graph execution generation.
    An unknown/future owner is not retired merely because its baseline push has
    not reached the serial coordinator yet. A previous snapshot can additionally
    prove retirement when this newer same-binding snapshot removed its execution
    identity. This grants no read authority. *)
val scope_is_superseded
  :  ?previous:projection
  -> projection
  -> Service.timeline_scope
  -> bool

val removal_target : local_deletion -> Uuid.t

(** One immutable version covers membership, phases, selection and deletion.
    At most three distinct residents; selection references a resident session.
    Version order is meaningful only within the exact binding. Older versions or
    other bindings cannot replace the current projection. Equality notices every
    observable transition, including local_deletion Some -> None, failure detail,
    and removal of the final graph with no readable DB or selected graph.
    Local availability, network progress and account state remain orthogonal. *)
type bootstrap_state =
  | Awaiting_baseline
  | Bootstrap_not_ready of string
  | Ready of projection
  | Bootstrap_failed of error
  | Binding_revoked of error

(** This is the real entry to sealed sessions: create/bind starts registration,
    then Ready delivers membership, exact phases, selection, per-session limits and
    capabilities from one Worker-owned version. No caller must supply a preissued
    session. Empty membership is Ready, distinct from not ready. No graph may be
    queried until its session is Open. Rebinding revokes the predecessor before
    its baseline is applied. Snapshot+subscription must atomically register/sample
    or replay without loss from the sample version; independent coalesced
    Service.state/Graph_states/Graph_info reads are not a valid baseline.
    Changes during registration and last-graph removal must be observable.
    Failure/retry are explicit; restarting registration must retire its old one. *)

(** Host retains account/auth/token/catalog/startup/unlock, resident configuration,
    focus/select, ordinary/Force deletion policy, confirmation and shared pump/client.
    This layer does not copy every Service.client_command or become UI business
    state. The host must perform a handoff before retiring a graph/account/client;
    focus alone revokes presentation, not resident execution. The authoritative
    projection, not optimistic UI flags, admits the next session. *)
type host_change =
  | Account_will_change
  | Graph_will_close of Uuid.t
  | Graph_will_remove of Uuid.t * removal_mode
  | Connection_will_stop

type cleanup_resource =
  | Observation
  | Asset_demand
  | File_lease
  | Pending_request
  | Durable_intent

type handoff_id

val handoff_id : Uuid.t -> handoff_id
val equal_handoff_id : handoff_id -> handoff_id -> bool

type handoff_plan

(** Deterministic snapshot of the exact authoritative frame. The effect runner
    forwards it without choosing another account/version from a later callback. *)
val host_change_plan : projection -> handoff_id:handoff_id -> change:host_change
  -> sessions:session Rrbvec.t -> (handoff_plan,error)result
val handoff_plan_id : handoff_plan -> handoff_id
val handoff_plan_change : handoff_plan -> host_change
val handoff_plan_binding : handoff_plan -> binding
val handoff_plan_sessions : handoff_plan -> session Rrbvec.t

type handoff_receipt
val valid_handoff_receipt : handoff_plan -> handoff_receipt -> bool
val valid_handoff_projection : handoff_plan -> projection -> bool

val handoff_receipt_id : handoff_receipt -> handoff_id
val handoff_binding : handoff_receipt -> binding
val handoff_sessions : handoff_receipt -> session Rrbvec.t
val handoff_change : handoff_receipt -> host_change
val handoff_pending : handoff_receipt -> cleanup_resource list

type handoff_state =
  | Quiescing of host_change
  | Safe_to_proceed of handoff_receipt
  | Applying_host_change of handoff_receipt
  | Host_change_applied of handoff_receipt
  | Handoff_failed of host_change * error

(** Prepare immediately fences new admission for affected owners and retires their
    presentation. Safe_to_proceed is Worker acknowledgement that target writers and
    callbacks are quiescent/fenced and retained resources have accountable owners;
    Mailbox.cancel/queue empty alone is insufficient. Host joins all OTHER legacy
    owners too before Close/Delete/stop. Ordinary cleanup waits for releases;
    Force may transfer isolated pending cleanup to the existing deletion owner,
    exposing pending resources and actual partial cleanup, never claiming complete
    erasure. Durable unknown/committed intents remain recoverable; only separately
    confirmed destructive removal may discard them. No receipt authorizes a remote
    deletion or bypasses target/catalog/account/path/generation checks. Cancel of a
    deletion confirmation must happen before Prepare and change no data. Handoff
    failure is retryable; no stale callback may re-enable the retired owner.
    Receipts bind exact handoff ID, binding, affected execution generations and
    removal's local-copy incarnation even when no DB can open. Before the host
    acts, the pure coordinator plans one consume against the current receipt;
    the runner forwards its exact attempt to the existing Service owner. Mailbox
    admission is not an action ACK. Only Host_change_applied acknowledges actual
    consumption/action; old safe receipts cannot authorize a reopened graph or
    replacement account. Close was already physically settled during prepare,
    and removal uses the bound existing deletion owner. Do not dispatch a second
    legacy Close/Delete after that ACK. Auth/UI/client lifecycle stay with host. *)

(** Connection-bound validation used inside the direct effect runner. Methods below
    map concrete Service messages, not fictional bytes or a separate adapter. The
    factory is trusted integration, not proof of an honest backend. *)
module type ISSUER = sig
  val binding : binding

  (** Fresh issuer/registration lifetime within the real mailbox incarnation.
      Rebinding the same client/account still yields a distinct binding; this is
      not a second invented Worker incarnation. Every delayed bootstrap failure,
      not-ready update and baseline is tagged with it, as are sealed sessions. *)

  val revoke : unit -> unit
  val release_binding_request : unit -> (Service.request, error) result
  val binding_released : Service.response -> (unit, error) result

  (** Revocation immediately removes data authority; the baseline subscription
      remains tracked until its exact unregister/fence ACK. Repeated cleanup is
      idempotent. Do not abandon an old registration on retry/rebind/shutdown. *)

  val handoff_request
    :  handoff_plan
    -> (Service.request, error) result

  val handoff_receipt
    :  handoff_plan
    -> Service.response
    -> (handoff_receipt, error) result

  (** Match the tracked host transition and actual writer/resource fence. This
      is not Client_command_completed interpreted as proof of quiescence. The
      actual Service frame binds backend lifetime, original version, captured
      resources and held local-copy preparation. No readback callback may choose
      another target or reconstruct an absent receipt. *)

  (** The actual Service owner registers and samples one lifecycle version.
      Baselines carry caller-known registration IDs, effective limits and exact
      resident/account identities. Ordinary query families map to Protocol V2;
      unsupported durability/resource capabilities fail before enqueue. *)
  val consume_handoff_request : handoff_receipt -> (Service.request,error)result
  val handoff_consumed : handoff_receipt -> Service.response -> (unit,error)result
  val bootstrap_request : unit -> (Service.request, error) result

  val bootstrap : Service.response -> (bootstrap_state, error) result

  (** Includes correlated ongoing baseline updates; rejects account/incarnation/
      version regressions, duplicate residents, invalid limits and selection.
      previous must be the latest accepted projection for this binding. Current
      unversioned Service.state/Graph_states alone cannot establish this obligation. *)
  val projection
    :  previous:projection option
    -> Service.push
    -> (projection, error) result

  val request
    :  session
    -> request_id:request_id
    -> 'a request
    -> (Service.request, error) result

  (** Pure coordinator supplies the captured current presentation and original
      proof. None denotes a known rejection, never Unknown. The runner only
      encodes this decision; it does not infer acknowledgement from UI callbacks. *)
  val acknowledge_mutation_request
    : session -> request_id:request_id -> presentation:presentation
    -> intent:mutation_intent -> original:receipt option -> (Service.request,error) result

  val reply
    :  session
    -> request_id:request_id
    -> 'a request
    -> Service.response
    -> ('a reply, error) result

  val observation
    :  session
    -> request_id:request_id
    -> 'a observation
    -> Service.response
    -> ('a observed, error) result

  (** Checked registration metadata is separate from sampled data: a V2_failed
      still owns an observation. Metadata accepts the exact retired binding for
      cleanup tracking; it grants no current read authority. *)
  val observation_registration
    :  session
    -> request_id:request_id
    -> 'a observed request
    -> Service.response
    -> ('a observation * observation_epoch, error) result

  val changefeed_notices : Service.push -> (changefeed_notice Rrbvec.t, error) result
  val observation_notices : Service.push -> (observation_notice Rrbvec.t, error) result

  (** Settle a caller-known pending logical registration even when cancellation
      hid its successful handle. Only the exact backend cleanup ACK is success;
      this is not a fabricated active observation. *)
  val release_observation_registration
    :  session
    -> observation_id:request_id
    -> (Service.request, error) result

  val observation_registration_released
    :  session
    -> observation_id:request_id
    -> Service.response
    -> (unit, error) result

  val receipt
    :  session
    -> request_id:request_id
    -> intent:append_intent
    -> Protocol.response
    -> (receipt, error) result

  val mutation_receipt
    :  session
    -> request_id:request_id
    -> intent:mutation_intent
    -> Protocol.response
    -> (receipt, error) result

  val confirmation
    :  session
    -> presentation:presentation
    -> receipt
    -> Protocol.response
    -> (confirmation, error) result

  val asset_notice : session -> Service.asset_notice -> (asset_notice, error) result
end

val issuer
  :  managed_origin:string
  -> user_id:string
  -> runtime_epoch:Logseq_db_worker_lui.Journal_worker_ids.Runtime.epoch
  -> worker_generation:Logseq_db_worker_lui.Journal_worker_ids.Worker.generation
  -> ((module ISSUER), error) result

(** Factory binds verified logical origin/account and real mailbox identities.
    The runner validates response kind, protocol and mailbox IDs, exact intent/
    graph/revision, continuation and handle, before issuing authority. Retired
    bindings accept tracked cleanup ACKs only, never new sessions/data operations.
    Protocol.V2_failed preserves its code/message but cannot reconstruct Error.t
    causal evidence it never transported. Existing Error.t values remain intact. *)
