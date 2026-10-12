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
[@@deriving yojson]

type detail_value =
  | Detail_string of string
  | Detail_int of int64
  | Detail_bool of bool
  | Detail_uuid of Graph_types.Uuid.t
  | Detail_strings of string list
  | Detail_uuids of Graph_types.Uuid.t list
[@@deriving yojson]

type detail =
  { name : string
  ; value : detail_value
  }
[@@deriving yojson]

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
[@@deriving yojson]

type cause =
  { component : component
  ; operation : string
  ; code : string option
  ; message : string
  }
[@@deriving yojson]

type causal_trace =
  { contexts : cause list
  ; origin : cause
  ; truncated : bool
  }
[@@deriving yojson]

type t =
  { code : code
  ; message : string
  ; details : detail list
  ; trace : causal_trace
  }
[@@deriving yojson]

let maximum_contexts = 16
let maximum_message_bytes = 512
let maximum_encoded_bytes = 32_768
let maximum_details = 64
let maximum_detail_values = 64
let maximum_name_bytes = 128

let code_string = function
  | Invalid_request -> "invalidRequest"
  | Stale_read_cursor -> "staleReadCursor"
  | Unsupported_api_version -> "unsupportedApiVersion"
  | Graph_not_found -> "graphNotFound"
  | Graph_locked -> "graphLocked"
  | Ownership_recovery -> "ownershipRecovery"
  | Unsupported_schema -> "unsupportedSchema"
  | Remote_graph -> "remoteGraph"
  | Ambiguous_sync_state -> "ambiguousSyncState"
  | Unsupported_value -> "unsupportedValue"
  | Unsupported_semantics -> "unsupportedSemantics"
  | Corrupt_storage -> "corruptStorage"
  | Not_found -> "notFound"
  | Ambiguous_selector -> "ambiguousSelector"
  | Duplicate_selector -> "duplicateSelector"
  | Built_in_protected -> "builtInProtected"
  | Invalid_tree -> "invalidTree"
  | Invalid_order -> "invalidOrder"
  | Invalid_position -> "invalidPosition"
  | Conflict -> "conflict"
  | Response_too_large -> "responseTooLarge"
  | Storage_busy -> "storageBusy"
  | Closed_session -> "closedSession"
;;

let code_of_string = function
  | "invalidRequest" -> Some Invalid_request
  | "staleReadCursor" -> Some Stale_read_cursor
  | "unsupportedApiVersion" -> Some Unsupported_api_version
  | "graphNotFound" -> Some Graph_not_found
  | "graphLocked" -> Some Graph_locked
  | "ownershipRecovery" -> Some Ownership_recovery
  | "unsupportedSchema" -> Some Unsupported_schema
  | "remoteGraph" -> Some Remote_graph
  | "ambiguousSyncState" -> Some Ambiguous_sync_state
  | "unsupportedValue" -> Some Unsupported_value
  | "unsupportedSemantics" -> Some Unsupported_semantics
  | "corruptStorage" -> Some Corrupt_storage
  | "notFound" -> Some Not_found
  | "ambiguousSelector" -> Some Ambiguous_selector
  | "duplicateSelector" -> Some Duplicate_selector
  | "builtInProtected" -> Some Built_in_protected
  | "invalidTree" -> Some Invalid_tree
  | "invalidOrder" -> Some Invalid_order
  | "invalidPosition" -> Some Invalid_position
  | "conflict" -> Some Conflict
  | "responseTooLarge" -> Some Response_too_large
  | "storageBusy" -> Some Storage_busy
  | "closedSession" -> Some Closed_session
  | _ -> None
;;

let component_string = function
  | Logseq_db_worker -> "logseqDbWorker"
  | Ownership -> "ownership"
  | Sqlite -> "sqlite"
  | Storage -> "storage"
  | Query -> "query"
  | Read_model -> "readModel"
  | Outliner -> "outliner"
  | Mutation_planner -> "mutationPlanner"
  | Engine -> "engine"
  | Protocol -> "protocol"
  | Managed_sync -> "managedSync"
  | Worker_service -> "workerService"
  | Operating_system -> "operatingSystem"
  | Dependency -> "dependency"
;;

let valid_name name =
  String.length name > 0
  && String.length name <= maximum_name_bytes
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
         | _ -> false)
       name
;;

