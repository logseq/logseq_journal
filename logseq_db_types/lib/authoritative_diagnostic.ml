type stage =
  | Prepare
  | Decode
  | Application

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

let stages = [ "prepare"; "decode"; "application" ]

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
  ; "reason", reasons
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
  ]
;;

let prefix = "authoritative-decode:v1:"
let detail_name = "authoritativeDiagnostic"
let signal_prefix = "worker.applyAuthoritative.authoritativeDecodeFailed:"
let maximum_counter = 1_000_000_000

let stage_name = function
  | Prepare -> "prepare"
  | Decode -> "decode"
  | Application -> "application"
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

let encode value = prefix ^ Yojson.Safe.to_string (`Assoc value)

let decode source =
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
                  | _ -> false)
               entries
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
  "Authoritative transaction rejected (" ^ String.concat "; " (List.map part value) ^ ")."
;;
