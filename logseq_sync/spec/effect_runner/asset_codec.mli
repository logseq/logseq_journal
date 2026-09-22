(** The asset envelope encrypts raw file bytes, not a Transit title value. *)
type crypto =
  { encrypt : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt : key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

val checksum : string -> string

val encode
  :  maximum_plaintext_bytes:int
  -> crypto:crypto
  -> key:string option
  -> string
  -> (string, string) result

(** Validate the bounded two-string envelope shape before allocating a Transit tree. *)
val decode
  :  maximum_plaintext_bytes:int
  -> crypto:crypto
  -> key:string option
  -> expected_checksum:string
  -> string
  -> (string, string) result
