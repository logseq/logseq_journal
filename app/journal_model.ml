type task_state =
  | No_status
  | Todo
  | Doing
  | In_review
  | Now
  | Done
  | Canceled
  | Backlog
  | Waiting
  | Later

type status_category =
  | Todo_category
  | Doing_category
  | Done_category
  | Later_category

let status_category = function
  | No_status -> None
  | Todo -> Some Todo_category
  | Doing | In_review | Now -> Some Doing_category
  | Done | Canceled -> Some Done_category
  | Backlog | Waiting | Later -> Some Later_category
;;

let status_name = function
  | No_status -> "No status"
  | Todo -> "Todo"
  | Doing -> "Doing"
  | In_review -> "In review"
  | Now -> "Now"
  | Done -> "Done"
  | Canceled -> "Canceled"
  | Backlog -> "Backlog"
  | Waiting -> "Waiting"
  | Later -> "Later"
;;

let status_default_value = function
  | No_status -> None
  | In_review -> Some "In Review"
  | status -> Some (status_name status)
;;

type t =
  { id : string
  ; page_id : string
  ; journal_day : int
  ; parent_id : string option
  ; sibling_order : string
  ; source : string
  ; task_state : task_state
  ; child_count : int
  ; creation_time : Journal_time.t
  ; revision : string
  ; last_mutation_id : string
  }

let create
      ~id
      ~page_id
      ~journal_day
      ~parent_id
      ~sibling_order
      ~source
      ~task_state
      ~child_count
      ~creation_time
      ~revision
      ~last_mutation_id
  =
  if not (Journal_validation.is_uuid id)
  then Error "Journal entry ID must be a UUID"
  else if not (Journal_validation.is_uuid page_id)
  then Error "Journal page ID must be a UUID"
  else if not (Journal_validation.is_journal_day journal_day)
  then Error "Journal day must be a valid YYYYMMDD date"
  else if
    match parent_id with
    | Some parent_id -> not (Journal_validation.is_uuid parent_id)
    | None -> false
  then Error "Journal parent ID must be a UUID"
  else if
    match parent_id with
    | Some parent_id -> String.equal id parent_id
    | None -> false
  then Error "Journal entry cannot be its own parent"
  else if
    String.equal sibling_order ""
    || String.length sibling_order > 512
    || (not (Journal_validation.is_valid_utf_8 sibling_order))
    || Journal_validation.contains_nul sibling_order
  then Error "Journal sibling order is invalid"
  else if child_count < 0
  then Error "Journal child count must not be negative"
  else if String.equal revision ""
  then Error "Journal revision must not be empty"
  else if not (Journal_validation.is_uuid last_mutation_id)
  then Error "Journal mutation ID must be a UUID"
  else (
    match Journal_validation.validate_block_source source with
    | Error error -> Error error
    | Ok () ->
      Ok
        { id
        ; page_id
        ; journal_day
        ; parent_id
        ; sibling_order
        ; source
        ; task_state
        ; child_count
        ; creation_time
        ; revision
        ; last_mutation_id
        })
;;

let id value = value.id
let page_id value = value.page_id
let parent_id value = value.parent_id
let sibling_order value = value.sibling_order
let source value = value.source
let task_state value = value.task_state
let child_count value = value.child_count
let creation_time value = value.creation_time
let journal_day value = value.journal_day
let revision value = value.revision
let last_mutation_id value = value.last_mutation_id

let with_child_count value ~child_count =
  if child_count < 0
  then Error "Journal child count must not be negative"
  else Ok { value with child_count }
;;
