type anchor =
  { block_id : string option
  ; first_index : int
  }

type route =
  | Timeline
  | Capture
  | Detail_loading
  | Detail
  | Missing_detail

type t

val create : anchor:anchor -> t
val route : t -> route
val anchor_to_restore : t -> anchor option
val set_anchor : t -> anchor -> t
val open_capture : t -> session_number:int64 -> t
val capture : t -> Journal_capture.t option
val update_capture : t -> Journal_capture.t -> t
val open_detail : t -> block_id:string -> request_generation:int64 -> t
val detail_block_id : t -> string option
val detail_request_generation : t -> int64

val apply_detail_response
  :  t
  -> request_generation:int64
  -> Journal_repository.detail
  -> t

val apply_missing_detail : t -> request_generation:int64 -> t
val detail : t -> Journal_detail.t option
val update_detail : t -> Journal_detail.t -> t
val back : t -> t
val keep_editing : t -> t
val discard : t -> t
val background : t -> t
val runtime_replaced : t -> t
