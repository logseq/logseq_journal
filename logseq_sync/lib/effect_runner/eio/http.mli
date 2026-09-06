type expected_content_type =
  | Structured_response
  | Snapshot_artifact

type request =
  { uri : Uri.t
  ; headers : (string * string) list
  ; maximum_response_bytes : int
  ; expected_content_type : expected_content_type
  }

val catalog : base_url:Uri.t -> token:string -> request

val snapshot_baseline
  :  base_url:Uri.t
  -> graph_id:Graph_types.Uuid.t
  -> token:string
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
val same_origin : Uri.t -> Uri.t -> bool
val artifact : base_url:Uri.t -> uri:Uri.t -> token:string option -> request
val validate_base_url : Uri.t -> (unit, string) result

val validate_response_content_type
  :  request
  -> (string * string) list
  -> (unit, string) result
