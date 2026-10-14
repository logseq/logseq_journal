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

type t =
  { id : string
  ; page_id : string
  ; journal_day : int option
  ; parent_id : string option
  ; sibling_order : string
  ; source : string
  ; asset_file_type : string option
  ; properties : Logseq_db_types.Graph_types.property_summary list
  ; display_properties : Logseq_db_types.Graph_types.property_summary list
  ; task_state : task_state
  ; tag_titles : string list
  ; tags_present : bool
  ; attachments_present : bool
  ; child_count : int
  ; creation_time : Journal_time.t
  ; revision : string
  ; last_mutation_id : string
  }

let create_on_page
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
  else if
    Option.fold
      ~none:false
      ~some:(fun day -> not (Journal_validation.is_journal_day day))
      journal_day
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
        ; asset_file_type = None
        ; properties = []
        ; display_properties = []
        ; task_state
        ; tag_titles = []
        ; tags_present = false
        ; attachments_present = false
        ; child_count
        ; creation_time
        ; revision
        ; last_mutation_id
        })
;;

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
  create_on_page
    ~id
    ~page_id
    ~journal_day:(Some journal_day)
    ~parent_id
    ~sibling_order
    ~source
    ~task_state
    ~child_count
    ~creation_time
    ~revision
    ~last_mutation_id
;;

let id value = value.id
let page_id value = value.page_id
let parent_id value = value.parent_id
let sibling_order value = value.sibling_order
module Graph = Logseq_db_types.Graph_types

let reference uuid = "[[" ^ Graph.Uuid.to_string uuid ^ "]]"

let rec internal_source = function
  | Graph.Internal_null -> ""
  | Internal_bool value -> if value then "Yes" else "No"
  | Internal_number value | Internal_string value | Internal_keyword value -> value
  | Internal_uuid uuid -> reference uuid
  | Internal_list values -> String.concat ", " (List.map internal_source values)
  | Internal_map values -> String.concat ", " (List.map (fun (key,value) ->
      internal_source key ^ ": " ^ internal_source value) values)
;;

let datetime_source ~localtime unix_ms =
  let (tm : Unix.tm) = localtime (Int64.to_float unix_ms /. 1000.) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d"
    (tm.tm_year+1900) (tm.tm_mon+1) tm.tm_mday tm.tm_hour tm.tm_min
;;

let property_source ~localtime = function
  | Graph.Checkbox_value value -> if value then "Yes" else "No"
  | Default_value value ->
    (match Graph.Uuid.of_string value with Ok uuid -> reference uuid | Error _ -> value)
  | String_value value | Url_value value | Number_value value | Raw_number_value value
  | Keyword_value value | Property_value value | Json_value value -> value
  | Node_value uuid | Asset_value uuid | Entity_value uuid | Class_value uuid
  | Page_value uuid -> reference uuid
  | Date_value {journal_day} -> Printf.sprintf "%04d-%02d-%02d"
      (journal_day / 10000) ((journal_day / 100) mod 100) (journal_day mod 100)
  | Datetime_value {unix_ms} ->
    datetime_source ~localtime unix_ms
  | Any_value value -> internal_source value
  | Map_value values -> internal_source (Internal_map values)
  | Collection_value values -> internal_source (Internal_list values)
;;

let property_sources ?(localtime = Unix.localtime) properties =
  List.filter_map (fun (p : Graph.property_summary) ->
    if p.schema.hidden || p.ident = "logseq.property/status" || p.ident = "block/tags" || p.values = [] then None
    else
      let render = function
        | Graph.Default_value "logseq.property/priority.low" when p.ident = "logseq.property/priority" -> "Low"
        | Default_value "logseq.property/priority.medium" when p.ident = "logseq.property/priority" -> "Medium"
        | Default_value "logseq.property/priority.high" when p.ident = "logseq.property/priority" -> "High"
        | Default_value "logseq.property/priority.urgent" when p.ident = "logseq.property/priority" -> "Urgent"
        | value -> property_source ~localtime value
      in
      let values = List.map render p.values |> List.filter (fun s -> String.trim s <> "") in
      if values = [] then None
      else Some (p.title, String.concat ", " values ^ if p.values_truncated then " …" else "")) properties
;;

let source value =
  if String.trim value.source <> "" then value.source else
  List.find_map (fun (p : Graph.property_summary) ->
    if p.ident = "logseq.property/value" then
      Some (String.concat ", " (List.map (property_source ~localtime:Unix.localtime) p.values)) else None)
    value.display_properties |> Option.value ~default:value.source
