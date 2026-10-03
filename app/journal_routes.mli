type destination =
  | Journals
  | Favorites

type route =
  | Timeline
  | Detail_loading
  | Detail
  | Missing_detail
  | Failed_detail of string

type t

val create : unit -> t

val open_favorite
  :  t
  -> request_generation:int64
  -> Logseq_db_worker.Protocol.v2_favorite_item
  -> t * Journal_graph_request.t option

val destination : t -> destination
val select_destination : t -> destination -> t
val route : t -> route
val open_detail : t -> block_id:string -> request_generation:int64 -> t
val detail_block_id : t -> string option
val detail_request_generation : t -> int64

(** Typed presentation path. Each push allocates a distinct UI entry even for
    the same block; mutable phase/detail state is owned separately. *)
type detail_route = string

val path : t -> detail_route Lui_navigation.Path.t
val active_entry_id : t -> string option

(* Read-only rendering projection. Persist mutations on the canonical owner
    using [update_detail_at] / [retry_detail_at], rather than storing this view. *)
val at_entry : t -> entry_id:string -> t option
val update_detail_at : t -> entry_id:string -> Journal_detail.t -> t
val accept_path : t -> detail_route Lui_navigation.Path.t -> t
val pop_to_root : t -> t
val retry_detail : t -> request_generation:int64 -> t * Journal_graph_request.t option

val retry_detail_at
  :  t
  -> entry_id:string
  -> request_generation:int64
  -> t * Journal_graph_request.t option

val map_details : t -> f:(Journal_detail.t -> Journal_detail.t) -> t

type staged_delete

val stage_delete : t -> block_id:string -> t * staged_delete option
val undo_delete : t -> staged_delete -> t

val apply_detail_response
  :  t
  -> request_generation:int64
  -> Journal_graph_projection.detail
  -> t

val apply_missing_detail : t -> request_generation:int64 -> t

val apply_detail_failure
  :  ?block_id:string
  -> ?stale_cursor:bool
  -> t
  -> request_generation:int64
  -> missing:bool
  -> message:string
  -> t

val detail : t -> Journal_detail.t option
val update_detail : t -> Journal_detail.t -> t
val apply_child_created : t -> child:Journal_model.t -> parent:Journal_model.t -> t
val apply_child_failure : t -> block_id:string -> message:string -> t
val back : t -> t
val background : t -> t
val runtime_replaced : t -> t
val graph_unavailable : t -> t

module Favorites : sig
  type t

  type event =
    | Select of bool
    | Invalidate
    | Hide_target of string
    | Reveal_target of string
    | Retry
    | Visible of
        { first_index : int
        ; last_exclusive : int
        }
    | Loaded of
        Journal_graph_request.favorites_request
        * Logseq_db_worker.Protocol.v2_favorites_result
    | Failed of Journal_graph_request.favorites_request * bool * string

  val create : graph_generation:int -> t
  val step : t -> event -> t * Journal_graph_request.favorites_request list
  val revision : t -> int
  val items : t -> Logseq_db_worker.Protocol.v2_favorite_item list
  val loading : t -> bool
  val error : t -> string option
  val initialized : t -> bool
  val has_more : t -> bool
end

(** Process-local composer storage; the application owns its graph identity. *)
type retained_drafts

val retain_drafts : interrupted:bool -> t -> retained_drafts
val restore_drafts : t -> retained_drafts -> t
