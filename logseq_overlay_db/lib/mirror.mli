type staged

val stage
  :  root:string
  -> graph_id:Logseq_db_types.Graph_types.Uuid.t
  -> snapshot_path:string
  -> expected_rows:int
  -> (staged, string) result

val directory : staged -> string
val database_path : staged -> string
val database : staged -> Datascript.db
val schema : staged -> Logseq_db_types.Graph_types.schema_version
val stage_plaintexts : staged -> (Datascript.datom * string) list -> (unit, string) result
val apply_staged_plaintexts : staged -> (Datascript.db, string) result

val persist
  :  staged
  -> Datascript.db
  -> Logseq_db_types.Sync_checkpoint.t
  -> (unit, string) result

val activate : staged -> active_directory:string -> (unit, string) result
val cancel : staged -> unit
