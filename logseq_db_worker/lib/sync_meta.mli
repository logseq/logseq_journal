type status =
  | Active
  | Paused

type t =
  { format_version : int
  ; graph_id : Graph_types.Uuid.t
  ; schema : Graph_types.schema_version
  ; applied_server_t : int
  ; checksum : string
  ; status : status
  ; last_error : string option
  }

val create
  :  graph_id:Graph_types.Uuid.t
  -> schema:Graph_types.schema_version
  -> applied_server_t:int
  -> checksum:string
  -> (t, string) result

val initialize_database : Sqlite3.db -> t -> (unit, string) result
val update_database : Sqlite3.db -> t -> (unit, string) result
val advance : t -> applied_server_t:int -> checksum:string -> (t, string) result
val pause : t -> message:string -> (t, string) result
val read_database : Sqlite3.db -> (t, string) result
val read_path : string -> (t, string) result
