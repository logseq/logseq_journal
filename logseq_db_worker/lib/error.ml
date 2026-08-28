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

type t =
  { code : code
  ; message : string
  ; details : detail list
  }

let valid_detail_name name =
  String.length name > 0
  && String.length name <= 128
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
         | _ -> false)
       name
;;

let create ~code ~message ~details =
  if String.length message = 0 || String.length message > 4096
  then Error "error message must contain 1..4096 bytes"
  else if
    List.length details > 64
    || not (List.for_all (fun detail -> valid_detail_name detail.name) details)
  then Error "invalid error details"
  else Ok { code; message; details }
;;

let code value = value.code
let message value = value.message
let details value = value.details

let code_string = function
  | Invalid_request -> "invalidRequest"
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

let to_yojson value =
  `Assoc
    [ "code", `String (code_string value.code)
    ; "message", `String value.message
    ; "details", `List (List.map detail_to_yojson value.details)
    ]
;;

let detail_of_yojson = function
  | `Assoc
      [ ("name", `String name)
      ; ("value", `Assoc [ ("type", `String kind); ("value", value) ])
      ] ->
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
        Result.map (fun value -> Detail_uuid value) (Graph_types.Uuid.of_string value)
      | "strings", value -> parse_strings (fun values -> Detail_strings values) value
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
    Result.map (fun value -> { name; value }) parsed
  | _ -> Error "invalid detail envelope"
;;

let of_yojson = function
  | `Assoc
      [ ("code", `String code); ("message", `String message); ("details", `List details) ]
    ->
    (match code_of_string code with
     | None -> Error "unknown error code"
     | Some code ->
       let rec parse acc = function
         | [] -> create ~code ~message ~details:(List.rev acc)
         | detail :: rest ->
           Result.bind (detail_of_yojson detail) (fun detail ->
             parse (detail :: acc) rest)
       in
       parse [] details)
  | _ -> Error "invalid error envelope"
;;
