type phase =
  | Prepared
  | Local_committed
  | Uploading
  | Remote_stored
  | Metadata_pending
  | Complete
  | Cancelled
[@@deriving yojson]

type t =
  { operation_id : Graph_types.Uuid.t
  ; origin : string
  ; account : string
  ; graph : Graph_types.Uuid.t
  ; asset : Graph_types.Uuid.t
  ; version : Asset_descriptor.version
  ; title : string
  ; size : int64
  ; staged_file : string
  ; replace_reference : Graph_types.Uuid.t option
  ; target : Graph_types.Uuid.t
  ; local_mutation : Graph_types.Uuid.t
  ; metadata_mutation : Graph_types.Uuid.t
  ; phase : phase
  ; revision : int
  }

let prepare
      ~operation_id
      ~origin
      ~account
      ~graph
      ~asset
      ~version
      ~title
      ~size
      ~staged_file
      ~replace_reference
      ~target
      ~local_mutation
      ~metadata_mutation
  =
  if
    origin = ""
    || account = ""
    || String.trim title = ""
    || String.length title > 1024
    || (not (String.is_valid_utf_8 title))
    || String.contains title '\000'
    || size < 0L
    || size > 104857600L
    || staged_file = ""
    || staged_file <> Filename.basename staged_file
    || staged_file = "."
    || staged_file = ".."
    || replace_reference = Some asset
    || Graph_types.Uuid.equal local_mutation metadata_mutation
  then Error "Invalid asset upload intent"
  else
    Ok
      { operation_id
      ; origin
      ; account
      ; graph
      ; asset
      ; version
      ; title
      ; size
      ; staged_file
      ; replace_reference
      ; target
      ; local_mutation
      ; metadata_mutation
      ; phase = Prepared
      ; revision = 0
      }
;;

let advance t phase =
  let allowed =
    match t.phase, phase with
    | Prepared, Local_committed
    | Local_committed, Uploading
    | Uploading, Remote_stored
    | Remote_stored, Metadata_pending
    | Metadata_pending, Complete -> true
    | ( (Prepared | Local_committed | Uploading | Remote_stored | Metadata_pending)
      , Cancelled ) -> true
    | _ -> false
  in
  if (not allowed) || t.revision = max_int
  then Error "Invalid upload phase transition"
  else Ok { t with phase; revision = t.revision + 1 }
;;

let restore t ~phase ~revision =
  let minimum =
    match phase with
    | Prepared -> 0
    | Local_committed | Cancelled -> 1
    | Uploading -> 2
    | Remote_stored -> 3
    | Metadata_pending -> 4
    | Complete -> 5
  in
  if t.phase <> Prepared || t.revision <> 0 || revision < minimum || revision > 6
  then Error "Invalid persisted upload checkpoint"
  else Ok { t with phase; revision }
;;

module Pure_codec = struct
  let (let*)=Result.bind
  module Intent=struct type nonrec t=t let prepare=prepare let restore=restore end
  module Uuid=Graph_types.Uuid
  module Asset=Asset_descriptor


type asset_version =
  { checksum : string
  ; file_type : string
  }
[@@deriving yojson]

type checkpoint =
  { format_version : int
  ; operation_id : Uuid.t
  ; origin : string
  ; account : string
  ; graph : Uuid.t
  ; asset : Uuid.t
  ; version : asset_version
  ; title : string
  ; size : int64
  ; staged_file : string
  ; replace_reference : Uuid.t option
  ; target : Uuid.t
  ; local_mutation : Uuid.t
  ; metadata_mutation : Uuid.t
  ; phase : phase
  ; revision : int
  }
[@@deriving yojson]

let encode (i : Intent.t) =
  checkpoint_to_yojson
    { format_version = 1
    ; operation_id = i.operation_id
    ; origin = i.origin
    ; account = i.account
    ; graph = i.graph
    ; asset = i.asset
    ; version = { checksum = i.version.checksum; file_type = i.version.file_type }
    ; title = i.title
    ; size = i.size
    ; staged_file = i.staged_file
    ; replace_reference = i.replace_reference
    ; target = i.target
    ; local_mutation = i.local_mutation
    ; metadata_mutation = i.metadata_mutation
    ; phase = i.phase
    ; revision = i.revision
    }
  |> Yojson.Safe.to_string
;;

let decode payload =
  try
    if String.length payload > 8192
    then Error "Upload checkpoint exceeds size limit"
    else
      let* value =
        Json_codec.decode
          checkpoint_of_yojson
          (Yojson.Safe.from_string payload)
        |> Result.map_error (fun source ->
          let diagnostic = Failure_diagnostic.of_source
              ~operation:"restoreUploads" ~reason:"invalidContent" source in
          if Failure_diagnostic.source_class diagnostic = "unknown"
          then "Upload checkpoint shape is invalid"
          else Failure_diagnostic.encode diagnostic)
      in
      if value.format_version <> 1
      then Error "Unsupported upload checkpoint format"
      else
        let* version =
          Asset.version
            ~checksum:value.version.checksum
            ~file_type:value.version.file_type
          |> Result.map_error (fun _ -> "Upload checkpoint asset version is invalid")
        in
        let* prepared =
          Intent.prepare
            ~operation_id:value.operation_id
            ~origin:value.origin
            ~account:value.account
            ~graph:value.graph
            ~asset:value.asset
            ~version
            ~title:value.title
            ~size:value.size
            ~staged_file:value.staged_file
            ~replace_reference:value.replace_reference
            ~target:value.target
            ~local_mutation:value.local_mutation
            ~metadata_mutation:value.metadata_mutation
          |> Result.map_error (fun _ -> "Upload checkpoint intent is invalid")
        in
        Intent.restore prepared ~phase:value.phase ~revision:value.revision
        |> Result.map_error (fun _ -> "Upload checkpoint phase is invalid")
  with
  | Yojson.Json_error _ -> Error "Upload checkpoint JSON is invalid"
  | Failure _ | Invalid_argument _ -> Error "Upload checkpoint shape is invalid"
;;

end
