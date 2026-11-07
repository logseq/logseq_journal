module Graph = Logseq_db_types.Graph_types
module Error = Logseq_db_worker.Error
module Worker = Journal_worker_coordination.Worker_api

type read
type rejection =
  | Projection_rejection of string
  | Worker_rejection of
      { operation : string; request_id : Graph.Uuid.t; error : Error.t }
type event =
  | Favorites_loaded of Journal_graph_request.favorites_request * Journal_worker_coordination.Worker_api.favorites
  | Favorites_failed of Journal_graph_request.favorites_request * bool * string
  | Favorites_invalidated
  | Diagnostic of { operation : string; request_id : Graph.Uuid.t; error : Error.t }
  | Rejected of rejection
type output =
  { requests : Graph.Uuid.t Rrbvec.t
  ; responses : event Rrbvec.t
  ; background : bool
  }
type ports =
  { plan_read : 'a. maximum_items:int -> read -> 'a Worker.query -> Graph.Uuid.t
  ; remember_page : Graph.page -> unit
  }
type t
val create : unit -> t
val reset : t -> unit
val current : t -> read -> bool
val is_page_target : t -> string -> bool
val operation_name : read -> string
val load : ports:ports -> Journal_graph_request.favorites_request -> Graph.Uuid.t
val changes : t -> ports:ports -> blocks:Graph.Uuid.t Rrbvec.t -> pages:Graph.Uuid.t Rrbvec.t
  -> structures:Worker_pure_data.structure_interest Rrbvec.t -> output
val accepts_list : read -> bool
val accepts_page : t -> read -> bool
val accepts_block : t -> read -> bool
val accepts_memberships : read -> bool
val receive_list : t -> ports:ports -> read -> Journal_worker_coordination.Worker_api.favorites -> output
val receive_page : t -> ports:ports -> read -> Worker_pure_data.page_lookup -> output
val receive_block : t -> ports:ports -> read -> Worker_pure_data.block_lookup -> output
val receive_memberships : t -> ports:ports -> read -> Worker_pure_data.child_member list -> Worker_pure_data.child_member Worker.continuation option -> output
val fail : t -> read -> request_id:Graph.Uuid.t -> code:Error.code -> message:string -> error:Error.t -> output
