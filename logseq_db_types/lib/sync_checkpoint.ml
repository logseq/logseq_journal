type status =
  | Active
  | Paused

type t =
  { format_version : int
  ; graph_id : Graph_types.Uuid.t
  ; schema : Graph_types.schema_version
  ; applied_server_t : int
  ; checksum : string
  ; status : status
  ; last_error : string option
  }

let format_version = 2

let valid_checksum value =
  String.length value = 16
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let create_full ~graph_id ~schema ~applied_server_t ~checksum ~status ~last_error =
  if schema.Graph_types.major < 0 || schema.minor < 0
  then Error "sync schema version must be non-negative"
  else if applied_server_t < 0
  then Error "applied server t must be non-negative"
  else if not (valid_checksum checksum)
  then Error "sync checksum must be 16 lowercase hexadecimal characters"
  else if status = Active && Option.is_some last_error
  then Error "active sync metadata must not contain an error"
  else if
    status = Paused
    &&
    match last_error with
    | None -> true
    | Some value -> String.length value = 0
  then Error "paused sync metadata must contain an error"
  else if
    Option.fold ~none:false ~some:(fun value -> String.length value > 4096) last_error
  then Error "sync error exceeds its byte budget"
  else
    Ok
      { format_version; graph_id; schema; applied_server_t; checksum; status; last_error }
;;

let create ~graph_id ~schema ~applied_server_t ~checksum =
  create_full
    ~graph_id
    ~schema
    ~applied_server_t
    ~checksum
    ~status:Active
    ~last_error:None
;;

let equal left right =
  left.format_version = right.format_version
  && Graph_types.Uuid.equal left.graph_id right.graph_id
  && left.schema = right.schema
  && left.applied_server_t = right.applied_server_t
  && String.equal left.checksum right.checksum
  && left.status = right.status
  && left.last_error = right.last_error
;;
