(** {1 TLDR}

    Encode and verify bounded asset file bytes, using caller-supplied crypto.
    [encode] returns wire bytes or an error; [decode] alone creates {!verified}
    plaintext bound to the expected asset version. No file I/O or persistence
    occurs here. Envelopes encrypt raw file bytes, not Transit title values.
    An envelope failure must never fall back to raw bytes. *)

type crypto =
  { encrypt : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt : key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

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

(** {1 Minimal usage example}

    The caller supplies [crypto], [key], [expected], [wire] and a positive
    [maximum_plaintext_bytes] matching its resource budget:
    {[
      match decode ~maximum_plaintext_bytes ~crypto ~key ~expected wire with
      | Ok verified -> Ok (verified_version verified, verified_bytes verified)
      | Error error -> Error (decode_error_message error)
    ]}
    Verification failure leaves the caller responsible for rejecting the input;
    no cache handle or file is acquired by this operation. *)

(** {1 Observation and helpers} *)

val checksum : string -> string
val decode_error_message : decode_error -> string
