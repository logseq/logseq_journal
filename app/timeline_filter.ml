module Uuid = Logseq_db_types.Graph_types.Uuid

type tag_id = Uuid.t
type status_id = Uuid.t
type unit_ = Days | Weeks
type preset = Past_7_days | Past_2_weeks
type relative_time = [ `Any_time | `Preset of preset | `Custom of int * unit_ ]
type time_error = Invalid_count

let any_time = `Any_time
let preset value = `Preset value

let custom ~count ~unit_ =
  let multiplier = match unit_ with Days -> 1 | Weeks -> 7 in
  if count <= 0 || count > max_int / multiplier
  then Error Invalid_count
  else Ok (`Custom (count, unit_))
;;

let time_choice time = time

type criteria = { tags : tag_id list; statuses : status_id list; time : relative_time }

let criteria ~tags ~statuses ~time =
  { tags = List.sort_uniq Uuid.compare tags; statuses = List.sort_uniq Uuid.compare statuses; time }
;;

let all = criteria ~tags:[] ~statuses:[] ~time:any_time
let tags criteria = criteria.tags
let statuses criteria = criteria.statuses
let time criteria = criteria.time

let active_count criteria =
  Bool.to_int (criteria.tags <> [])
  + Bool.to_int (criteria.statuses <> [])
  + Bool.to_int (criteria.time <> any_time)
;;

type time_control = Any_time | Preset of preset | Custom of { count_text : string; unit_ : unit_ }
type sheet = { draft_tags : tag_id list; draft_statuses : status_id list; draft_time : time_control }
type t = { applied : criteria; sheet : sheet option }

let restore applied = { applied; sheet = None }
let initial = restore all
let applied state = state.applied
let sheet state = state.sheet
let draft_tags sheet = sheet.draft_tags
let draft_statuses sheet = sheet.draft_statuses
let draft_time sheet = sheet.draft_time

let validate_draft_time sheet =
  match sheet.draft_time with
  | Any_time -> Ok any_time
  | Preset value -> Ok (preset value)
  | Custom { count_text; unit_ } ->
    if not (String.for_all (function '0' .. '9' -> true | _ -> false) count_text)
    then Error Invalid_count
    else (
      match int_of_string_opt count_text with
      | None -> Error Invalid_count
      | Some count -> custom ~count ~unit_)
;;

let draft criteria =
  let draft_time =
    match time_choice criteria.time with
    | `Any_time -> Any_time
    | `Preset value -> Preset value
    | `Custom (count, unit_) -> Custom { count_text = string_of_int count; unit_ }
  in
  { draft_tags = criteria.tags; draft_statuses = criteria.statuses; draft_time }
;;

let open_sheet state =
  match state.sheet with Some _ -> state | None -> { state with sheet = Some (draft state.applied) }
;;

type edit = Toggle_tag of tag_id | Toggle_status of status_id | Set_time of time_control | Reset

let toggle id ids =
  if List.exists (Uuid.equal id) ids
  then List.filter (fun candidate -> not (Uuid.equal id candidate)) ids
  else id :: ids
;;

let edit state change =
  match state.sheet with
  | None -> state
  | Some sheet ->
    let sheet =
      match change with
      | Toggle_tag id -> { sheet with draft_tags = toggle id sheet.draft_tags }
      | Toggle_status id -> { sheet with draft_statuses = toggle id sheet.draft_statuses }
      | Set_time draft_time -> { sheet with draft_time }
      | Reset -> draft all
    in
    { state with sheet = Some sheet }
;;

let cancel state = { state with sheet = None }

let apply state =
  match state.sheet with
  | None -> Ok state
  | Some sheet ->
    Result.map
      (fun time -> restore (criteria ~tags:sheet.draft_tags ~statuses:sheet.draft_statuses ~time))
      (validate_draft_time sheet)
;;
