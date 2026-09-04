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
