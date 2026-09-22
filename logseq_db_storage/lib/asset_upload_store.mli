(** Upload checkpoints are durable local worker state, never synchronized datoms. *)
val initialize_database : Sqlite3.db -> (unit, string) result

val save
  :  Sqlite3.db
  -> expected:int option
  -> Logseq_db_types.Asset_upload_intent.t
  -> (unit, string) result

val read
  :  Sqlite3.db
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> (Logseq_db_types.Asset_upload_intent.t option, string) result

val list
  :  Sqlite3.db
  -> origin:string
  -> account:string
  -> graph:Logseq_db_types.Graph_types.Uuid.t
  -> after:Logseq_db_types.Graph_types.Uuid.t option
  -> limit:int
  -> (Logseq_db_types.Asset_upload_intent.t list, string) result

val delete_graph
  :  Sqlite3.db
  -> origin:string
  -> account:string
  -> graph:Logseq_db_types.Graph_types.Uuid.t
  -> (unit, string) result

val delete_account
  :  Sqlite3.db
  -> origin:string
  -> account:string
  -> (unit, string) result
