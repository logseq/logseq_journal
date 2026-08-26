(** Zeroizable plaintext graph-key ownership inside the Engine crypto boundary. *)

type t

val of_string : string -> (t, string) result
val clear : t -> unit

val encrypt_value
  :  crypto:Sync_e2ee.crypto
  -> t
  -> Transit_core.Json.value
  -> (string, string) result

val decrypt_value
  :  crypto:Sync_e2ee.crypto
  -> t
  -> string
  -> (Transit_core.Json.value, string) result
