module Graph = Logseq_db_types.Graph_types

let uuid_to_yojson uuid = `String (Graph.Uuid.to_string uuid)

let uuid_of_yojson = function
  | `String value -> Graph.Uuid.of_string value
  | _ -> Error "UUID is not a string"
;;

let task_status_to_string = function
  | Types.Todo -> "todo"
  | Doing -> "doing"
  | In_review -> "in-review"
  | Now -> "now"
  | Done -> "done"
  | Canceled -> "canceled"
  | Backlog -> "backlog"
  | Waiting -> "waiting"
  | Later -> "later"
;;

let task_status_of_string = function
  | "todo" -> Ok Types.Todo
  | "doing" -> Ok Doing
  | "in-review" -> Ok In_review
  | "now" -> Ok Now
  | "done" -> Ok Done
  | "canceled" -> Ok Canceled
  | "backlog" -> Ok Backlog
  | "waiting" -> Ok Waiting
  | "later" -> Ok Later
  | _ -> Error "invalid task status"
;;

let optional_of_yojson decode = function
  | `Null -> Ok None
  | value -> Result.map Option.some (decode value)
;;

let optional_to_yojson encode = function
  | None -> `Null
  | Some value -> encode value
;;

let block_reason_to_yojson = function
  | Types.Rejected -> `String "rejected"
  | Stale_barrier -> `String "staleBarrier"
  | Dependency_blocked mutation_id ->
    `Assoc
      [ "mutationId", uuid_to_yojson mutation_id; "type", `String "dependencyBlocked" ]
  | Authoritative_mismatch -> `String "authoritativeMismatch"
  | Planner_dependency_changed -> `String "plannerDependencyChanged"
;;

let block_reason_of_yojson = function
  | `String "rejected" -> Ok Types.Rejected
  | `String "staleBarrier" -> Ok Types.Stale_barrier
  | `Assoc [ ("mutationId", mutation_id); ("type", `String "dependencyBlocked") ] ->
    Result.map
      (fun mutation_id -> Types.Dependency_blocked mutation_id)
      (uuid_of_yojson mutation_id)
  | `String "authoritativeMismatch" -> Ok Types.Authoritative_mismatch
  | `String "plannerDependencyChanged" -> Ok Types.Planner_dependency_changed
  | _ -> Error "invalid block reason"
;;

let server_cursor_to_string cursor =
  "server-cursor:v1:" ^ Int64.to_string (Types.Server_cursor.to_int64 cursor)
;;

let server_cursor_of_string value =
  let prefix = "server-cursor:v1:" in
  let length = String.length prefix in
  if String.length value <= length || String.sub value 0 length <> prefix
  then Error "invalid server cursor token version"
  else (
    let digits = String.sub value length (String.length value - length) in
    if
      not
        (String.for_all
           (function
             | '0' .. '9' -> true
             | _ -> false)
           digits)
    then Error "invalid server cursor number"
    else (
      match Int64.of_string_opt digits with
      | None -> Error "server cursor overflows int64"
      | Some value ->
        Types.Server_cursor.of_int64 value
        |> Result.map_error (fun `Negative_cursor -> "negative server cursor")))
;;
