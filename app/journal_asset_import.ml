module Ui = Journal_view
module Uuid = Logseq_db_types.Graph_types.Uuid

type source =
  | Files
  | Photos
  | Camera

let source_to_string = function
  | Files -> "files"
  | Photos -> "photos"
  | Camera -> "camera"
;;

(* [request] mirrors the extension's request prop; [staged] requests copy the
   pick into a temp file on the host so the path outlives the picker's
   security scope — needed when the selection is attached later (composer). *)
type request =
  { id : int
  ; source : source
  ; staged : bool
  ; max_selections : int option
  }

let file_request ~id = { id; source = Files; staged = false; max_selections = Some 1 }

let staged_request ?max_selections ~id ~source () =
  { id; source; staged = true; max_selections }
;;

(* A picked asset held for a later import: the wire pick fields plus [token],
   which identifies the pending item for the extension's remove event. *)
type staged =
  { token : string
  ; operation : Uuid.t
  ; asset : Uuid.t
  ; local_mutation : Uuid.t
  ; metadata_mutation : Uuid.t
  ; source_file : string
  ; title : string
  ; file_type : string
  ; source_identity : string option
  }

let staged_token (staged : staged) = staged.token
let staged_path (staged : staged) = staged.source_file
let staged_title (staged : staged) = staged.title
let staged_type (staged : staged) = staged.file_type
let staged_source_identity (staged : staged) = staged.source_identity

module Json = struct
  type request = { id : int; source : string option [@default None]; staged : bool option [@default None]; maxSelections : int option [@default None] }
  [@@deriving yojson]
  type pick =
    { operation : string; asset : string; localMutation : string; metadataMutation : string
    ; path : string; title : string; file_type : string [@key "type"]; sourceIdentity : string option [@default None] }
  [@@deriving yojson]
  type event =
    { action : string; selection : pick option [@default None]; items : pick list option [@default None]; request : request option [@default None]
    ; error : string option [@default None]; reason : string option [@default None]; token : string option [@default None] }
  [@@deriving yojson]
  type pending =
    { token : string; path : string; title : string; file_type : string [@key "type"]
    ; sourceIdentity : string option [@default None] }
  [@@deriving yojson]
  type props =
    { enabled : bool; completion : string option [@default None]; error : string option [@default None]
    ; request : request; pending : pending list }
  [@@deriving yojson]
end

let read_event payload =
  try
    Logseq_db_types.Json_codec.decode Json.event_of_yojson (Yojson.Safe.from_string payload)
    |> Result.map_error (function
      | ("invalid UTF-8 field name" | "duplicate JSON field" | "invalid UTF-8 string"
        | "non-finite JSON number" | "nonstandard JSON value" | "JSON exceeds byte budget"
        | "invalid JSON value") as source -> source
      | _ -> "Native event shape is invalid")
  with Yojson.Json_error _ -> Error "Native event JSON syntax is invalid"
;;

let staged_of_pick (pick : Json.pick) =
  let ( let* ) = Result.bind in
  let uuid text = Result.map_error (fun _ -> "Invalid import identity") (Uuid.of_string text) in
  let* operation = uuid pick.operation in
  let* asset = uuid pick.asset in
  let* local_mutation = uuid pick.localMutation in
  let* metadata_mutation = uuid pick.metadataMutation in
  Ok
    { token = Uuid.to_string operation; operation; asset; local_mutation; metadata_mutation
    ; source_file = pick.path; title = pick.title; file_type = pick.file_type
    ; source_identity = pick.sourceIdentity }
;;

let picked (wire : Json.event) =
  let ( let* ) = Result.bind in
  match wire.action, wire.selection with
  | "picked", Some selection ->
    let* staged = staged_of_pick selection in
    Ok (staged, Option.map (fun (request : Json.request) -> request.id) wire.request)
  | _ -> Error "Invalid attachment selection"
;;

let to_import (staged : staged) ~target : Logseq_db_types.Asset_import.t =
  { operation = staged.operation
  ; asset = staged.asset
  ; target
  ; replace_reference = None
  ; local_mutation = staged.local_mutation
  ; metadata_mutation = staged.metadata_mutation
  ; source_file = staged.source_file
  ; title = staged.title
  ; file_type = staged.file_type
  }
;;

let decode ~target payload =
  let ( let* ) = Result.bind in
  let* wire = read_event payload in
  let* staged, _ = picked wire in
  Ok (to_import staged ~target)
;;

type event =
  | Picked of staged * int option
  | Picked_batch of staged list * int option * string option
  | Removed of string
  | Dismissed
  | Picker_dismissed of int option
  | Unavailable of string

let decode_event payload =
  let ( let* ) = Result.bind in
  let* wire = read_event payload in
  let request_id = Option.map (fun (request : Json.request) -> request.id) wire.request in
  match wire.action with
  | "picked" -> Result.map (fun (staged, id) -> Picked (staged, id)) (picked wire)
  | "picked-batch" ->
    (match wire.items with
     | None -> Error "Invalid attachment batch"
     | Some items ->
       let rec decode reversed = function
         | [] -> Ok (Picked_batch (List.rev reversed, request_id, wire.error))
         | pick :: rest ->
           let* staged = staged_of_pick pick in
           decode (staged :: reversed) rest
       in
       decode [] items)
  | "dismissed" -> Ok (match request_id with None -> Dismissed | Some _ -> Picker_dismissed request_id)
  | "unavailable" ->
    (match wire.reason with Some reason -> Ok (Unavailable reason) | None -> Error "Invalid attachment source")
  | "remove" ->
    (match wire.token with Some token -> Ok (Removed token) | None -> Error "Invalid attachment selection")
  | _ -> Error "Invalid attachment action"
;;

let extension =
  Ui.Native_widget.Extension.create
    ~kind_id:(Journal_ids.Native_widget.Kind_id.of_int 2104)
    ~encode_props:(fun props -> Json.props_to_yojson props |> Yojson.Safe.to_string |> Bytes.of_string)
    ~decode_event:(fun ~event_id:_ bytes -> Ok (Bytes.to_string bytes))
    ()
;;

(* Staged picks live under the host temp directory as [journal-import-*];
   delete only files matching that contract so a user path is never removed. *)
let discard_staged_file (staged : staged) =
  if String.starts_with ~prefix:"journal-import-" (Filename.basename staged.source_file)
  then (
    try Sys.remove staged.source_file with
    | _ -> ())
;;

let is_dismissal payload =
  match decode_event payload with
  | Ok Dismissed | Ok (Picker_dismissed _) -> true
  | _ -> false
;;

let view ~key ~enabled ~completion ~request ~pending ~on_select body =
  let completion, error = match completion with None -> None, None | Some (operation, error) -> Some operation, error in
  let wire_request : Json.request =
    { id = request.id; source = Some (source_to_string request.source); staged = Some request.staged
    ; maxSelections = request.max_selections }
  in
  Ui.Native_widget.widget extension ~key
    ~props:Json.
      { enabled; completion; error; request = wire_request
      ; pending = List.map (fun (item : staged) ->
          { token = item.token; path = item.source_file; title = item.title
          ; file_type = item.file_type; sourceIdentity = item.source_identity }) pending }
    ~on_event:on_select ~children:[ Ui.View.Body.Private.to_widget body ] ()
;;
