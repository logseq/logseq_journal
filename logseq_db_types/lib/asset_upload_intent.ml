type phase =
  | Prepared
  | Local_committed
  | Uploading
  | Remote_stored
  | Metadata_pending
  | Complete
  | Cancelled

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
