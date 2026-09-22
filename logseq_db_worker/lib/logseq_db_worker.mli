module Config = Logseq_db_worker_contract.Config
module Error = Logseq_db_worker_contract.Error
module Protocol = Logseq_db_worker_contract.Protocol
module Pure_reducer = Logseq_db_worker_pure_reducer.Core
module Effect_runner = Logseq_db_worker_effect_runner.Effect_runner

type graph_phase = Pure_reducer.graph_phase =
  | Graph_closed
  | Graph_opening
  | Graph_open
  | Graph_closing
  | Graph_failed

type graph_state = Pure_reducer.graph_state =
  { generation : int
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; phase : graph_phase
  ; error : Error.t option
  }

type t
type create_error = Invalid_create of string

val create
  :  sw:Eio.Switch.t
  -> config:Pure_reducer.config
  -> runner_dependencies:Effect_runner.dependencies
  -> (t, create_error) result

val post : t -> Pure_reducer.event -> unit
val view : t -> Pure_reducer.view
val graph_state : t -> graph_state
val request : t -> Protocol.request -> Protocol.response
val shutdown : t -> unit

val retain_asset_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> handle:string
  -> (string * string) option

val release_asset_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> handle:string
  -> unit

type import_receipt =
  { operation : Logseq_db_types.Graph_types.Uuid.t
  ; graph_generation : int
  ; scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; target : Logseq_db_types.Graph_types.Uuid.t
  ; asset : Logseq_db_types.Asset_descriptor.t
  ; file_type : string
  ; preview : (string * string) option
  }

val import_asset
  :  t
  -> graph_generation:int
  -> Logseq_db_types.Asset_import.t
  -> (import_receipt, string) result

val retain_imported_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> (string * string) option
