(** Pure Logseq DB worker lifecycle and request-routing policy. *)

type graph_phase =
  | Graph_closed
  | Graph_opening
  | Graph_open
  | Graph_closing
  | Graph_failed

type graph_state =
  { generation : int
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; phase : graph_phase
  ; error : Logseq_db_worker_contract.Error.t option
  }

type request_id

val request_id_of_int64 : int64 -> request_id
val request_id_to_int64 : request_id -> int64
val equal_request_id : request_id -> request_id -> bool

type database_handle
type database_opened

val database_opened
  :  database_id:string
  -> graph_id:Logseq_db_types.Graph_types.Uuid.t
  -> database_opened

val database_handle_id : database_handle -> string
val opened_database_handle : database_opened -> database_handle
val opened_graph_id : database_opened -> Logseq_db_types.Graph_types.Uuid.t

type effect_id
type ticket

val effect_id_to_string : effect_id -> string

type lifecycle_result =
  | Lifecycle_unchanged
  | Lifecycle_opened of database_opened * int
  | Lifecycle_closed of int
  | Lifecycle_failed of int * Logseq_db_worker_contract.Error.t

type sync_worker_result =
  { event : Logseq_sync_pure_reducer.Core.event option
  ; lifecycle : lifecycle_result
  }

type _ runner_request =
  | Execute_request :
      { database : database_handle
      ; request : Logseq_db_worker_contract.Protocol.request
      ; response_budget_bytes : int option
      }
      -> Logseq_db_worker_contract.Protocol.response runner_request
  | Close_database : database_handle -> unit runner_request
  | Handle_sync_worker_effect :
      Logseq_sync_pure_reducer.Core.worker_effect
      -> sync_worker_result runner_request

type runner_effect = Request : ticket * 'a runner_request -> runner_effect
type effect_error = Logseq_db_worker_contract.Error.t

type runner_completion =
  | Execute_request_completed of
      ticket * (Logseq_db_worker_contract.Protocol.response, effect_error) result
  | Close_database_completed of ticket * (unit, effect_error) result
  | Sync_worker_effect_completed of ticket * (sync_worker_result, effect_error) result

type asset_notice =
  | Asset_availability of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; availability : Logseq_sync_pure_reducer.Asset_transfer.availability
      }
  | Asset_demand_accepted of string
  | Asset_backpressure of string
  | Asset_capacity_available
  | Upload_status of
      { operation : Logseq_db_types.Graph_types.Uuid.t
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; target : Logseq_db_types.Graph_types.Uuid.t
      ; title : string
      ; status : Asset_upload.status
      }

type output =
  | Asset_notice of Logseq_sync_pure_reducer.Core.graph_scope * asset_notice
  | Reply of request_id * Logseq_db_worker_contract.Protocol.response
  | Graph_push of Logseq_db_worker_contract.Protocol.push
  | Sync_output of Logseq_sync_pure_reducer.Core.output
  | Graph_state_changed of graph_state
  | Scoped_graph_state_changed of Logseq_sync_pure_reducer.Core.graph_scope * graph_state
  | Scoped_graph_push of Logseq_sync_pure_reducer.Core.graph_scope * Logseq_db_worker_contract.Protocol.push
  | Diagnostic of string

type upload_recovery_ticket = private
  { scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; after : Logseq_db_types.Graph_types.Uuid.t option
  ; limit : int
  ; serial : int
  }

type instruction =
  | Sync_io_fence_reached of int64 * Logseq_sync_pure_reducer.Core.effect_scope * (unit,string) result
  | Asset_cleanup_barrier_reached of int64
  | Deliver_protected_result of Logseq_sync_pure_reducer.Core.protected_output
  | Deliver_asset_result of Logseq_sync_pure_reducer.Core.asset_output
  | Read_uploads of upload_recovery_ticket
  | Run_upload of Logseq_sync_pure_reducer.Core.asset_context * Asset_upload.instruction
  | Run_asset of
      Logseq_sync_pure_reducer.Core.asset_context
      * Logseq_sync_pure_reducer.Asset_transfer.instruction
  | Close_asset_scope of Logseq_sync_pure_reducer.Core.graph_scope
  | Run_worker of runner_effect
  | Run_sync of Logseq_sync_pure_reducer.Core.runner_effect
  | Publish of output

val instruction_diagnostic : instruction -> string
val equal_instruction : instruction -> instruction -> bool
val equal_instructions : instruction list -> instruction list -> bool

type config

val config
  :  worker:Logseq_db_worker_contract.Config.t
  -> sync:Logseq_sync_pure_reducer.Core.config
  -> config

type view =
  { graph : graph_state
  ; sync : Logseq_sync_pure_reducer.Core.state
  ; pending_requests : int
  ; pending_effects : int
  ; shutdown : bool
  }

val equal_view : view -> view -> bool

type state
type create_error = Invalid_create of string

val initial : config -> (state, create_error) result
val view : state -> view

