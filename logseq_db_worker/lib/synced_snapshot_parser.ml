module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type row =
  { addr : int
  ; content : string
  ; addresses : string option
  }

type parser =
  { max_frame_bytes : int
  ; mutable buffer : string
  }

type import =
  { expected_rows : int
  ; mutable accepted_rows : int
  ; mutable last_addr : int option
  ; mutable has_root : bool
  ; mutable has_tail : bool
  }

type completed_import = { row_count : int }

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let create_parser ~max_frame_bytes =
  if max_frame_bytes <= 0 then invalid_arg "max_frame_bytes must be positive";
  { max_frame_bytes; buffer = "" }
;;

let uint32_be value offset =
  let byte index = Char.code value.[offset + index] in
  Int64.(
    logor
      (shift_left (of_int (byte 0)) 24)
      (logor
         (shift_left (of_int (byte 1)) 16)
         (logor (shift_left (of_int (byte 2)) 8) (of_int (byte 3)))))
;;

let int_of_value = function
  | Value.Int value when value >= 0 -> Ok value
  | Value.Int64 value when value >= 0L && value <= Int64.of_int max_int ->
    Ok (Int64.to_int value)
  | _ -> Error "snapshot row address must be a non-negative Transit integer"
;;

let optional_string = function
  | Value.Null -> Ok None
  | Value.String value -> Ok (Some value)
  | _ -> Error "snapshot row addresses must be JSON text or nil"
;;

let decode_row = function
  | Value.Array [ addr; Value.String content; addresses ] ->
    bind (int_of_value addr) (fun addr ->
      bind (optional_string addresses) (fun addresses -> Ok { addr; content; addresses }))
  | _ -> Error "snapshot row must be [addr, content, addresses]"
;;

let decode_rows payload =
  let rec decode_all decoded = function
    | [] -> Ok (List.rev decoded)
    | value :: rest ->
      bind (decode_row value) (fun row -> decode_all (row :: decoded) rest)
  in
  try
    match Codec.of_string payload with
    | Value.Array values -> decode_all [] values
    | _ -> Error "snapshot frame payload must be a Transit row array"
  with
  | Value.Decode_error message
  | Yojson.Json_error message
  | Failure message
  | Invalid_argument message -> Error message
;;

let feed parser chunk =
  parser.buffer <- parser.buffer ^ chunk;
  let rec consume offset rows =
    let remaining = String.length parser.buffer - offset in
    if remaining < 4
    then Ok (offset, List.rev rows)
    else (
      let length64 = uint32_be parser.buffer offset in
      if length64 > Int64.of_int parser.max_frame_bytes
      then Error "snapshot frame exceeds configured size limit"
      else (
        let length = Int64.to_int length64 in
        if remaining - 4 < length
        then Ok (offset, List.rev rows)
        else (
          let payload = String.sub parser.buffer (offset + 4) length in
          bind (decode_rows payload) (fun decoded ->
            consume (offset + 4 + length) (List.rev_append decoded rows)))))
  in
  bind (consume 0 []) (fun (consumed, rows) ->
    if consumed > 0
    then
      parser.buffer
      <- String.sub parser.buffer consumed (String.length parser.buffer - consumed);
    Ok rows)
;;

let finish parser =
  if String.length parser.buffer = 0
  then Ok ()
  else Error "incomplete framed snapshot stream"
;;

let create_import ~expected_rows =
  { expected_rows
  ; accepted_rows = 0
  ; last_addr = None
  ; has_root = false
  ; has_tail = false
  }
;;

let accept_rows state rows =
  let rec validate last_addr has_root has_tail count = function
    | [] -> Ok (last_addr, has_root, has_tail, count)
    | row :: rest ->
      (match last_addr with
       | Some previous when row.addr <= previous ->
         Error "snapshot row addresses must be strictly increasing"
       | None | Some _ ->
         validate
           (Some row.addr)
           (has_root || row.addr = 0)
           (has_tail || row.addr = 1)
           (count + 1)
           rest)
  in
  bind
    (validate state.last_addr state.has_root state.has_tail state.accepted_rows rows)
    (fun (last_addr, has_root, has_tail, accepted_rows) ->
       if accepted_rows > state.expected_rows
       then Error "snapshot contains more rows than advertised"
       else (
         state.last_addr <- last_addr;
         state.has_root <- has_root;
         state.has_tail <- has_tail;
         state.accepted_rows <- accepted_rows;
         Ok ()))
;;

let finish_import state =
  if state.expected_rows < 0
  then Error "snapshot expected row count must be non-negative"
  else if state.accepted_rows <> state.expected_rows
  then Error "snapshot row count does not match server metadata"
  else if not state.has_root
  then Error "snapshot is missing DataScript root row 0"
  else if not state.has_tail
  then Error "snapshot is missing DataScript tail row 1"
  else Ok { row_count = state.accepted_rows }
;;
