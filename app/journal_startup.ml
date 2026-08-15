module Error = struct
  type t = Invalid of string

  let to_string (Invalid message) = message
end

type t = Logseq_db_worker.Config.t

let magic = "LDB1"
let header_size = 8
let maximum_payload_bytes = 1024 * 1024
let error format = Printf.ksprintf (fun message -> Error (Error.Invalid message)) format

let encode value =
  let json =
    Logseq_db_worker.Config.to_yojson value |> Yojson.Safe.to_string
  in
  let size = header_size + String.length json in
  if size > maximum_payload_bytes
  then error "startup payload exceeds 1 MiB"
  else (
    let bytes = Bytes.create size in
    Bytes.blit_string magic 0 bytes 0 4;
    Bytes.set_int32_le bytes 4 (Int32.of_int (String.length json));
    Bytes.blit_string json 0 bytes header_size (String.length json);
    Ok bytes)
;;
let decode bytes =
  let length = Bytes.length bytes in
  if length < header_size
  then error "startup payload is truncated"
  else if length > maximum_payload_bytes
  then error "startup payload exceeds 1 MiB"
  else if not (String.equal (Bytes.sub_string bytes 0 4) magic)
  then error "invalid startup magic"
  else (
    let encoded_length = Bytes.get_int32_le bytes 4 in
    if Int32.compare encoded_length 0l < 0
    then error "startup configuration length is invalid"
    else if Int32.to_int encoded_length <> length - header_size
    then error "startup payload has trailing or missing bytes"
    else
      let json = Bytes.sub_string bytes header_size (length - header_size) in
      try
        match
          Yojson.Safe.from_string json |> Logseq_db_worker.Config.of_yojson
        with
        | Ok config -> Ok config
        | Error message -> error "invalid startup configuration: %s" message
      with
      | Yojson.Json_error _ -> error "startup configuration must be valid UTF-8 JSON")
;;