type event =
  | Asset_cleanup_barrier of int64
  | Upload_requested of
      { graph_generation : int
      ; operation : Logseq_db_types.Graph_types.Uuid.t
      ; event : Asset_upload.event
      }
  | Uploads_loaded of
      upload_recovery_ticket * (Logseq_db_types.Asset_upload_intent.t list, string) result
  | Upload_completed of Asset_upload.ticket * Asset_upload.completion
  | Asset_requested of
      { graph_generation : int
      ; event : Logseq_sync_pure_reducer.Asset_transfer.event
      }
  | Asset_completed of
      Logseq_sync_pure_reducer.Core.graph_scope
      * Logseq_sync_pure_reducer.Asset_transfer.event
  | Graph_request_for_scope of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; id : request_id
      ; request : Logseq_db_worker_contract.Protocol.request
      ; response_budget_bytes : int option
      }
  | Projection_push_for_scope of Logseq_sync_pure_reducer.Core.graph_scope * Logseq_db_worker_contract.Protocol.push
  | Asset_requested_for_scope of Logseq_sync_pure_reducer.Core.graph_scope * Logseq_sync_pure_reducer.Asset_transfer.event
  | Upload_requested_for_scope of Logseq_sync_pure_reducer.Core.graph_scope * Logseq_db_types.Graph_types.Uuid.t * Asset_upload.event
  | Start
  | Graph_request of
      { id : request_id
      ; request : Logseq_db_worker_contract.Protocol.request
      ; response_budget_bytes : int option
      }
  | Sync_event of Logseq_sync_pure_reducer.Core.event
  | Projection_push of Logseq_db_worker_contract.Protocol.push
  | Set_foreground of bool
  | Runner_completed of runner_completion
  | Shutdown

type transition =
  { next : state
  ; effects : instruction list
  }

val step : state -> event -> transition

val complete_execute
  :  runner_effect
  -> (Logseq_db_worker_contract.Protocol.response, effect_error) result
  -> event option

val asset_ticket_current : state -> Logseq_sync_pure_reducer.Asset_transfer.ticket -> bool
val asset_scope_current : state -> Logseq_sync_pure_reducer.Core.graph_scope -> bool
val upload_ticket_current : state -> Asset_upload.ticket -> bool
val upload_recovery_current : state -> upload_recovery_ticket -> bool

val import_context
  :  state
  -> graph_generation:int
  -> Logseq_sync_pure_reducer.Core.asset_context option

val graph_scopes : state -> Logseq_sync_pure_reducer.Core.graph_scope list

val graph_state_for_scope : state -> Logseq_sync_pure_reducer.Core.graph_scope -> graph_state option

type coordination_state =
  { sync : Logseq_sync_pure_reducer.Core.coordination_state
  ; residents : (Logseq_sync_pure_reducer.Core.graph_scope * graph_state) list
  }
val coordination_state : state -> coordination_state
val import_context_for_scope : state -> Logseq_sync_pure_reducer.Core.graph_scope -> Logseq_sync_pure_reducer.Core.asset_context option

(** Pure admission/epoch/tombstone ownership for real query subscriptions.
    Physical listeners and snapshot leases remain with the effect owner. A
    released logical ID cannot allocate later if Cancel overtook registration.
    This registry never infers a physical release ACK. *)
module Observation_registry : sig
  type t

  type decision =
    | Start
    | Existing
    | Retired
    | Full
    | Mismatch
    | Invalid

  type release =
    | Release
    | Already_released
    | Unknown
    | Release_full
    | Wrong_owner

  val empty : t

  val reserve
    :  t
    -> registration:int64
    -> id:Logseq_db_types.Graph_types.Uuid.t
    -> scope:Logseq_sync_pure_reducer.Core.graph_scope
    -> command:Logseq_db_worker_contract.Protocol.command
    -> maximum_bytes:int
    -> t * decision

  val release
    :  t
    -> registration:int64
    -> id:Logseq_db_types.Graph_types.Uuid.t
    -> scope:Logseq_sync_pure_reducer.Core.graph_scope
    -> t * release

  (** Fence an unallocated logical ID even after its graph owner has disappeared.
      This cannot release a known live/closing resource or grant a graph fence. *)
  val release_unallocated
    : t -> registration:int64 -> id:Logseq_db_types.Graph_types.Uuid.t
    -> owner:Logseq_sync_pure_reducer.Core.timeline_scope -> t * release

  (** External completion after physical listener/read cleanup; only then is
      its active-resource capacity reusable. *)
  val released
    :  t
    -> registration:int64
    -> id:Logseq_db_types.Graph_types.Uuid.t
    -> scope:Logseq_sync_pure_reducer.Core.graph_scope
    -> t

  val advance
    :  t
    -> registration:int64
    -> id:Logseq_db_types.Graph_types.Uuid.t
    -> t * int64 option

  val current
    :  t
    -> registration:int64
    -> id:Logseq_db_types.Graph_types.Uuid.t
    -> epoch:int64
    -> bool

  val scope
    :  t
    -> registration:int64
    -> id:Logseq_db_types.Graph_types.Uuid.t
    -> Logseq_sync_pure_reducer.Core.graph_scope option

  val epoch
    :  t
    -> registration:int64
    -> id:Logseq_db_types.Graph_types.Uuid.t
    -> int64 option

  val active : t -> int
  val retained : t -> int

  (** Only after all physical listeners/read leases of this binding settled. *)
  val retire_registration : t -> registration:int64 -> t
