module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Worker = Journal_worker_coordination.Worker_api

type purpose =
  | Captured of { block_id : string }
  | Updated of { block_id : string }
  | Update_conflict_refresh of { block_id : string }
  | Delete_conflict_refresh of { block_id : string }

type read

type confirmation =
  { purpose : purpose
  ; block_id : string
  ; value : Protocol.v2_block_record
  ; revision : string
  ; page : Graph.page
  ; page_revision : string
  ; scope_revision : string
  ; children : Protocol.v2_child_member Rrbvec.t
  }

type planning = (Protocol.request, string) result

type step =
  | Continue of planning
  | Confirmed of confirmation
  | Absent of {purpose:purpose; block_id:string}
  | Failed of string

type ports =
  { now : unit -> int64
  ; plan_read : source_epoch:int64 -> read -> Protocol.command -> Protocol.request
  }

type t

val create : unit -> t
val reset : t -> unit
val current : t -> read -> bool
val start : t -> ports:ports -> purpose -> planning
val retry_stale : t -> ports:ports -> read -> planning option

val receive_summary
  :  t
  -> ports:ports
  -> read
  -> lookup:Protocol.v2_block_lookup
  -> page:Protocol.v2_page_lookup option
  -> items:Protocol.v2_child_member list
  -> next_cursor:Protocol.v2_child_member Worker.continuation option
  -> scope_revision:string
  -> generation:string
  -> projection_revision:string
  -> step

val reference_fragment
  :  read
  -> target:Protocol.v2_block_record
  -> final_children:Protocol.v2_child_member list
  -> Protocol.v2_block_record Rrbvec.t

val worker_query : read -> Worker.block_summary Worker.query

(** Pure business ordering for one child insertion and its status sub-operations.
    The Worker coordinator remains the authority for admission and receipts. *)
module Pure_child : sig
  type stage
  type t
  type action =
    | Write of int * int64 * Protocol.command
    | Read_child of int64
    | Read_parent of int64 * Worker.block_summary
    | Present of int64
    | Acknowledge of int * int64 * Worker.mutation_intent * Worker.presentation
    | Complete
    | Ignore
    | Wait of string
  val start : command:Journal_graph_projection.create_child -> page:Graph.page
    -> resolved_status:Graph.Uuid.t option -> insert:Protocol.command -> (t * action,string) result
  val command : t -> Journal_graph_projection.create_child
  val page : t -> Graph.page
  val failure : t -> Worker.error option
  val resolved_status : t -> Graph.Uuid.t option
  val canonical : t -> Worker.block_summary option
  val presentation : t -> Worker.presentation option
  val stage : t -> int -> stage
  val stage_id : stage -> Graph.Uuid.t
  val stage_wire : stage -> Protocol.command
  val stage_mutation : stage -> Worker.mutation_command
  val interrupted : t -> index:int -> round:int64 -> string -> t * action
  val read_failed : t -> round:int64 -> string -> t * action
  val insert_rejected : t -> bool
  val status_mutation_id : domain:string -> mutation_id:string -> revision:int64
    -> block:Graph.Uuid.t -> Graph.Uuid.t option -> Graph.Uuid.t
  val retarget : t -> command:Journal_graph_projection.create_child
    -> resolved_status:Graph.Uuid.t option -> (t,string) result
  val bind : t -> index:int -> round:int64 -> intent:Worker.mutation_intent
    -> presentation:Worker.presentation -> t option
  val receive : t -> index:int -> round:int64 -> Worker.mutation_progress -> t * action
  val read_child : t -> round:int64 -> Worker.block_summary -> t * action
  val projection_ready : t -> round:int64 -> t * action
  val retry : t -> t * action
  val applied : t -> round:int64 -> Worker.presentation -> t * action
  val acknowledged : t -> index:int -> round:int64 -> (unit,string) result -> t * action
  val rebind_ack : t -> index:int -> round:int64 -> intent:Worker.mutation_intent
    -> presentation:Worker.presentation -> t option
end
