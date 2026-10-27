module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Error = Logseq_db_worker.Error

type read
type rejection =
  | Projection_rejection of string
  | Worker_rejection of
      { operation : string; request_id : Graph.Uuid.t; error : Error.t }
type event =
  | Favorites_loaded of Journal_graph_request.favorites_request * Protocol.v2_favorites_result
  | Favorites_failed of Journal_graph_request.favorites_request * bool * string
  | Favorites_invalidated
  | Rejected of rejection
type output =
  { requests : Protocol.request Rrbvec.t
  ; responses : event Rrbvec.t
  ; background : bool
  }
type ports =
  { plan_read : read -> Protocol.command -> Protocol.request
  ; remember_page : Graph.page -> unit
  }
type t
val create : unit -> t
val reset : t -> unit
val current : t -> read -> bool
val is_page_target : t -> string -> bool
val operation_name : read -> string
val load : ports:ports -> Journal_graph_request.favorites_request -> Protocol.request
val changes : t -> ports:ports -> blocks:Graph.Uuid.t Rrbvec.t -> pages:Graph.Uuid.t Rrbvec.t
  -> structures:Protocol.v2_structure_interest Rrbvec.t -> output
val accepts_list : read -> bool
val accepts_page : t -> read -> bool
val accepts_block : t -> read -> bool
val accepts_memberships : read -> bool
val receive_list : t -> ports:ports -> read -> Protocol.v2_favorites_result -> output
val receive_page : t -> ports:ports -> read -> Protocol.v2_page_lookup -> output
val receive_block : t -> ports:ports -> read -> Protocol.v2_block_lookup -> output
val receive_memberships : t -> ports:ports -> read -> Protocol.v2_child_member list -> Graph.Cursor.t option -> output
val fail : t -> read -> request_id:Graph.Uuid.t -> code:Error.code -> message:string -> error:Error.t -> output
