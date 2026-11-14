(** {1 TLDR}

    Plan canonical mutation readback and own pure insertion/capture chains.
    The host executes the returned read/write actions. No I/O or persistent data
    is owned here; [Pure_insertion.bind] preserves Worker errors and installs no
    state when intent, presentation or round validation fails.

    {1 Minimal usage example}

    With a caller-owned chain, current stage/round, intent and presentation:
    {[
      match Pure_insertion.bind chain ~index ~round ~intent ~presentation with
      | Error error -> report_error error
      | Ok bound -> install_chain bound
    ]}
    [report_error] and [install_chain] are supplied by the host.

    {1 Capability details} *)

module Graph = Logseq_db_types.Graph_types
module Worker = Journal_worker_coordination.Worker_api

type purpose =
  | Updated of { block_id : string }
  | Update_conflict_refresh of { block_id : string }
  | Delete_conflict_refresh of { block_id : string }

type read

type confirmation =
  { purpose : purpose
  ; block_id : string
  ; value : Worker_pure_data.block_record
  ; revision : string
  ; page : Graph.page
  ; page_revision : string
  ; scope_revision : string
  ; children : Worker_pure_data.child_member Rrbvec.t
  }

type planning = (Graph.Uuid.t, string) result

type step =
  | Continue of planning
  | Confirmed of confirmation
  | Absent of {purpose:purpose; block_id:string}
  | Failed of string

type ports =
  { now : unit -> int64
  ; plan_read : source_epoch:int64 -> read -> Worker.block_summary Worker.query -> Graph.Uuid.t
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
  -> lookup:Worker_pure_data.block_lookup
  -> page:Worker_pure_data.page_lookup option
  -> items:Worker_pure_data.child_member list
  -> next_cursor:Worker_pure_data.child_member Worker.continuation option
  -> scope_revision:string
  -> generation:string
  -> projection_revision:string
  -> step

val reference_fragment
  :  read
  -> target:Worker_pure_data.block_record
  -> final_children:Worker_pure_data.child_member list
  -> Worker_pure_data.block_record Rrbvec.t

val worker_query : read -> Worker.block_summary Worker.query

(** Pure business ordering for one child insertion and its status sub-operations.
    The Worker coordinator remains the authority for admission and receipts. *)
module Pure_insertion : sig
  type stage
  type t
  type action =
    | Write of int * int64
    | Read_child of int64
    | Read_parent of int64 * Worker.block_summary
    | Present of int64
    | Acknowledge of int * int64 * Worker.durable_intent * Worker.presentation
    | Complete
    | Ignore
    | Wait of string
  val start : command:Journal_graph_projection.create_child -> page:Graph.page
    -> resolved_status:Graph.Uuid.t option -> insert:Worker.mutation_command -> (t * action,string) result
  val start_capture : command:Journal_graph_projection.capture -> resolved_status:Graph.Uuid.t option
    -> root:Worker_pure_data.append_node -> (t * action,string) result
  val capture_command : Journal_graph_projection.capture -> Journal_graph_projection.create_child
  val stage_intent : Worker.session -> stage -> (Worker.durable_intent,Worker.error) result
  val command : t -> Journal_graph_projection.create_child
  val page : t -> Graph.page
  val failure : t -> Worker.error option
  val resolved_status : t -> Graph.Uuid.t option
  val canonical : t -> Worker.block_summary option
  val presentation : t -> Worker.presentation option
  val stage : t -> int -> stage
  val stage_id : stage -> Graph.Uuid.t
  val interrupted : t -> index:int -> round:int64 -> string -> t * action
  val read_failed : t -> round:int64 -> string -> t * action
  val insert_rejected : t -> bool
  val status_mutation_id : domain:string -> mutation_id:string -> revision:int64
    -> block:Graph.Uuid.t -> Graph.Uuid.t option -> Graph.Uuid.t
  val retarget : t -> command:Journal_graph_projection.create_child
    -> resolved_status:Graph.Uuid.t option -> (t,string) result
  val matches_child : t -> Journal_graph_projection.create_child -> bool
  val matches_capture : t -> Journal_graph_projection.capture -> bool
  val retarget_capture : t -> command:Journal_graph_projection.capture -> resolved_status:Graph.Uuid.t option -> (t,string) result
  val bind : t -> index:int -> round:int64 -> intent:Worker.durable_intent
    -> presentation:Worker.presentation -> (t, Worker.error) result
  val receive : t -> index:int -> round:int64 -> Worker.mutation_progress -> t * action
  val read_child : t -> round:int64 -> Worker.block_summary -> t * action
  val projection_ready : t -> round:int64 -> t * action
  type recovery = private {mutation_id:string;round:int64;delay:float}
  (** One scheduled continuation after immediate recovery is exhausted. No clock
      is read here; the host returns the exact token after its external timer. *)
  val take_recovery : t -> t * recovery option
  val resume_recovery : t -> recovery -> t * action
  val retry : t -> t * action
  val applied : t -> round:int64 -> Worker.presentation -> t * action
  val acknowledged : t -> index:int -> round:int64 -> (unit,string) result -> t * action
  val rebind_ack : t -> index:int -> round:int64 -> intent:Worker.durable_intent
    -> presentation:Worker.presentation -> (t, Worker.error) result
end
