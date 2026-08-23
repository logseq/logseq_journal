type phase =
  | Fetching_graph_key
  | Fetching_user_keys
  | Awaiting_password
  | Ready
  | Failed

type platform =
  { has_private_key : user_id:string -> bool
  ; unlock_private_key :
      user_id:string
      -> password:string
      -> private_key_package:string
      -> (unit, string) result
  ; decrypt_graph_key :
      user_id:string -> encrypted_graph_key:string -> (string, string) result
  }

type t

val create
  :  platform:platform
  -> user_id:string
  -> graph_id:Graph_types.Uuid.t
  -> graph_name:string
  -> t

val phase : t -> phase
val graph_name : t -> string
val encrypted_graph_key : t -> string option
val graph_key : t -> string option
val accept_graph_key_response : t -> string -> (unit, string) result
val accept_user_keys_response : t -> string -> (unit, string) result
val submit_password : t -> string -> (unit, string) result
val clear : t -> unit
