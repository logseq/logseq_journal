module Ui = Journal_view
module Uuid = Logseq_db_types.Graph_types.Uuid
module V = Ui.View

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

let lui_source = function
  | Files -> `files
  | Photos -> `photos
  | Camera -> `camera
;;

(* [request] selects which picker arm a [file_picker] element should present.
   [staged] requests copy the pick into a temp file so the path outlives the
   picker's retained scope — needed when the selection is attached later
   (composer). *)
type request =
  { id : int
  ; source : source
  ; staged : bool
  }

let file_request ~id = { id; source = Files; staged = false }
let staged_request ~id ~source = { id; source; staged = true }

(* The picker token encodes the journal request so picked payloads carry the
   same routing information the extension used to attach itself. *)
let request_token (request : request) =
  Printf.sprintf
    "journal-import:%d:%s:%d"
    request.id
    (source_to_string request.source)
    (if request.staged then 1 else 0)
;;

let request_staged token =
  match String.split_on_char ':' token with
  | [ "journal-import"; _; _; staged ] -> staged = "1"
  | _ -> false
;;

(* Staged picks are journal-owned temp copies already, so the picker can
   release its retained file as soon as the first pick lands — echoing the
   request token as the completion prop does that. *)
let staged_completion request pending =
  match pending with
  | [] -> None
  | _ :: _ -> Some (request_token request, None)
;;

(* A picked asset held for a later import: the pick fields plus [token], which
   identifies the pending item for the remove affordance. *)
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

(* Import identities are random UUIDv4s, matching the UUIDs the retired Swift
   extension generated for each pick. *)
let uuid_v4 () =
  let bytes = Bytes.create 16 in
  (try
     let ic = open_in_bin "/dev/urandom" in
     really_input ic bytes 0 16;
     close_in ic
   with
   | _ -> ());
  Bytes.set bytes 6 (Char.chr (Char.code (Bytes.get bytes 6) land 0x0f lor 0x40));
  Bytes.set bytes 8 (Char.chr (Char.code (Bytes.get bytes 8) land 0x3f lor 0x80));
  let hex = Buffer.create 36 in
  Bytes.iteri
    (fun index byte ->
       if index = 4 || index = 6 || index = 8 || index = 10 then Buffer.add_char hex '-';
       Buffer.add_string hex (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents hex
;;

let fresh_uuid () = Uuid.of_string (uuid_v4 ())

let fresh_uuids () =
  match fresh_uuid (), fresh_uuid (), fresh_uuid () with
  | Ok asset, Ok local_mutation, Ok metadata_mutation ->
    Ok (asset, local_mutation, metadata_mutation)
  | _ -> Error "Unable to create an import identity; try again."
;;

(* [completion] reports an operation id for in-place imports; the picker
   retains the picked file under its *request* token, so the echo needs this
   operation -> request mapping recorded when the pick decodes. *)
let request_of_operation : (string, string) Hashtbl.t = Hashtbl.create 8

type picked_file =
  { request : string
  ; path : string
  ; title : string
  ; file_type : string
  }

(* The lui picker reports {"request":token,"files":[{path,name,content-type}]};
   journal keeps the extension-era naming (extension of [name] for [file_type]). *)
let decode_picked payload =
  try
    match Yojson.Basic.from_string payload with
    | `Assoc fields ->
      (match List.assoc_opt "request" fields, List.assoc_opt "files" fields with
       | Some ((`String _ | `Int _) as token), Some (`List (`Assoc file :: _)) ->
         let token_string =
           match token with
           | `String s -> s
           | `Int i -> string_of_int i
           | _ -> ""
         in
         let field key =
           match List.assoc_opt key file with
           | Some (`String value) -> Ok value
           | _ -> Error "Invalid attachment selection"
         in
         (match field "path", field "name" with
          | Ok path, Ok name ->
            Ok
              { request = token_string
              ; path
              ; title = name
              ; file_type =
                  String.lowercase_ascii
                    (String.sub
                       (Filename.extension name)
                       1
                       (max 0 (String.length (Filename.extension name) - 1)))
              }
          | _ -> Error "Invalid attachment selection")
       | _ -> Error "Invalid attachment selection")
    | _ -> Error "Invalid attachment selection"
  with
  | _ -> Error "Invalid attachment selection"
;;

let file_extension path =
  let ext = Filename.extension path in
  if String.length ext > 1
  then String.lowercase_ascii (String.sub ext 1 (String.length ext - 1))
  else "bin"
;;

(* Staged picks get an immediate journal-owned temp copy: the picker's own
   retained/temp files are released as soon as the completion token echoes. *)
let stage_copy path =
  let dest =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "journal-import-%s.%s" (uuid_v4 ()) (file_extension path))
  in
  try
    let ic = open_in_bin path in
    let length = in_channel_length ic in
    let contents = really_input_string ic length in
    close_in ic;
    let oc = open_out_bin dest in
    output_string oc contents;
    close_out oc;
    Ok dest
  with
  | _ -> Error "Unable to access the selected file. Please try again."
;;

let staged_of_pick (file : picked_file) ~source_file =
  match fresh_uuid (), fresh_uuids () with
  | Ok operation, Ok (asset, local_mutation, metadata_mutation) ->
    Ok
      { token = Uuid.to_string operation
      ; operation
      ; asset
      ; local_mutation
      ; metadata_mutation
      ; source_file
      ; title = file.title
      ; file_type = file.file_type
      }
  | _ -> Error "Unable to create an import identity; try again."
;;

let decode ~target ~replace_reference payload =
  match decode_picked payload, fresh_uuids () with
  | Ok file, Ok (asset, local_mutation, metadata_mutation) ->
    (match fresh_uuid () with
     | Error _ -> Error "Unable to create an import identity; try again."
     | Ok operation ->
       Hashtbl.replace request_of_operation (Uuid.to_string operation) file.request;
       Ok
         Logseq_db_types.Asset_import.
           { operation
           ; asset
           ; target
           ; replace_reference
           ; local_mutation
           ; metadata_mutation
           ; source_file = file.path
           ; title = file.title
           ; file_type = file.file_type
           })
  | Error message, _ -> Error message
  | _, Error message -> Error message
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
     | Some (`String "remove") ->
       (match List.assoc_opt "token" fields with
        | Some (`String token) -> Ok (Removed token)
        | _ -> Error "Invalid attachment selection")
     | _ ->
       (match decode_picked payload with
        | Error message -> Error message
        | Ok file ->
          if request_staged file.request
          then (
            match stage_copy file.path with
            | Error message -> Error message
            | Ok source_file ->
              Result.map (fun staged -> Picked staged) (staged_of_pick file ~source_file))
          else Error "Invalid attachment selection"))
  | _ -> Error "Invalid attachment selection"
;;

let is_dismissal payload =
  match decode_event payload with
  | Ok Dismissed -> true
  | _ -> false
;;

let is_error_dismissal payload =
  match
    try Yojson.Basic.from_string payload with
    | _ -> `Null
  with
  | `Assoc fields ->
    (match List.assoc_opt "action" fields with
     | Some (`String "error-dismissed") -> true
     | _ -> false)
  | _ -> false
