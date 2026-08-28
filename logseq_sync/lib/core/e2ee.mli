module Transit = Transit_core.Json

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

type private_key_package =
  { salt : string
  ; iv : string
  ; ciphertext : string
  }

val unavailable_crypto : crypto
val protected_attributes : string list
val binary : string -> (string, string) result
val private_key_package : string -> (private_key_package, string) result

val unlock_graph_key
  :  crypto:crypto
  -> password:string
  -> private_key_package:string
  -> encrypted_graph_key:string
  -> (string, string) result

val transform_attribute_value
  :  transform:(Transit.value -> (Transit.value, string) result)
  -> attribute:string
  -> Transit.value
  -> (Transit.value, string) result

val encrypt_value
  :  crypto:crypto
  -> graph_key:string
  -> Transit.value
  -> (string, string) result

val decrypt_value
  :  crypto:crypto
  -> graph_key:string
  -> string
  -> (Transit.value, string) result
