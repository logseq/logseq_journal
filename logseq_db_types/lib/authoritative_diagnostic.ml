type stage =
  | Prepare
  | Decode
  | Application
  | Integrity

type reason =
  | Transit_syntax
  | Empty_transaction
  | Transaction_shape
  | Operation_shape
  | Operation_keyword
  | Unsupported_operation
  | Operation_fields
  | Entity_shape
  | Reference_shape
  | Integer_range
  | Source_tx_type
  | Protected_value_type
  | Decrypted_value_count
  | Decimal_value
  | Integer_value
  | Application_exception
  | Unknown

type t = (string * Yojson.Safe.t) list

let stages = [ "prepare"; "decode"; "application"; "integrity" ]

let reasons =
  [ "transit-syntax"
  ; "empty-transaction"
  ; "transaction-shape"
  ; "operation-shape"
  ; "operation-keyword"
  ; "unsupported-operation"
  ; "operation-fields"
  ; "entity-shape"
  ; "reference-shape"
  ; "integer-range"
  ; "source-tx-type"
  ; "protected-value-type"
  ; "decrypted-value-count"
  ; "decimal-value"
  ; "integer-value"
  ; "application-exception"
  ; "unknown"
  ]
;;

let integrity_reasons =
  [ "payload-mismatch"
  ; "expected-simulation-failed"
  ; "expected-cursor-missing"
  ; "missing-durable-origin"
  ; "multiple-local-matches"
  ; "origin-context-length"
  ; "missing-frozen-interval"
  ; "cursor-overflow"
  ; "negative-interval"
  ; "stale-delete-non-delete"
  ; "stale-delete-context-length"
  ; "submitted-delete-missing-t-before"
  ; "unknown"
  ]
;;

let cursor_keys = [ "checkpoint"; "through"; "expectedCursor"; "tBefore" ]

let integrity_counters =
  [ "ordinal"
  ; "count"
  ; "expectedDatoms"
  ; "actualDatoms"
  ; "matchingSubmissions"
  ; "cursorCount"
  ; "transactionCount"
  ; "rootCount"
  ]
;;

let integrity_descriptors =
  [ "outboxState", [ "queued"; "submitted"; "accepted"; "stale-rejected"; "blocked" ]
  ; ( "mutation"
    , [ "save-block"
      ; "insert-blocks"
      ; "create-journal-page"
      ; "delete-blocks"
      ; "set-task-status"
      ; "clear-task-status"
      ; "publish-asset"
      ; "set-asset-reference"
      ] )
  ]
;;

let valid_cursor text =
  try
    let n = Int64.of_string text in
    n >= 0L && Int64.to_string n = text
  with
  | Failure _ -> false
;;

let operations =
  [ "add"; "retract"; "retract-attribute"; "retract-entity"; "cas"; "other" ]
;;

let attributes =
  [ "block/title"
  ; "block/name"
  ; "block/uuid"
  ; "block/parent"
  ; "block/page"
  ; "block/order"
  ; "block/refs"
  ; "db/ident"
  ; "db/valueType"
  ; "db/cardinality"
  ; "custom"
  ]
;;

let fields = [ "entity"; "attribute"; "value"; "expected"; "source-tx"; "unknown" ]

let kinds =
  [ "null"
  ; "bool"
  ; "string"
  ; "integer"
  ; "int64"
  ; "float"
  ; "binary"
  ; "decimal"
  ; "big-integer"
  ; "date"
  ; "uuid"
  ; "uri"
  ; "keyword"
  ; "symbol"
  ; "array"
  ; "map"
  ; "set"
  ; "list"
  ; "tagged"
  ; "unknown"
  ]
;;

let exceptions = [ "invalid-argument"; "failure"; "not-found"; "other" ]

let counter_keys =
  [ "transaction"; "operationIndex"; "operationCount"; "lookupRefs"; "arity" ]
;;

let string_lists =
  [ "stage", stages
  ; "reason", List.sort_uniq String.compare (reasons @ integrity_reasons)
  ; "operation", operations
  ; "attribute", attributes
  ; "field", fields
  ; "type", kinds
  ; "exception", exceptions
  ]
;;

let key_order =
  [ "stage"
  ; "reason"
  ; "transaction"
  ; "operationIndex"
  ; "operationCount"
  ; "lookupRefs"
  ; "arity"
  ; "operation"
  ; "attribute"
  ; "field"
  ; "type"
  ; "exception"
  ; "checkpoint"
  ; "through"
  ; "expectedCursor"
  ; "tBefore"
  ; "ordinal"
  ; "count"
  ; "expectedDatoms"
  ; "actualDatoms"
  ; "matchingSubmissions"
  ; "cursorCount"
  ; "transactionCount"
  ; "rootCount"
  ; "outboxState"
  ; "mutation"
  ]
