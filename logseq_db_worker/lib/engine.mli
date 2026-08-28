type t

type clocks =
  { epoch_ms : unit -> int64
  ; monotonic_ns : unit -> int64
  }

type dependencies =
  { clocks : clocks
  ; cursor_authentication_key : bytes
  }

exception Fatal_storage_error of string

val open_ : dependencies:dependencies -> Config.t -> (t, Error.t) result
val execute : t -> Protocol.request -> Protocol.response
val sync_checkpoint : t -> (Sync_checkpoint.t, string) result
val authoritative_database : t -> (Datascript.db, string) result
val projected_database : t -> (Datascript.db, string) result

val duplicate_managed_mutation
  :  t
  -> Logseq_db_types.Mutation.t
  -> (Logseq_db_types.Mutation.success, string) result

type prepared_managed_mutation

val prepare_managed_mutation
  :  t
  -> Logseq_db_types.Mutation.t
  -> (prepared_managed_mutation, string) result

val prepared_mutation_payload : prepared_managed_mutation -> string
val prepared_mutation_outliner_op : prepared_managed_mutation -> string
val prepared_mutation_database : prepared_managed_mutation -> Datascript.db
val prepared_mutation_operations : prepared_managed_mutation -> Datascript.tx_op list

val commit_managed_mutation
  :  t
  -> prepared_managed_mutation
  -> outbox_records:string list
  -> (Logseq_db_types.Mutation.success, string) result

val managed_outbox_records : t -> (string list, string) result

val restore_managed_outbox
  :  t
  -> Datascript.tx_op list list
  -> (string list, string) result

val commit_outbox_transition
  :  t
  -> expected:string list
  -> string list
  -> (unit, string) result

val apply_authoritative
  :  t
  -> Datascript.tx_op list list
  -> checkpoint:Sync_checkpoint.t
  -> outbox_records:string list
  -> (int64 * int64 * Graph_types.Uuid.t list * Datascript.db, string) result

val close : t -> (unit, string) result
val basis : t -> int64 option