;;

let emit_json on_select fields = on_select (Yojson.Basic.to_string (`Assoc fields))

let is_image_type file_type =
  List.mem
    file_type
    [ "jpg"; "jpeg"; "png"; "gif"; "webp"; "heic"; "heif"; "tiff"; "bmp" ]
;;

(* Pending strip: 48pt thumbnails (or a glyph) with a corner remove button,
   scrolled horizontally — the layout the extension's PendingCell produced. *)
let pending_chip ~on_select (item : staged) =
  let thumb =
    if is_image_type item.file_type
    then
      Lui_elements.file_image
        ~path:item.source_file
        ~max_pixel_size:96
        ~width:48
        ~height:48
        ~corner_radius:8
        []
    else Lui_elements.icon ~name:(Ui.journal_icon "doc") ~width:48 ~height:48 []
  in
  Lui_elements.overlay
    ~accessibility_identifier:("journal-asset-pending:" ^ item.token)
    [ Lui_elements.column
        ~gap:2
        ~width:56
        [ thumb
        ; Ui.mount
            (V.text
               ~style:
                 (Ui.Style.Text_style.create ~foreground:Ui.Style.Text_style.Secondary ())
               ~line_limit:1
               item.title)
        ]
    ; Lui_elements.align
        `top_trailing
        (Lui_elements.button
           ~icon:(Ui.journal_icon "xmark.circle.fill")
           ~accessibility_identifier:("journal-asset-remove:" ^ item.token)
           ~on_press:(fun _ ->
             emit_json
               on_select
               [ "action", `String "remove"; "token", `String item.token ])
           [])
    ]
;;

let view ~key ~enabled ~completion ~replacement:_ ~request ~pending ~on_select body =
  let token = request_token request in
  (* The completion prop echoes the picker's request token: staged picks
     report the token directly, in-place imports resolve it through the
     operation id recorded at pick time. *)
  let completion_token =
    Option.bind completion (fun (value, _) ->
      if request.staged then Some value else Hashtbl.find_opt request_of_operation value)
  in
  let picker =
    Lui_elements.file_picker
      ~source:(lui_source request.source)
      ?request:(if request.id > 0 then Some (`String token) else None)
      ?types:
        (match request.source with
         | Files -> None
         | Photos | Camera -> Some "public.image")
      ~disabled:(not enabled)
      ?completion:(Option.map (fun t -> `String t) completion_token)
      ~on_picked:(fun event ->
        match event with
        | Lui_protocol.Picked (_, payload) -> on_select payload
        | _ -> ())
      ~on_dismiss:(fun _ -> emit_json on_select [ "action", `String "dismissed" ])
      []
  in
  let content =
    Lui_elements.column
      ~gap:8
      ((match pending with
        | [] -> []
        | pending ->
          [ Lui_elements.scroll
              ~orientation:`horizontal
              ~height:72
              [ Lui_elements.row
                  ~gap:12
                  ~padding_horizontal:4
                  (List.map (pending_chip ~on_select) pending)
              ]
          ])
       @ [ Ui.mount (V.Body.Private.to_widget body) ])
  in
  let alert =
    match completion with
    | Some (_, Some message) ->
      Some
        (Lui_elements.dialog
           ~text:"Unable to import file"
           ~description:message
           ~on_dismiss:(fun _ ->
             emit_json on_select [ "action", `String "error-dismissed" ])
           [ Lui_elements.button
               ~text:"OK"
               ~on_press:(fun _ ->
                 emit_json on_select [ "action", `String "error-dismissed" ])
               []
           ])
    | _ -> None
  in
  Ui.element ~key (fun context parent ->
    let node = content context parent in
    ignore (picker context (Some node));
    Option.iter (fun alert -> ignore (alert context (Some node))) alert;
    node)
;;
