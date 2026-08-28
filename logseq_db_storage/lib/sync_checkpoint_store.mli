val initialize_database
  :  Sqlite3.db
  -> Logseq_db_types.Sync_checkpoint.t
  -> (unit, string) result

val update_database
  :  Sqlite3.db
  -> Logseq_db_types.Sync_checkpoint.t
  -> (unit, string) result

val read_database : Sqlite3.db -> (Logseq_db_types.Sync_checkpoint.t, string) result
val read_path : string -> (Logseq_db_types.Sync_checkpoint.t, string) result
