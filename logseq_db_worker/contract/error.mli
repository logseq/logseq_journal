type code =
  | Invalid_request
  | Stale_read_cursor
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

type component =
  | Logseq_db_worker
  | Ownership
  | Sqlite
  | Storage
  | Query
  | Read_model
  | Outliner
  | Mutation_planner
  | Engine
  | Protocol
  | Managed_sync
  | Worker_service
  | Operating_system
  | Dependency

type cause =
  { component : component
  ; operation : string
  ; code : string option
  ; message : string
  }

type causal_trace =
  { contexts : cause list
  ; origin : cause
  ; truncated : bool
  }

type t

val maximum_contexts : int
val maximum_message_bytes : int
val maximum_encoded_bytes : int

val create_cause
  :  component:component
  -> operation:string
  -> code:string option
  -> message:string
  -> (cause, string) result

(** [create_cause_or_fallback] constructs a strict cause from [message], or discards
    that message and retries with the caller-owned [fallback_message] when validation
    fails. It is intended for trusted production boundaries, not decoding or
    sanitization. An invalid fallback raises [Invalid_argument]. *)
val create_cause_or_fallback
  :  component:component
  -> operation:string
  -> code:string option
  -> message:string
  -> fallback_message:string
  -> cause

val create : code:code -> message:string -> details:detail list -> (t, string) result

val create_with_origin
  :  code:code
  -> message:string
  -> details:detail list
  -> origin:cause
  -> (t, string) result

val wrap
  :  code:code
  -> message:string
  -> details:detail list
  -> context:cause
  -> t
  -> (t, string) result

val code : t -> code
val message : t -> string
val details : t -> detail list
val trace : t -> causal_trace
val code_string : code -> string
val component_string : component -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val code_of_string : string -> code option
