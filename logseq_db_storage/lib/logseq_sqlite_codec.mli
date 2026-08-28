type error =
  | Unsupported_tag of string
  | Malformed_transit of string
  | Out_of_range_number of string
  | Malformed_storage_payload of string

type physical_entry =
  { address : Datascript.storage_address
  ; content : string
  ; addresses : Datascript.storage_address list
  }

type index_metadata =
  { count : int
  ; shift : int
  }

type root_index_metadata =
  { eavt : index_metadata
  ; aevt : index_metadata
  ; avet : index_metadata
  }

val decode_transit : string -> (Transit_core.Json.value, string) result
val preflight : string -> (unit, error) result
val decode_value : string -> (Datascript.value, error) result
val encode_value : Datascript.value -> (string, error) result
val decode_storage_payload : string -> (Datascript.storage_payload, error) result
val encode_storage_payload : Datascript.storage_payload -> (string, error) result
val decode_root_index_metadata : string -> (root_index_metadata, error) result

val decode_physical_payload
  :  content:string
  -> addresses:string list
  -> (Datascript.storage_payload, error) result

val encode_physical_payload
  :  Datascript.storage_payload
  -> (string * string list, error) result

val encode_physical_batch
  :  ?restore:(Datascript.storage_address -> Datascript.storage_payload option)
  -> ?metadata:root_index_metadata
  -> (Datascript.storage_address * Datascript.storage_payload) list
  -> (physical_entry list, error) result
