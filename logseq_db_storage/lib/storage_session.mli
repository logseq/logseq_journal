type t
type staged

type error =
  | Closed
  | Fatal of string
  | Stage_failed of string
  | Persistence_failed of string
  | Already_consumed

val garbage_collection_unreachable_address_threshold : int
val garbage_collection_file_growth_threshold_bytes : int64

val create
  :  db:Datascript.db
  -> tail:Datascript.datom list list
  -> callbacks:Logseq_sqlite_storage.callbacks
  -> t

val current_db : t -> Datascript.db
val current_tail : t -> Datascript.datom list list

val stage_transact
  :  ?tx_meta:Datascript.tx_meta
  -> t
  -> Datascript.tx_op list
  -> (staged, error) result

val stage_transact_batch
  :  ?tx_meta:Datascript.tx_meta
  -> t
  -> Datascript.tx_op list list
  -> (staged, error) result

val staged_db_after : staged -> Datascript.db
val staged_tx_data : staged -> Datascript.datom list
val commit_staged : t -> staged -> (unit, error) result

val commit_staged_with_sync_metadata
  :  t
  -> staged
  -> Sync_checkpoint.t
  -> (unit, error) result

val persist_sync_metadata : t -> Sync_checkpoint.t -> (unit, error) result
val load_sync_outbox : t -> (string list, error) result
val commit_sync_outbox_insert : t -> string list -> (unit, error) result

val commit_staged_with_sync_metadata_and_outbox
  :  t
  -> staged
  -> Sync_checkpoint.t
  -> string list
  -> (unit, error) result

val garbage_collection_needed : t -> (bool, error) result
val collect_garbage : t -> (unit, error) result
val close : t -> (unit, error) result
val is_fatal : t -> bool