;;

let prefix = "authoritative-decode:v1:"
let integrity_prefix = "authoritative-integrity:v1:"
let integrity_signal_prefix = "worker.applyAuthoritative.authoritativeIntegrityFailure:"
let detail_name = "authoritativeDiagnostic"
let signal_prefix = "worker.applyAuthoritative.authoritativeDecodeFailed:"
let maximum_counter = 1_000_000_000

let stage_name = function
  | Prepare -> "prepare"
  | Decode -> "decode"
  | Application -> "application"
  | Integrity -> "integrity"
;;

let reason_name = function
  | Transit_syntax -> "transit-syntax"
  | Empty_transaction -> "empty-transaction"
  | Transaction_shape -> "transaction-shape"
  | Operation_shape -> "operation-shape"
  | Operation_keyword -> "operation-keyword"
  | Unsupported_operation -> "unsupported-operation"
  | Operation_fields -> "operation-fields"
  | Entity_shape -> "entity-shape"
  | Reference_shape -> "reference-shape"
  | Integer_range -> "integer-range"
  | Source_tx_type -> "source-tx-type"
  | Protected_value_type -> "protected-value-type"
  | Decrypted_value_count -> "decrypted-value-count"
  | Decimal_value -> "decimal-value"
  | Integer_value -> "integer-value"
  | Application_exception -> "application-exception"
  | Unknown -> "unknown"
;;

let canonical entries =
  List.filter_map
    (fun key -> Option.map (fun value -> key, value) (List.assoc_opt key entries))
    key_order
;;

let fixed values fallback value = if List.mem value values then value else fallback

let operation_name = function
  | "db/add" | "add" -> "add"
  | "db/retract" | "retract" -> "retract"
  | "db.fn/retractAttribute" | "db/retractAttribute" | "retract-attribute" ->
    "retract-attribute"
  | "db/retractEntity" | "retract-entity" -> "retract-entity"
  | "db.fn/cas" | "db/cas" | "cas" -> "cas"
  | _ -> "other"
;;

let add_optional key value entries =
  match value with
  | None -> entries
  | Some value -> (key, value) :: List.remove_assoc key entries
;;

let number key value =
  Option.map
    (fun n ->
       `Int
         (max
            (if key = "transaction" || key = "operationIndex" then 1 else 0)
            (min maximum_counter n)))
    value
;;

let descriptor values fallback value =
  Option.map (fun v -> `String (fixed values fallback v)) value
;;

let with_context
      ?stage
      ?transaction
      ?operation_index
      ?operation_count
      ?lookup_refs
      ?arity
      ?operation
      ?attribute
      ?field
      entries
  =
  entries
  |> add_optional "stage" (Option.map (fun x -> `String (stage_name x)) stage)
  |> add_optional "transaction" (number "transaction" transaction)
  |> add_optional "operationIndex" (number "operationIndex" operation_index)
  |> add_optional "operationCount" (number "operationCount" operation_count)
  |> add_optional "lookupRefs" (number "lookupRefs" lookup_refs)
  |> add_optional "arity" (number "arity" arity)
  |> add_optional "operation" (Option.map (fun x -> `String (operation_name x)) operation)
  |> add_optional "attribute" (descriptor attributes "custom" attribute)
  |> add_optional "field" (descriptor fields "unknown" field)
  |> canonical
;;

let create
      ~stage
      ~reason
      ?transaction
      ?operation_index
      ?operation_count
      ?lookup_refs
      ?arity
      ?operation
      ?attribute
      ?field
      ?actual
      ?exception_kind
      ()
  =
  [ "stage", `String (stage_name stage); "reason", `String (reason_name reason) ]
  |> with_context
       ?transaction
       ?operation_index
       ?operation_count
       ?lookup_refs
       ?arity
       ?operation
       ?attribute
       ?field
  |> add_optional "type" (descriptor kinds "unknown" actual)
  |> add_optional "exception" (descriptor exceptions "other" exception_kind)
  |> canonical
;;

