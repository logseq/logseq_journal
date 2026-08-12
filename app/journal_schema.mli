module Attr : sig
  val store_id : string
  val store_schema_version : string
  val page_id : string
  val page_day : string
  val page_title : string
  val block_id : string
  val block_page : string
  val block_parent : string
  val block_order : string
  val block_parent_order : string
  val block_parent_order_block : string
  val block_source : string
  val block_task_state : string
  val block_created_instant_unix_ms : string
  val block_created_local_day : string
  val block_created_local_minute : string
  val block_created_time_zone_id : string
  val block_created_utc_offset_seconds : string
  val block_revision : string
  val block_last_mutation_id : string
end

module Error : sig
  type t

  val to_string : t -> string
end

val version : int
val store_identity : string

(** The exact app-private DataScript schema accepted by this application
    version. *)
val data_script : Datascript.schema

(** Reject missing, additional, or structurally changed schema attributes. *)
val validate_schema : Datascript.schema -> (unit, Error.t) result
