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

let source_of_string = function
  | "files" -> Some Files
  | "photos" -> Some Photos
  | "camera" -> Some Camera
  | _ -> None
;;

(* [request] mirrors the extension's request prop; [staged] requests copy the
   pick into a temp file on the host so the path outlives the picker's
   security scope — needed when the selection is attached later (composer). *)
type request =
  { id : int
  ; source : source
  ; staged : bool
  }

let file_request ~id = { id; source = Files; staged = false }
let staged_request ~id ~source = { id; source; staged = true }

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
  }

let staged_token (staged : staged) = staged.token
let staged_path (staged : staged) = staged.source_file
let staged_title (staged : staged) = staged.title
let staged_type (staged : staged) = staged.file_type

let parse payload =
  let ( let* ) = Result.bind in
  try
    let json = Yojson.Basic.from_string payload in
    let field key =
      match Yojson.Basic.Util.member key json with
      | `String value -> Ok value
      | _ -> Error "Invalid attachment selection"
    in
    let uuid key =
      let* text = field key in
      Result.map_error (fun _ -> "Invalid import identity") (Uuid.of_string text)
    in
    let* operation = uuid "operation" in
    let* asset = uuid "asset" in
    let* local_mutation = uuid "localMutation" in
    let* metadata_mutation = uuid "metadataMutation" in
    let* replace_reference =
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "replaceReference" fields with
         | Some `Null | Some (`String "") -> Ok None
         | Some (`String id) -> Result.map Option.some (Uuid.of_string id)
         | _ -> Error "Invalid replacement reference")
      | _ -> Error "Invalid attachment selection"
    in
    let* source_file = field "path" in
    let* title = field "title" in
    let* file_type = field "type" in
    Ok
      ( { token = Uuid.to_string operation
        ; operation
        ; asset
        ; local_mutation
        ; metadata_mutation
        ; source_file
        ; title
        ; file_type
        }
      , replace_reference )
  with
  | _ -> Error "Invalid attachment selection"
;;

let decode ~target payload =
  Result.map
    (fun ((pick : staged), replace_reference) ->
       Logseq_db_types.Asset_import.
         { operation = pick.operation
         ; asset = pick.asset
         ; target
         ; replace_reference
         ; local_mutation = pick.local_mutation
         ; metadata_mutation = pick.metadata_mutation
         ; source_file = pick.source_file
         ; title = pick.title
         ; file_type = pick.file_type
         })
    (parse payload)
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

type event =
  | Picked of staged
  | Removed of string
  | Dismissed
  | Unavailable of string

let decode_event payload =
  match
    try Yojson.Basic.from_string payload with
    | _ -> `Null
  with
  | `Assoc fields ->
    (match List.assoc_opt "action" fields with
     | Some (`String "dismissed") -> Ok Dismissed
     | Some (`String "unavailable") ->
       Ok
         (Unavailable
            (match List.assoc_opt "reason" fields with
             | Some (`String reason) -> reason
             | _ -> "This attachment source is not available."))
     | Some (`String "remove") ->
       (match List.assoc_opt "token" fields with
        | Some (`String token) -> Ok (Removed token)
        | _ -> Error "Invalid attachment selection")
     | _ -> Result.map (fun (staged, _) -> Picked staged) (parse payload))
  | _ -> Error "Invalid attachment selection"
;;

let extension =
  Ui.Native_widget.Extension.create
    ~kind_id:(Journal_ids.Native_widget.Kind_id.of_int 2104)
    ~version:1
    ~capabilities:[ Stateful; Resource; Semantics ]
    ~encode_props:(fun props -> Bytes.of_string (Yojson.Basic.to_string props))
    ~decode_event:(fun ~event_id:_ bytes -> Ok (Bytes.to_string bytes))
    ()
;;

let is_dismissal payload =
  match decode_event payload with
  | Ok Dismissed -> true
  | _ -> false
;;

let view ~key ~enabled ~completion ~replacement ~request ~pending ~on_select body =
  let operation, error =
    match completion with
    | None -> `Null, `Null
    | Some (operation, error) ->
      ( `String operation
      , (match error with
         | None -> `Null
         | Some message -> `String message) )
  in
  Ui.Native_widget.widget
    extension
    ~key
    ~props:
      (`Assoc
          [ "enabled", `Bool enabled
          ; "completion", operation
          ; "error", error
          ; ( "replace"
            , match replacement with
              | None -> `Null
              | Some root -> `String root )
          ; ( "request"
            , `Assoc
                [ "id", `Int request.id
                ; "source", `String (source_to_string request.source)
                ; "staged", `Bool request.staged
                ] )
          ; ( "pending"
            , `List
                (List.map
                   (fun (item : staged) ->
                      `Assoc
                        [ "token", `String item.token
                        ; "path", `String item.source_file
                        ; "title", `String item.title
                        ; "type", `String item.file_type
                        ])
                   pending) )
          ])
    ~on_event:on_select
    ~children:[ Ui.View.Body.Private.to_widget body ]
    ()
;;
