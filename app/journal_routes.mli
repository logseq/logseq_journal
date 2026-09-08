type destination =
  | Journals
  | Favorites

type anchor =
  { block_id : string option
  ; first_index : int
  }

type route =
  | Timeline
  | Detail_loading
  | Detail
  | Missing_detail

type t

val create : anchor:anchor -> t
val destination : t -> destination
val select_destination : t -> destination -> t
val route : t -> route
val anchor_to_restore : t -> anchor option
val set_anchor : t -> anchor -> t
val open_detail : t -> block_id:string -> request_generation:int64 -> t
val detail_block_id : t -> string option
val detail_request_generation : t -> int64

val apply_detail_response
  :  t
  -> request_generation:int64
  -> Journal_graph_projection.detail
  -> t

val apply_missing_detail : t -> request_generation:int64 -> t
val detail : t -> Journal_detail.t option
val update_detail : t -> Journal_detail.t -> t
val back : t -> t
val keep_editing : t -> t
val discard : t -> t
val background : t -> t
val runtime_replaced : t -> t
val graph_unavailable : t -> t

module Favorites : sig
  type t

  type event =
    | Select of bool
    | Invalidate
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
  val anchor : t -> anchor
  val window : t -> int * Logseq_db_worker.Protocol.v2_favorite_item list
  val has_more : t -> bool
end
