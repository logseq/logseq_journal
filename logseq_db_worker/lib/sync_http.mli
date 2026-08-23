type meth =
  | Get
  | Post

type expected_content_type =
  | Structured_response
  | Snapshot_artifact

type request =
  { meth : meth
  ; uri : Uri.t
  ; headers : (string * string) list
  ; body : string option
  ; maximum_response_bytes : int
  ; expected_content_type : expected_content_type
  }

val catalog : base_url:Uri.t -> token:string -> request

val pull
  :  base_url:Uri.t
  -> graph_id:Graph_types.Uuid.t
  -> since:int option
  -> token:string
  -> request

val transaction_batch
  :  base_url:Uri.t
  -> graph_id:Graph_types.Uuid.t
  -> token:string
  -> body:string
  -> request

val snapshot_metadata
  :  base_url:Uri.t
  -> graph_id:Graph_types.Uuid.t
  -> token:string
  -> request

val e2ee_graph_key
  :  base_url:Uri.t
  -> graph_id:Graph_types.Uuid.t
  -> token:string
  -> request

val e2ee_user_keys : base_url:Uri.t -> token:string -> request
val artifact : uri:Uri.t -> token:string -> request

val websocket_uri
  :  base_url:Uri.t
  -> graph_id:Graph_types.Uuid.t
  -> (Uri.t, string) result

val redacted : request -> string
val validate_base_url : Uri.t -> (unit, string) result

val validate_response_content_type
  :  request
  -> (string * string) list
  -> (unit, string) result