end

(** One changefeed consumer for one physical DB session. Legacy ownership can be
    transferred once; registered replacements require actual prior retirement.
    An unapplied pull is retained verbatim until its exact ACK succeeds. *)
module Changefeed_owner : sig
  type t

  type pull =
    | Read
    | Cached of Logseq_db_worker_contract.Protocol.response
    | Refused

  val empty : t
  val legacy : t -> bool
  val needs_resync : t -> bool
  val claim : t -> registration:int64 -> t * bool

  val pull
    :  t
    -> registration:int64
    -> request:Logseq_db_worker_contract.Protocol.request
    -> maximum_bytes:int
    -> pull

  val remember
    :  t
    -> registration:int64
    -> request:Logseq_db_worker_contract.Protocol.request
    -> maximum_bytes:int
    -> Logseq_db_worker_contract.Protocol.response
    -> (t, string) result

  val may_ack : t -> registration:int64 -> generation:string -> through:string -> bool

  val acknowledged
    :  t
    -> registration:int64
    -> request:Logseq_db_worker_contract.Protocol.request
    -> Logseq_db_worker_contract.Protocol.response
    -> t

  (** Physical history has at most 256 windows and one maximum response's
      conservative encoded-byte budget. False requires the I/O owner to discard
      that history and publish resync; it does not acknowledge any consumer. *)
  val retain_window : t -> encoded_bytes:int -> t * bool

  val release_windows : t -> count:int -> encoded_bytes:int -> t
  val invalidate : t -> t
  val retire : t -> registration:int64 -> t
end


(** Cleanup ownership transferred by the real Mailbox's exactly-once discarded
    success callback. Any unsettled physical release blocks new acquisition;
    failure retains that obligation. Attempt tokens prevent an old ACK from settling a retry. No
    clock, callback, transport or filesystem access occurs here. *)
module Orphan_cleanup : sig
  type resource = { scope : Logseq_sync_pure_reducer.Core.graph_scope; handle : string }
  type t
  type work
  val empty : t
  val count : t -> int
  val acquisition_open : t -> bool
  val track : t -> resource -> t
  val next : t -> t * work option
  val resource : work -> resource
  val first_attempt : work -> bool
  val retry_delay : work -> float
  val completed : t -> work -> (unit,string) result -> t
end

(** Admission/tombstones for typed demand rounds on the existing Service. A
    retired round cannot allocate later, even when release overtook Replace.
    Physical settlement remains separate from command admission. *)
module Demand_registry : sig
  type t
  type owner={registration:int64;scope:Logseq_sync_pure_reducer.Core.graph_scope;consumer:string}
  type reservation=Start|Existing|Retired|Mismatch|Full|Invalid
  type release=Release|Already_settled|Unknown|Mismatch|Full
  val empty:t
  val reserve:t -> owner -> priority:Logseq_sync_pure_reducer.Asset_transfer.priority
    -> assets:Logseq_db_types.Asset_descriptor.t list -> t * reservation
  val admitted:t -> owner -> bool
  val retire:t -> owner -> t * release
  val settled:t -> owner -> t
  val pending:t -> registration:int64 -> owner Rrbvec.t

  (** Permanently fences this and older registrations before pruning completed
      tombstones. Unsettled resource owners remain pending. *)
  val forget_settled:t -> registration:int64 -> t
end

(** Pure admission and completion ledger for physical graph operations. A fence
    blocks that graph incarnation across focus/foreground changes. Finishing an
    operation is an interpreter input after its actual I/O and callback posting.
    Drained is only a writer fact: it grants no resource, deletion or host permit. *)
module Writer_fence : sig
  type t
  type operation
  type fence
  type error = Fenced | Full
  val empty : t
  val admit : t -> Logseq_sync_pure_reducer.Core.graph_scope -> t * (operation,error) result
  val finish : t -> operation -> t
  val freeze : t -> Logseq_sync_pure_reducer.Core.graph_scope -> t * (fence,error) result
  val drained : t -> fence -> bool
  val fenced : t -> Logseq_sync_pure_reducer.Core.graph_scope -> bool
  val pending : t -> Logseq_sync_pure_reducer.Core.graph_scope -> int
  val operation_id : operation -> int64
  val same_incarnation : Logseq_sync_pure_reducer.Core.graph_scope -> Logseq_sync_pure_reducer.Core.graph_scope -> bool
end
