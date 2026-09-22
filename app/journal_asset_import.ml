module Ui = Bonsai_swiftui_ui
module Uuid = Logseq_db_types.Graph_types.Uuid

let decode ~target payload =
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
         | Some `Null -> Ok None
         | Some (`String id) -> Result.map Option.some (Uuid.of_string id)
         | _ -> Error "Invalid replacement reference")
      | _ -> Error "Invalid attachment selection"
    in
    let* source_file = field "path" in
    let* title = field "title" in
    let* file_type = field "type" in
    Ok
      Logseq_db_types.Asset_import.
        { operation
        ; asset
        ; target
        ; replace_reference
        ; local_mutation
        ; metadata_mutation
        ; source_file
        ; title
        ; file_type
        }
  with
  | _ -> Error "Invalid attachment selection"
;;

let extension =
  Ui.Native_widget.Extension.create
    ~kind_id:(Bonsai_swiftui_spec.Id.Native_widget.Kind_id.of_int 2104)
    ~version:1
    ~capabilities:[ Stateful; Resource; Semantics ]
    ~encode_props:(fun props -> Bytes.of_string (Yojson.Basic.to_string props))
    ~decode_event:(fun ~event_id:_ bytes -> Ok (Bytes.to_string bytes))
    ()
;;

let is_dismissal payload =
  match (try Yojson.Basic.from_string payload with _ -> `Null) with
  | `Assoc fields ->
    (match List.assoc_opt "action" fields with
     | Some (`String "dismissed") -> true
     | _ -> false)
  | _ -> false
;;

let view ~key ~enabled ~completion ~replacement ~request ~on_select =
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
          ; "request", `Int request
          ])
    ~on_event:on_select
    ~children:[]
    ()
;;
