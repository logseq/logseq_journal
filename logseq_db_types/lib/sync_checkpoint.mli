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

val format_version : int

val create
  :  graph_id:Graph_types.Uuid.t
  -> schema:Graph_types.schema_version
  -> applied_server_t:int
  -> checksum:string
  -> (t, string) result

val create_full
  :  graph_id:Graph_types.Uuid.t
  -> schema:Graph_types.schema_version
  -> applied_server_t:int
  -> checksum:string
  -> status:status
  -> last_error:string option
  -> (t, string) result

val equal : t -> t -> bool
