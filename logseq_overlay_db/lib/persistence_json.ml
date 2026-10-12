module Graph = Logseq_db_types.Graph_types

type task_status = Types.task_status =
  | Todo
  | Doing
  | In_review
  | Now
  | Done
  | Canceled
  | Backlog
  | Waiting
  | Later
[@@deriving yojson]

type block_reason = Types.block_reason =
  | Rejected
  | Stale_barrier
  | Dependency_blocked of Graph.Uuid.t
  | Authoritative_mismatch
  | Planner_dependency_changed
[@@deriving yojson]

type local_status = Types.local_status =
  | Applied
  | No_change
  | Already_applied
[@@deriving yojson]

type remote_won_reason = Types.remote_won_reason =
  | Before_submission
  | Proven_unexecuted
[@@deriving yojson]

type auxiliary_delete_fact = Types.auxiliary_delete_fact =
  | Comment_area
  | Default_property_holder
  | Rewritten_source_title
  | Timestamp
  | Transaction_metadata
[@@deriving yojson]

type delete_conflict_kind = Types.delete_conflict_kind =
  | Frontier_fact_changed
  | Descendant_closure_changed
  | Incoming_reference_changed
  | Auxiliary_write_footprint_changed of auxiliary_delete_fact
  | Page_lifecycle_changed
[@@deriving yojson]

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
