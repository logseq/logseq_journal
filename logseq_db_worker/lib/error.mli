type code =
  | Invalid_request
  | Unsupported_api_version
  | Graph_not_found
  | Graph_locked
  | Ownership_recovery
  | Unsupported_schema
  | Remote_graph
  | Ambiguous_sync_state
  | Unsupported_value
  | Unsupported_semantics
  | Corrupt_storage
  | Not_found
  | Ambiguous_selector
  | Duplicate_selector
  | Built_in_protected
  | Invalid_tree
  | Invalid_order
  | Invalid_position
  | Conflict
  | Response_too_large
  | Storage_busy
  | Closed_session

type detail_value =
  | Detail_string of string
  | Detail_int of int64
  | Detail_bool of bool
  | Detail_uuid of Graph_types.Uuid.t
  | Detail_strings of string list
  | Detail_uuids of Graph_types.Uuid.t list

type detail =
  { name : string
  ; value : detail_value
  }

type t

val create : code:code -> message:string -> details:detail list -> (t, string) result
val code : t -> code
val message : t -> string
val details : t -> detail list
val code_string : code -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
