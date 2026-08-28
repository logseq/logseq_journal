type purpose =
  | Catalog_discovery
  | Snapshot_bootstrap
  | E2ee_key_access
  | Websocket_connect

type challenge =
  { challenge_id : string
  ; purpose : purpose
  ; user_id : string
  ; account_generation : int
  ; graph_generation : int option
  ; connection_generation : int option
  }

type error =
  | Unknown_challenge
  | User_mismatch
  | Account_generation_mismatch
  | Graph_generation_mismatch
  | Connection_generation_mismatch
  | Invalid_token

type t

val create : next_id:(unit -> string) -> unit -> t

val issue
  :  t
  -> purpose:purpose
  -> user_id:string
  -> account_generation:int
  -> graph_generation:int option
  -> connection_generation:int option
  -> challenge

val provide
  :  t
  -> challenge_id:string
  -> user_id:string
  -> account_generation:int
  -> graph_generation:int option
  -> connection_generation:int option
  -> token:string
  -> (challenge * string, error) result

val fail : t -> challenge_id:string -> (challenge, error) result
val cancel_all : t -> unit
val pending_count : t -> int
val diagnostics : t -> string