let contains text needle =
  let rec loop index =
    if index + String.length needle > String.length text
    then false
    else if String.sub text index (String.length needle) = needle
    then true
    else loop (index + 1)
  in
  String.length needle = 0 || loop 0
;;

let display_safe value =
  String.length value > 0
  && String.length value <= maximum_message_bytes
  && List.for_all
       (fun prohibited -> not (contains value prohibited))
       [ "/Users/"
       ; "/home/"
       ; "Bearer "
       ; "password="
       ; "token="
       ; "access_token"
       ; "refresh_token"
       ; "signedUrl"
       ; "signed_url"
       ; "BEGIN PRIVATE KEY"
       ]
;;

let create_cause ~component ~operation ~code ~message =
  if not (valid_name operation)
  then Error "cause operation must contain 1..128 identifier bytes"
  else if
    match code with
    | Some value -> not (valid_name value)
    | None -> false
  then Error "cause code must contain 1..128 identifier bytes"
  else if not (display_safe message)
  then Error "cause message is empty, oversized, or not display-safe"
  else Ok { component; operation; code; message }
;;

let create_cause_or_fallback ~component ~operation ~code ~message ~fallback_message =
  match create_cause ~component ~operation ~code ~message with
  | Ok cause -> cause
  | Error _ ->
    create_cause ~component ~operation ~code ~message:fallback_message |> Result.get_ok
;;

let valid_detail_value = function
  | Detail_string value -> display_safe value
  | Detail_int _ | Detail_bool _ | Detail_uuid _ -> true
  | Detail_strings values ->
    List.length values <= maximum_detail_values && List.for_all display_safe values
  | Detail_uuids values -> List.length values <= maximum_detail_values
;;

let valid_details details =
  List.length details <= maximum_details
  && List.for_all
       (fun detail -> valid_name detail.name && valid_detail_value detail.value)
       details
;;

let encoded_bytes value = String.length (Yojson.Safe.to_string (to_yojson value))

let validate_error value =
  if not (display_safe value.message)
  then Error "error message is empty, oversized, or not display-safe"
  else if not (valid_details value.details)
  then Error "invalid error details"
  else if List.length value.trace.contexts > maximum_contexts
  then Error "causal context count exceeds the bound"
  else if encoded_bytes value > maximum_encoded_bytes
  then Error "encoded error exceeds the byte bound"
  else Ok value
;;

let create_with_origin ~code ~message ~details ~origin =
  validate_error
    { code; message; details; trace = { contexts = []; origin; truncated = false } }
;;

let create ~code ~message ~details =
  Result.bind
    (create_cause
       ~component:Logseq_db_worker
       ~operation:(code_string code)
       ~code:(Some (code_string code))
       ~message)
    (fun origin -> create_with_origin ~code ~message ~details ~origin)
;;

let rec drop_outer_contexts contexts count =
  if count <= 0
  then contexts
  else (
    match contexts with
    | [] -> []
    | _ :: rest -> drop_outer_contexts rest (count - 1))
;;

let wrap ~code ~message ~details ~context lower =
  let contexts = context :: lower.trace.contexts in
  let excess = max 0 (List.length contexts - maximum_contexts) in
  let contexts = drop_outer_contexts contexts excess in
  let rec fit contexts dropped =
    let value =
      { code
      ; message
      ; details
      ; trace =
          { contexts
          ; origin = lower.trace.origin
          ; truncated = lower.trace.truncated || excess > 0 || dropped
          }
      }
    in
    if encoded_bytes value <= maximum_encoded_bytes
    then validate_error value
    else (
      match contexts with
      | [] -> Error "encoded error exceeds the byte bound"
      | _ :: rest -> fit rest true)
  in
  fit contexts false
;;

let code value = value.code
let message value = value.message
let details value = value.details
let trace value = value.trace

let of_yojson json =
  Result.bind
    (Logseq_db_types.Json_codec.decode
       ~maximum_bytes:maximum_encoded_bytes
       of_yojson
       json)
    (fun value ->
       let valid_cause (cause : cause) =
         Result.is_ok
           (create_cause
              ~component:cause.component
              ~operation:cause.operation
              ~code:cause.code
              ~message:cause.message)
       in
       if
         not
           (valid_cause value.trace.origin
            && List.for_all valid_cause value.trace.contexts)
       then Error "invalid causal trace"
       else validate_error value)
;;