let properties value = value.properties
let display_properties value = value.display_properties
let with_properties ?(localtime = Unix.localtime) value ~properties =
  let display_properties = List.map (fun (p : Graph.property_summary) ->
    {p with values=List.map (function
      | Graph.Datetime_value {unix_ms} -> Graph.String_value (datetime_source ~localtime unix_ms)
      | value -> value) p.values}) properties in
  {value with properties; display_properties}
;;

let is_image_file_type value =
  match String.lowercase_ascii (String.trim value) with
  | "png"
  | "jpg"
  | "jpeg"
  | "gif"
  | "webp"
  | "heic"
  | "heif"
  | "tif"
  | "tiff"
  | "bmp"
  | "avif" -> true
  | _ -> false
;;

let asset_file_type value = value.asset_file_type
let with_asset_file_type value ~asset_file_type = { value with asset_file_type }
let has_tags value = value.tags_present || value.tag_titles <> []

let has_attachments value =
  value.attachments_present
  || Option.fold ~none:false ~some:(fun t -> String.trim t <> "") value.asset_file_type
;;

let with_content_metadata value ~tags_present ~attachments_present =
  { value with tags_present; attachments_present }
;;

let task_state value = value.task_state
let child_count value = value.child_count
let creation_time value = value.creation_time
let journal_day_opt value = value.journal_day

let journal_day value =
  match value.journal_day with
  | Some day -> day
  | None -> invalid_arg "Non-journal block in journal feed"
;;

let revision value = value.revision
let last_mutation_id value = value.last_mutation_id

let with_child_count value ~child_count =
  if child_count < 0
  then Error "Journal child count must not be negative"
  else Ok { value with child_count }
;;

let tag_titles value = value.tag_titles

let with_tag_titles value ~tag_titles =
  { value with
    tag_titles = List.filter (fun title -> String.trim title <> "") tag_titles
  }
;;

(* The literal-text renderer recognizes only exact UUID links. Scanning is linear
   in source bytes, with the same validator used for block identity. *)
let fold_references source ~init ~f =
  let length = String.length source in
  let rec scan offset acc =
    if offset >= length
    then acc
    else if source.[offset] = '\\'
    then scan (min length (offset + 2)) acc
    else if
      offset + 40 <= length
      && source.[offset] = '['
      && source.[offset + 1] = '['
      && source.[offset + 38] = ']'
      && source.[offset + 39] = ']'
    then (
      let id = String.sub source (offset + 2) 36 in
      if Journal_validation.is_uuid id
      then scan (offset + 40) (f acc offset (String.lowercase_ascii id))
      else scan (offset + 1) acc)
    else scan (offset + 1) acc
  in
  scan 0 init
;;

let reference_ids source =
  let seen = Hashtbl.create 8 in
  fold_references source ~init:[] ~f:(fun ids _ id ->
    if Hashtbl.mem seen id
    then ids
    else (
      Hashtbl.add seen id ();
      id :: ids))
  |> List.rev
;;

let maximum_reference_depth = 16

let render_references ~lookup source =
  let remaining = ref 256 in
  let rec expand path depth source =
    let output = Buffer.create (min 65536 (String.length source)) in
    let copied = ref 0
    and cyclic = ref false in
    fold_references source ~init:() ~f:(fun () offset id ->
      Buffer.add_substring output source !copied (offset - !copied);
      let replacement =
        if List.mem id path
        then (
          cyclic := true;
          None)
        else if depth >= maximum_reference_depth || !remaining = 0
        then None
        else (
          match lookup id with
          | None -> None
          | Some target ->
            decr remaining;
            let result = expand (id :: path) (depth + 1) target in
            if Option.is_none result then cyclic := true;
            result)
      in
      (* Reserve space for the literal suffix, so a large expansion falls back
         to its original token without truncating the surrounding source. *)
      let replacement =
        Option.bind replacement (fun text ->
          if
            Buffer.length output + String.length text + String.length source - offset - 40
            <= 65536
          then Some text
          else None)
      in
      (match replacement with
       | Some text -> Buffer.add_string output text
       | None -> Buffer.add_substring output source offset 40);
      copied := offset + 40);
    Buffer.add_substring output source !copied (String.length source - !copied);
    if !cyclic && depth > 0 then None else Some (Buffer.contents output)
  in
  Option.value (expand [] 0 source) ~default:source
;;
