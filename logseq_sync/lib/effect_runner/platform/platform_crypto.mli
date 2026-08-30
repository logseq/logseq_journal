type crypto =
  { decrypt_private_key :
      password:string
      -> iterations:int
      -> salt:string
      -> iv:string
      -> ciphertext:string
      -> (string, string) result
  ; decrypt_graph_key : private_key:string -> ciphertext:string -> (string, string) result
  ; encrypt_aes_gcm : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

val crypto : crypto
val has_private_key : managed_sync_origin:Uri.t -> user_id:string -> bool

val unlock_private_key
  :  managed_sync_origin:Uri.t
  -> user_id:string
  -> password:string
  -> private_key_package:string
  -> (unit, string) result

val unlock_graph_key
  :  managed_sync_origin:Uri.t
  -> user_id:string
  -> encrypted_graph_key:string
  -> (string, string) result

type wrapped_key_load_failure =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

val load_wrapped_graph_key
  :  managed_sync_origin:Uri.t
  -> user_id:string
  -> graph_id:Graph_types.Uuid.t
  -> (string, wrapped_key_load_failure) result

val verify_and_save_wrapped_graph_key
  :  managed_sync_origin:Uri.t
  -> user_id:string
  -> graph_id:Graph_types.Uuid.t
  -> encrypted_graph_key:string
  -> (unit, string) result

val delete_wrapped_graph_key
  :  managed_sync_origin:Uri.t
  -> user_id:string
  -> graph_id:Graph_types.Uuid.t
  -> (unit, string) result

val delete_account_secrets
  :  managed_sync_origin:Uri.t
  -> user_id:string
  -> (unit, string) result
