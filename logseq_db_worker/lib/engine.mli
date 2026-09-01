type t

type clocks =
  { epoch_ms : unit -> int64
  ; monotonic_ns : unit -> int64
  }

type dependencies =
  { clocks : clocks
  ; cursor_authentication_key : bytes
  }

exception Fatal_storage_error of Error.t

type attachment =
  { graph_id : Graph_types.Uuid.t
  ; graph_name : string
  ; graph_dir : string
  ; database_path : string
  ; checkpoint : Sync_checkpoint.t
  }

val open_
  :  dependencies:dependencies
  -> response_budget_bytes:int
  -> attachment
  -> (t, Error.t) result

val execute : t -> Protocol.request -> Protocol.response
val sync_checkpoint : t -> (Sync_checkpoint.t, string) result
val authoritative_database : t -> (Datascript.db, string) result
val projected_database : t -> (Datascript.db, string) result
val authoritative_precondition : t -> (string, string) result

val duplicate_managed_mutation
  :  t
  -> Logseq_db_types.Mutation.t
  -> (Logseq_db_types.Mutation.success, string) result

type prepared_managed_mutation

val prepare_managed_mutation
  :  t
  -> identity:Logseq_db_types.Mutation.identity
  -> Logseq_db_types.Mutation.t
  -> (prepared_managed_mutation, string) result

val prepared_mutation_payload : prepared_managed_mutation -> string
val prepared_mutation_outliner_op : prepared_managed_mutation -> string
val prepared_mutation_database : prepared_managed_mutation -> Datascript.db
val prepared_mutation_operations : prepared_managed_mutation -> Datascript.tx_op list

type managed_replan =
  { status : Logseq_db_types.Mutation.status
  ; outliner_op : string
  ; operations : Datascript.tx_op list
  ; projected_database : Datascript.db
  }

val replan_managed_mutation
  :  t
  -> database:Datascript.db
  -> Logseq_db_types.Mutation.t
  -> (managed_replan, string) result

val restore_managed_projection : t -> (unit, string) result

val commit_managed_mutation
  :  t
  -> prepared_managed_mutation
  -> outbox_records:string list
  -> (Logseq_db_types.Mutation.success, string) result

val managed_outbox_records : t -> (string list, string) result

val commit_outbox_transition
  :  t
  -> expected:string list
  -> string list
  -> (unit, string) result

type authoritative_apply_error =
  | Authoritative_conflict
  | Authoritative_apply_failed of string

val apply_authoritative
  :  t
  -> expected_precondition:string
  -> Datascript.tx_op list list
  -> projection_transactions:Datascript.tx_op list list
  -> checkpoint:Sync_checkpoint.t
  -> outbox_records:string list
  -> ( int64 * int64 * Graph_types.Uuid.t list * Datascript.db
       , authoritative_apply_error )
       result

val close : t -> (unit, string) result
val basis : t -> int64 option
