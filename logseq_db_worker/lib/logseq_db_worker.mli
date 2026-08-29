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

module Graph_lifecycle : sig
  type t

  val create : unit -> t
  val state : t -> graph_state

  val begin_open
    :  t
    -> generation:int
    -> graph_id:Logseq_db_types.Graph_types.Uuid.t option
    -> unit

  val opened : t -> generation:int -> unit
  val failed : t -> generation:int -> message:string -> unit
  val begin_close : t -> generation:int -> unit
  val closed : t -> generation:int -> unit
end
