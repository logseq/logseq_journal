module Config = Config
module Error = Error
module Protocol = Protocol
module Engine = Engine
module Synced_mirror = Synced_mirror

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
  ; error : string option
  }

module Graph_lifecycle = struct
  type t = { mutable state : graph_state }

  let create () =
    { state = { generation = -1; graph_id = None; phase = Graph_closed; error = None } }
  ;;

  let state t = t.state

  let begin_open t ~generation ~graph_id =
    if generation >= t.state.generation
    then t.state <- { generation; graph_id; phase = Graph_opening; error = None }
  ;;

  let opened t ~generation =
    if generation = t.state.generation && t.state.phase = Graph_opening
    then t.state <- { t.state with phase = Graph_open; error = None }
  ;;

  let failed t ~generation ~message =
    if generation = t.state.generation
    then t.state <- { t.state with phase = Graph_failed; error = Some message }
  ;;

  let begin_close t ~generation =
    if generation = t.state.generation
    then t.state <- { t.state with phase = Graph_closing; error = None }
  ;;

  let closed t ~generation =
    if generation = t.state.generation
    then t.state <- { t.state with graph_id = None; phase = Graph_closed; error = None }
  ;;
end
