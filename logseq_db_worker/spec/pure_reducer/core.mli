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
  | Diagnostic of string

type upload_recovery_ticket = private
  { scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; after : Logseq_db_types.Graph_types.Uuid.t option
  ; limit : int
  ; serial : int
  }

type instruction =
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
  | Start
  | Graph_request of
      { id : request_id
      ; request : Logseq_db_worker_contract.Protocol.request
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
