type response = (bytes, string) result
type scope = Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope
type t

val create
  :  emit:(bytes -> unit)
  -> enqueue:((unit -> unit) -> unit)
  -> is_running:(unit -> bool)
  -> current_scope:(unit -> scope)
  -> send_response:(int -> response -> unit)
  -> decode_failure:(string -> unit)
  -> t

val emit : t -> ?on_result:(response -> unit) -> bytes -> unit
(** Remove the current continuation before invoking it. Success responses retain
    the existing protocol behavior; queued failure fences belong to [fail]. *)
val resolve : t -> response_tag:int -> response -> bool
val fail
  :  t
  -> request_tag:int
  -> reason:string
  -> supplied_scope:(int64 * int64) option
  -> unit
