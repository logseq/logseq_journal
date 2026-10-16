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

val delete_account
  :  Sqlite3.db
  -> origin:string
  -> account:string
  -> (unit, string) result

(** A frozen set of exact checkpoint payloads for coordinated local retirement. *)
type captured_graph
val capture_graph : Sqlite3.db -> origin:string -> account:string -> graph:Logseq_db_types.Graph_types.Uuid.t -> (captured_graph, string) result
val captured_graph_to_yojson : captured_graph -> Yojson.Safe.t
val captured_graph_of_yojson : Yojson.Safe.t -> (captured_graph, string) result
val captured_graph_matches : captured_graph -> origin:string -> account:string -> graph:Logseq_db_types.Graph_types.Uuid.t -> bool
(** Fails without deleting if any captured operation acquired a different payload.
    Missing rows are already retired. Uncaptured operations are never removed. *)
val delete_captured_graph : Sqlite3.db -> captured_graph -> (unit, string) result
