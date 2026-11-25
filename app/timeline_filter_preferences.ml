open Journal_timeline_filter.Timeline_filter

let startup_prefix = "JTF1"

let unwrap_startup payload =
  if not (String.starts_with ~prefix:startup_prefix payload) then [], payload else
  match String.index_from_opt payload (String.length startup_prefix) '\n' with
  | None -> [], payload
  | Some separator ->
    let offset = String.length startup_prefix in
    let snapshot = String.sub payload offset (separator - offset) in
    let config = String.sub payload (separator + 1) (String.length payload - separator - 1) in
    let entries =
      try match Yojson.Safe.from_string snapshot with `Assoc entries -> entries | _ -> []
      with Yojson.Json_error _ -> [] in
    entries, config
;;

exception Invalid_record of string

let decode text =
  let open Yojson.Safe.Util in
  let invalid message = raise (Invalid_record message) in
  let bounded limit = function
    | `List values when List.length values <= limit -> values
    | _ -> invalid "Invalid filter collection size"
  in
  let ids value = List.map (fun value ->
    match Uuid.of_string (to_string value) with Ok id -> id | Error message -> invalid message)
      (bounded 100 value) in
  let criteria_of_json value =
    let time = match member "time" value with
      | `String "any" -> any_time
      | `String "14-days" -> preset Past_14_days
      | `String "3-months" -> preset Past_3_months
      | `List [`Int count; `String unit_name] ->
        let unit_ = match unit_name with "days" -> Days | "weeks" -> Weeks | _ -> invalid "Invalid time unit" in
        (match custom ~count ~unit_ with Ok time -> time | Error Invalid_count -> invalid "Invalid time count")
      | _ -> invalid "Invalid relative time"
    in
    criteria ~tags:(ids (member "tags" value)) ~statuses:(ids (member "statuses" value)) ~time
  in
  try
    if String.length text > 512 * 1024 then invalid "Filter record exceeds 512 KiB";
    let value = Yojson.Safe.from_string text in
    match member "version" value with
    | `Int 1 -> Ok empty_preferences
    | `Int 2 ->
      let definitions = bounded 5 (member "definitions" value) |> List.map (fun item ->
        to_string (member "name" item), criteria_of_json item) in
      let selected_name = match member "selected" value with `Null -> None | value -> Some (to_string value) in
      (match preferences ~definitions ~selected_name with
       | Ok record -> Ok record
       | Error error -> Error (match error with
         | Empty_name -> "Empty filter name" | Duplicate_name -> "Duplicate filter name"
         | Name_too_long -> "Invalid filter name length or encoding" | Too_many_filters -> "Too many saved filters"
         | Too_many_selections -> "Too many filter selections" | Unknown_selection -> "Unknown selected filter"))
    | _ -> Error "Unsupported filter record version"
  with
  | Yojson.Json_error message | Type_error (message, _) | Invalid_record message -> Error message
;;

let encode record =
  let ids values = `List (List.map (fun id -> `String (Uuid.to_string id)) values) in
  let definition (name, value) =
    let time = match time_choice (time value) with
      | `Any_time -> `String "any"
      | `Preset Past_14_days -> `String "14-days"
      | `Preset Past_3_months -> `String "3-months"
      | `Custom (count, unit_) -> `List [`Int count; `String (match unit_ with Days -> "days" | Weeks -> "weeks")] in
    `Assoc ["name", `String name; "tags", ids (tags value); "statuses", ids (statuses value); "time", time]
  in
  let selected = Option.fold ~none:`Null ~some:(fun name -> `String name) (selected_name record) in
  Yojson.Safe.to_string (`Assoc ["version", `Int 2; "definitions", `List (List.map definition (definitions record)); "selected", selected])
;;