let integrity_context_value key value =
  if List.mem key cursor_keys && valid_cursor value
  then Some (`String value)
  else if List.mem key integrity_counters
  then (
    try
      let n = int_of_string value in
      if n >= 0 && n <= maximum_counter && string_of_int n = value
      then Some (`Int n)
      else None
    with
    | Failure _ -> None)
  else (
    match List.assoc_opt key integrity_descriptors with
    | Some values when List.mem value values -> Some (`String value)
    | _ -> None)
;;

let with_integrity_context context value =
  if List.assoc_opt "stage" value <> Some (`String "integrity")
  then value
  else (
    let entries =
      List.fold_left
        (fun entries (key, value) ->
           match integrity_context_value key value with
           | None -> entries
           | Some v -> (key, v) :: List.remove_assoc key entries)
        value
        context
      |> canonical
    in
    (* Worker Error detail strings share its 512-byte display-safe budget. *)
    let rec fit entries =
      if
        String.length integrity_prefix
        + String.length (Yojson.Safe.to_string (`Assoc entries))
        <= 512
      then entries
      else fit (List.rev (List.tl (List.rev entries)))
    in
    fit entries)
;;

let integrity ~reason ?(context = []) () =
  [ "stage", `String "integrity"
  ; "reason", `String (fixed integrity_reasons "unknown" reason)
  ]
  |> with_integrity_context context
;;

let encode value =
  (if List.assoc_opt "stage" value = Some (`String "integrity")
   then integrity_prefix
   else prefix)
  ^ Yojson.Safe.to_string (`Assoc value)
;;

let decode source =
  let is_integrity = String.starts_with ~prefix:integrity_prefix source in
  let prefix = if is_integrity then integrity_prefix else prefix in
  if String.length source > 512 || not (String.starts_with ~prefix source)
  then None
  else (
    try
      match
        Yojson.Safe.from_string
          (String.sub
             source
             (String.length prefix)
             (String.length source - String.length prefix))
      with
      | `Assoc entries ->
        let keys = List.map fst entries in
        let valid =
          List.length keys = List.length (List.sort_uniq String.compare keys)
          && List.mem_assoc "stage" entries
          && List.mem_assoc "reason" entries
          && List.for_all
               (fun (key, value) ->
                  match List.assoc_opt key string_lists, value with
                  | Some allowed, `String s -> List.mem s allowed
                  | None, `Int n when List.mem key counter_keys ->
                    (n >= if key = "transaction" || key = "operationIndex" then 1 else 0)
                    && n <= maximum_counter
                  | None, `String s when is_integrity && List.mem key cursor_keys ->
                    valid_cursor s
                  | None, `Int n when is_integrity && List.mem key integrity_counters ->
                    n >= 0 && n <= maximum_counter
                  | None, `String s when is_integrity ->
                    (match List.assoc_opt key integrity_descriptors with
                     | Some allowed -> List.mem s allowed
                     | None -> false)
                  | _ -> false)
               entries
          &&
          if is_integrity
          then
            List.assoc_opt "stage" entries = Some (`String "integrity")
            && (match List.assoc_opt "reason" entries with
                | Some (`String r) -> List.mem r integrity_reasons
                | _ -> false)
            && List.for_all
                 (fun (key, _) ->
                    List.mem
                      key
                      ([ "stage"; "reason" ]
                       @ cursor_keys
                       @ integrity_counters
                       @ List.map fst integrity_descriptors))
                 entries
          else
            List.assoc_opt "stage" entries <> Some (`String "integrity")
            && (match List.assoc_opt "reason" entries with
                | Some (`String r) -> List.mem r reasons
                | _ -> false)
            &&
            if List.assoc_opt "stage" entries = Some (`String "application")
            then
              List.assoc_opt "reason" entries = Some (`String "application-exception")
              && not (List.mem_assoc "operationIndex" entries)
            else List.assoc_opt "reason" entries <> Some (`String "application-exception")
        in
        if valid then Some (canonical entries) else None
      | _ -> None
    with
    | Yojson.Json_error _ | Failure _ | Invalid_argument _ -> None)
;;

let message value =
  let part (key, value) =
    key
    ^ "="
    ^
    match value with
    | `String s -> s
    | `Int n -> string_of_int n
    | _ -> "unknown"
  in
  (if List.assoc_opt "stage" value = Some (`String "integrity")
   then "Authoritative integrity validation failed ("
   else "Authoritative transaction rejected (")
  ^ String.concat "; " (List.map part value)
  ^ ")."
;;

let integrity_of_source source =
  match decode source with
  | Some value when List.assoc_opt "stage" value = Some (`String "integrity") -> value
  | _ ->
    let reason =
      match source with
      | "accepted transaction has no durable origin evidence" -> "missing-durable-origin"
      | "authoritative transaction ambiguously matches local submissions" ->
        "multiple-local-matches"
      | "authoritative transaction origins do not match their cursors" ->
        "origin-context-length"
      | "own transaction omitted its frozen submission interval" ->
        "missing-frozen-interval"
      | "server cursor interval overflows int64" -> "cursor-overflow"
      | "negative server cursor interval" -> "negative-interval"
      | "stale delete state contains a non-delete mutation" -> "stale-delete-non-delete"
      | "authoritative transaction roots do not match their cursors" ->
        "stale-delete-context-length"
      | "submitted delete omitted its durable t_before" ->
        "submitted-delete-missing-t-before"
      | s when String.starts_with ~prefix:"accepted transaction payload mismatch:" s ->
        "payload-mismatch"
      | _ -> "unknown"
    in
    integrity ~reason ()
;;
