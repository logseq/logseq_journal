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

type decode_error =
  | Invalid_limit
  | Wire_too_large
  | Plaintext_too_large
  | Malformed_envelope
  | Malformed_transit of string
  | Decryption_failed of string
  | Checksum_mismatch

val decode_error_message : decode_error -> string

(** Only a successful bounded decode creates this value. It binds plaintext to
    the expected version; there is no unchecked bytes-to-verified constructor. *)
type verified
val verified_bytes : verified -> string
val verified_version : verified -> Logseq_db_types.Asset_descriptor.version

(** Preserve conservative raw/envelope classification. A candidate's parsing or
    decryption failure never becomes raw data, even if its wire checksum matches. *)
val decode
  :  maximum_plaintext_bytes:int
  -> crypto:crypto
  -> key:string option
  -> expected:Logseq_db_types.Asset_descriptor.version
  -> string
  -> (verified, decode_error) result
