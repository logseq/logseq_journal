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

type t =
  { code : code
  ; message : string
  ; details : detail list
  ; trace : causal_trace
  }

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

let component_of_string = function
  | "logseqDbWorker" -> Some Logseq_db_worker
  | "ownership" -> Some Ownership
  | "sqlite" -> Some Sqlite
  | "storage" -> Some Storage
  | "query" -> Some Query
  | "readModel" -> Some Read_model
  | "outliner" -> Some Outliner
  | "mutationPlanner" -> Some Mutation_planner
  | "engine" -> Some Engine
  | "protocol" -> Some Protocol
  | "managedSync" -> Some Managed_sync
  | "workerService" -> Some Worker_service
  | "operatingSystem" -> Some Operating_system
  | "dependency" -> Some Dependency
  | _ -> None
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

let detail_to_yojson detail =
  let kind, value =
    match detail.value with
    | Detail_string value -> "string", `String value
    | Detail_int value -> "int64", `String (Int64.to_string value)
    | Detail_bool value -> "bool", `Bool value
    | Detail_uuid value -> "uuid", `String (Graph_types.Uuid.to_string value)
    | Detail_strings values ->
      "strings", `List (List.map (fun value -> `String value) values)
    | Detail_uuids values ->
      ( "uuids"
      , `List (List.map (fun value -> `String (Graph_types.Uuid.to_string value)) values)
      )
  in
  `Assoc
    [ "name", `String detail.name
    ; "value", `Assoc [ "type", `String kind; "value", value ]
    ]
;;

let cause_to_yojson cause =
  `Assoc
    [ "component", `String (component_string cause.component)
    ; "operation", `String cause.operation
    ; "code", Option.fold ~none:`Null ~some:(fun value -> `String value) cause.code
    ; "message", `String cause.message
    ]
;;

let to_yojson value =
  `Assoc
    [ "code", `String (code_string value.code)
    ; "message", `String value.message
    ; "details", `List (List.map detail_to_yojson value.details)
    ; ( "trace"
      , `Assoc
          [ "contexts", `List (List.map cause_to_yojson value.trace.contexts)
          ; "origin", cause_to_yojson value.trace.origin
          ; "truncated", `Bool value.trace.truncated
          ] )
    ]
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

let assoc_fields expected = function
  | `Assoc fields ->
    let actual = List.map fst fields |> List.sort String.compare in
    let expected = List.sort String.compare expected in
    if actual = expected then Ok fields else Error "unknown, duplicate, or missing field"
  | _ -> Error "expected object"
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing " ^ name)
;;

let bind_field name fields parse = Result.bind (field name fields) parse

let parse_string = function
  | `String value -> Ok value
  | _ -> Error "expected string"
;;

let parse_code = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error "invalid optional code"
;;

let cause_of_yojson json =
  Result.bind
    (assoc_fields [ "component"; "operation"; "code"; "message" ] json)
    (fun fields ->
       Result.bind (bind_field "component" fields parse_string) (fun component ->
         match component_of_string component with
         | None -> Error "unknown error component"
         | Some component ->
           Result.bind (bind_field "operation" fields parse_string) (fun operation ->
             Result.bind (bind_field "code" fields parse_code) (fun code ->
               Result.bind (bind_field "message" fields parse_string) (fun message ->
                 create_cause ~component ~operation ~code ~message)))))
;;

let detail_of_yojson json =
  Result.bind
    (assoc_fields [ "name"; "value" ] json)
    (fun fields ->
       Result.bind (bind_field "name" fields parse_string) (fun name ->
         Result.bind (field "value" fields) (fun value_json ->
           Result.bind
             (assoc_fields [ "type"; "value" ] value_json)
             (fun value_fields ->
                Result.bind (bind_field "type" value_fields parse_string) (fun kind ->
                  Result.bind (field "value" value_fields) (fun value ->
                    let parse_strings constructor = function
                      | `List values ->
                        let rec loop acc = function
                          | [] -> Ok (constructor (List.rev acc))
                          | `String value :: rest -> loop (value :: acc) rest
                          | _ -> Error "invalid detail list"
                        in
                        loop [] values
                      | _ -> Error "invalid detail list"
                    in
                    let parsed =
                      match kind, value with
                      | "string", `String value -> Ok (Detail_string value)
                      | "int64", `String value ->
                        (try Ok (Detail_int (Int64.of_string value)) with
                         | Failure _ -> Error "invalid int detail")
                      | "bool", `Bool value -> Ok (Detail_bool value)
                      | "uuid", `String value ->
                        Result.map
                          (fun value -> Detail_uuid value)
                          (Graph_types.Uuid.of_string value)
                      | "strings", value ->
                        parse_strings (fun values -> Detail_strings values) value
                      | "uuids", `List values ->
                        let rec loop acc = function
                          | [] -> Ok (Detail_uuids (List.rev acc))
                          | `String value :: rest ->
                            Result.bind (Graph_types.Uuid.of_string value) (fun uuid ->
                              loop (uuid :: acc) rest)
                          | _ -> Error "invalid UUID detail list"
                        in
                        loop [] values
                      | _ -> Error "invalid detail value"
                    in
                    Result.map (fun value -> { name; value }) parsed))))))
;;

let parse_list parse = function
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest -> Result.bind (parse value) (fun value -> loop (value :: acc) rest)
    in
    loop [] values
  | _ -> Error "expected list"
;;

let of_yojson json =
  Result.bind
    (assoc_fields [ "code"; "message"; "details"; "trace" ] json)
    (fun fields ->
       Result.bind (bind_field "code" fields parse_string) (fun raw_code ->
         match code_of_string raw_code with
         | None -> Error "unknown error code"
         | Some code ->
           Result.bind (bind_field "message" fields parse_string) (fun message ->
             Result.bind
               (bind_field "details" fields (parse_list detail_of_yojson))
               (fun details ->
                  Result.bind (field "trace" fields) (fun trace_json ->
                    Result.bind
                      (assoc_fields [ "contexts"; "origin"; "truncated" ] trace_json)
                      (fun trace_fields ->
                         Result.bind
                           (bind_field
                              "contexts"
                              trace_fields
                              (parse_list cause_of_yojson))
                           (fun contexts ->
                              Result.bind
                                (bind_field "origin" trace_fields cause_of_yojson)
                                (fun origin ->
                                   Result.bind (field "truncated" trace_fields) (function
                                     | `Bool truncated ->
                                       validate_error
                                         { code
                                         ; message
                                         ; details
                                         ; trace = { contexts; origin; truncated }
                                         }
                                     | _ -> Error "invalid trace truncation flag")))))))))
;;
