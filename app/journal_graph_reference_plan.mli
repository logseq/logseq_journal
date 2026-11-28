(** {1 TLDR}

    Plan bounded reference reads for a graph. The plan tracks discoveries and
    pending reads in memory. Ports plan queries, and callers publish the
    source updates returned by observation and completion. *)

module Graph = Logseq_db_types.Graph_types

type lookup = Page_lookup | Outline_lookup
type read = { block_id : string; depth : int; lookup : lookup }
type source =
  | Block of Graph.block
  | Missing_outline of Graph.Uuid.t
  | Page of { page : Graph.page; detail_owner : bool }
  | Missing_page of Graph.Uuid.t
type known = { id : string; text : string option; page_kind : bool }
type change =
  | Block_changed of { id : string; journal_block_known : bool }
  | Page_changed of { id : string; detail_page_owned : unit -> bool }
type ports =
  { now : unit -> int64
  ; plan_read : 'a. source_epoch:int64 option -> read -> 'a Journal_worker_coordination.Worker_api.query -> Graph.Uuid.t
  ; known_page : string -> Graph.page option
  }
type output =
  { requests : Graph.Uuid.t Rrbvec.t
  ; updates : (string * string option) Rrbvec.t
  }
type t

val create : localtime:(float -> Unix.tm) -> unit -> t
val observe_fragment
  : t -> ports:ports -> source_epoch:int64 -> sources:source Rrbvec.t
  -> changes:known Rrbvec.t -> property_blocks:Graph.block Seq.t -> output

(** Use a separate plan for Timeline creators so their terminal labels do
    not consume the discovery budget for content references. *)
val observe_creators
  : t -> ports:ports -> source_epoch:int64 -> Graph.Uuid.t Seq.t -> output

(** {1 Minimal usage example}

    The caller supplies [ports], the current [source_epoch], a [creator_id]
    from a Timeline block and handlers for [output]. Retain each issued read
    and its source epoch so its reply reaches the same plan:
    {[
      let plan = create ~localtime:Unix.localtime () in
      let apply output =
        Rrbvec.iter dispatch_request output.requests;
        Rrbvec.iter publish_source output.updates
      in
      let on_page_reply ~source_epoch read lookup =
        apply (receive_page plan ~ports ~source_epoch read lookup)
      in
      let on_outline_reply ~source_epoch read lookup =
        apply (receive_outline plan ~ports ~source_epoch read lookup)
      in
      apply (observe_creators plan ~ports ~source_epoch (Seq.return creator_id));
      (on_page_reply, on_outline_reply)
    ]}
    A page miss can dispatch an outline lookup. A successful reply publishes
    the profile label through [publish_source]. *)

(** {1 Capability details} *)

val plan_change : t -> ports:ports -> change -> Graph.Uuid.t option
val receive_page : t -> ports:ports -> source_epoch:int64 -> read -> Worker_pure_data.page_lookup -> output
val receive_outline : t -> ports:ports -> source_epoch:int64 -> read -> Worker_pure_data.block_lookup -> output

(** {1 Lifecycle and recovery} *)

val reset : t -> unit
val fence : t -> now:(unit -> int64) -> string -> unit
val resync : t -> ports:ports -> Graph.Uuid.t Rrbvec.t
(** Invalidate cached profile sources and refresh the supplied retained creators. *)
val refresh_creators : t -> ports:ports -> Graph.Uuid.t Seq.t -> output
val shared_read_failed : t -> ports:ports -> source_epoch:int64 -> block_id:string -> output
val read_failed : t -> ports:ports -> source_epoch:int64 -> block_id:string -> depth:int -> output
val abandon : t -> source_epoch:int64 -> read -> unit
