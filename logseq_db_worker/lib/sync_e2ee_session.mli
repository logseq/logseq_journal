type phase =
  | Fetching_graph_key
  | Fetching_user_keys
  | Awaiting_password
  | Ready
  | Failed

type platform =
  { has_private_key : managed_sync_origin:Uri.t -> user_id:string -> bool
  ; unlock_private_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> password:string
      -> private_key_package:string
      -> (unit, string) result
  }

type t

val create
  :  platform:platform
  -> managed_sync_origin:Uri.t
  -> user_id:string
  -> graph_id:Graph_types.Uuid.t
  -> graph_name:string
  -> t

val phase : t -> phase
val graph_name : t -> string
val encrypted_graph_key : t -> string option
val accept_graph_key_response : t -> string -> (unit, string) result
val accept_user_keys_response : t -> string -> (unit, string) result
val submit_password : t -> string -> (unit, string) result
val clear : t -> unit
