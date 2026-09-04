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
