module Transit = Transit_core.Json

type crypto =
  { decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

type private_key_package =
  { salt : string
  ; iv : string
  ; ciphertext : string
  }

val binary : string -> (string, string) result
val private_key_package : string -> (private_key_package, string) result

val decrypt_value
  :  crypto:crypto
  -> graph_key:string
  -> string
  -> (Transit.value, string) result
