(** Pure Logseq DB worker orchestration policy. *)

type target_kind =
  | Managed
  | Snapshot
  | Import_snapshot
  | Synced_mirror
  | Native_local

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

type engine_handle
type engine_opened

val engine_opened
  :  engine_id:string
  -> graph_id:Logseq_db_types.Graph_types.Uuid.t option
  -> basis:int64 option
  -> engine_opened

val engine_handle_id : engine_handle -> string
val opened_engine_handle : engine_opened -> engine_handle
val opened_graph_id : engine_opened -> Logseq_db_types.Graph_types.Uuid.t option
val opened_basis : engine_opened -> int64 option

type effect_id
type ticket

val effect_id_to_string : effect_id -> string

type managed_mutation_prepared =
  { admission_id : string
  ; input : Logseq_sync_pure_reducer.Core.local_batch_input
  }

type managed_request_result =
  | Managed_immediate of Logseq_db_worker_contract.Protocol.response
  | Managed_prepared of managed_mutation_prepared

type lifecycle_result =
  | Lifecycle_unchanged
  | Lifecycle_opened of engine_opened * int
  | Lifecycle_closed of int
  | Lifecycle_failed of int * Logseq_db_worker_contract.Error.t

type sync_worker_result =
  { event : Logseq_sync_pure_reducer.Core.event option
  ; lifecycle : lifecycle_result
  ; mutation_success : Logseq_db_types.Mutation.success option
  }

type _ runner_request =
  | Open_engine : Logseq_db_worker_contract.Config.t -> engine_opened runner_request
  | Execute_request :
      { engine : engine_handle
      ; request : Logseq_db_worker_contract.Protocol.request
      }
      -> Logseq_db_worker_contract.Protocol.response runner_request
  | Close_engine : engine_handle -> unit runner_request
  | Prepare_managed_mutation :
      { engine : engine_handle
      ; scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; admission_id : string
      ; request : Logseq_db_worker_contract.Protocol.request
      }
      -> managed_request_result runner_request
  | Handle_sync_worker_effect :
      Logseq_sync_pure_reducer.Core.worker_effect
      -> sync_worker_result runner_request

type runner_effect = Request : ticket * 'a runner_request -> runner_effect
type effect_error = Logseq_db_worker_contract.Error.t

type runner_completion =
  | Open_engine_completed of ticket * (engine_opened, effect_error) result
  | Execute_request_completed of
      ticket * (Logseq_db_worker_contract.Protocol.response, effect_error) result
  | Close_engine_completed of ticket * (unit, effect_error) result
  | Prepare_managed_mutation_completed of
      ticket * (managed_request_result, effect_error) result
  | Sync_worker_effect_completed of ticket * (sync_worker_result, effect_error) result

type output =
  | Reply of request_id * Logseq_db_worker_contract.Protocol.response
  | Graph_push of Logseq_db_worker_contract.Protocol.push
  | Sync_output of Logseq_sync_pure_reducer.Core.output
  | Graph_state_changed of graph_state
  | Diagnostic of string

type instruction =
  | Run_worker of runner_effect
  | Run_sync of Logseq_sync_pure_reducer.Core.runner_effect
  | Publish of output

val instruction_diagnostic : instruction -> string
val equal_instruction : instruction -> instruction -> bool
val equal_instructions : instruction list -> instruction list -> bool

type config
type config_error = Invalid_config of string

val config
  :  worker:Logseq_db_worker_contract.Config.t
  -> sync:Logseq_sync_pure_reducer.Core.config option
  -> (config, config_error) result

type view =
  { target : target_kind
  ; graph : graph_state
  ; sync : Logseq_sync_pure_reducer.Core.state option
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
  | Start
  | Graph_request of
      { id : request_id
      ; request : Logseq_db_worker_contract.Protocol.request
      }
  | Sync_event of Logseq_sync_pure_reducer.Core.event
  | Set_foreground of bool
  | Runner_completed of runner_completion
  | Shutdown

val complete_open : runner_effect -> (engine_opened, effect_error) result -> event option

val complete_execute
  :  runner_effect
  -> (Logseq_db_worker_contract.Protocol.response, effect_error) result
  -> event option

type transition =
  { next : state
  ; effects : instruction list
  }

val step : state -> event -> transition
