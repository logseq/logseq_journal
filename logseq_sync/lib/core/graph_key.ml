type t =
  { bytes : bytes
  ; mutable cleared : bool
  }

let of_string value =
  if String.length value = 32
  then Ok { bytes = Bytes.of_string value; cleared = false }
  else Error "graph key must contain exactly 32 bytes"
;;

let clear key =
  if not key.cleared
  then (
    Bytes.fill key.bytes 0 (Bytes.length key.bytes) '\000';
    key.cleared <- true)
;;

let use key operation =
  if key.cleared
  then Error "graph key has been cleared"
  else operation (Bytes.unsafe_to_string key.bytes)
;;

let encrypt_value ~crypto key value =
  use key (fun graph_key -> E2ee.encrypt_value ~crypto ~graph_key value)
;;

let decrypt_value ~crypto key ciphertext =
  use key (fun graph_key -> E2ee.decrypt_value ~crypto ~graph_key ciphertext)
;;
