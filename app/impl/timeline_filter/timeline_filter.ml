module Uuid = Logseq_db_types.Graph_types.Uuid

type tag_id = Uuid.t
type status_id = Uuid.t
type unit_ = Days | Weeks
type preset = Past_14_days | Past_3_months
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

type preferences = { definitions : (string * criteria) list; selected_name : string option }
type preference_error = Empty_name | Duplicate_name | Name_too_long | Too_many_filters | Too_many_selections | Unknown_selection

let empty_preferences = { definitions = []; selected_name = None }
let definitions preferences = preferences.definitions
let selected_name preferences = preferences.selected_name

let preferences ~definitions ~selected_name =
  let rec validate seen = function
    | [] ->
      let definitions = List.rev seen in
      if Option.exists (fun name -> not (List.mem_assoc name definitions)) selected_name
      then Error Unknown_selection
      else Ok { definitions; selected_name }
    | (name, criteria) :: rest ->
      let name = String.trim name in
      if List.length seen = 5 then Error Too_many_filters
      else if name = "" then Error Empty_name
      else if String.length name > 128 || not (String.is_valid_utf_8 name) then Error Name_too_long
      else if List.mem_assoc name seen then Error Duplicate_name
      else if List.length criteria.tags > 100 || List.length criteria.statuses > 100
      then Error Too_many_selections
      else validate ((name, criteria) :: seen) rest
  in
  validate [] definitions
;;

type t = { applied : criteria; sheet : sheet option; preferences : preferences }

let restore preferences =
  let applied = Option.bind preferences.selected_name (fun name -> List.assoc_opt name preferences.definitions) in
  { applied = Option.value applied ~default:all; sheet = None; preferences }
;;

type entry = Configure_directly | Native_menu of { names : string list; active_name : string option }

let entry state =
  match state.preferences.definitions with
  | [] -> Configure_directly
  | definitions -> Native_menu { names = List.map fst definitions; active_name = state.preferences.selected_name }
;;

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

type command = Apply | Save_as of string | Select of string | Clear
type error = Invalid_time of time_error | Invalid_preferences of preference_error | No_open_sheet | Unknown_name
type transition = { next : t; replacement : preferences option }

let submit state command =
  let previous = state.preferences in
  let finish applied sheet preferences =
    Ok { next = { applied; sheet; preferences }
       ; replacement = (if preferences = previous then None else Some preferences) }
  in
  match command with
  | Clear -> finish all state.sheet { previous with selected_name = None }
  | Select name ->
    (match List.assoc_opt name previous.definitions with
     | None -> Error Unknown_name
     | Some applied -> finish applied state.sheet { previous with selected_name = Some name })
  | Apply | Save_as _ ->
    match state.sheet with
    | None -> Error No_open_sheet
    | Some sheet ->
      match validate_draft_time sheet with
      | Error error -> Error (Invalid_time error)
      | Ok time ->
        let applied = criteria ~tags:sheet.draft_tags ~statuses:sheet.draft_statuses ~time in
        if List.length applied.tags > 100 || List.length applied.statuses > 100
        then Error (Invalid_preferences Too_many_selections)
        else match command with
        | Apply -> finish applied None { previous with selected_name = None }
        | Save_as name ->
          let selected_name = Some (String.trim name) in
          (match preferences ~definitions:(previous.definitions @ [name, applied]) ~selected_name with
           | Ok preferences -> finish applied None preferences
           | Error error -> Error (Invalid_preferences error))
        | Clear | Select _ -> assert false
;;
