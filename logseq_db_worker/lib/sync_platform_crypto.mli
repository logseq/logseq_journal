val crypto : Sync_e2ee.crypto
val has_private_key : user_id:string -> bool

val unlock_private_key
  :  user_id:string
  -> password:string
  -> private_key_package:string
  -> (unit, string) result

val unlock_graph_key
  :  user_id:string
  -> encrypted_graph_key:string
  -> (string, string) result
