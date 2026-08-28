type status =
  { fts_generation : string option
  ; vector_generation : string option
  }

type t =
  { graph_dir : string
  ; owner : Ownership.t
  }

type error =
  | Ownership_error of Ownership.error
  | Invalid_marker
  | Io_error

let create ~graph_dir ~owner =
  match Ownership.revalidate owner with
  | Error error -> Error (Ownership_error error)
  | Ok () ->
    (try
       let graph_dir = Unix.realpath graph_dir in
       if String.equal graph_dir (Ownership.graph_dir owner)
       then Ok { graph_dir; owner }
       else Error (Ownership_error Ownership.Identity_changed)
     with
     | Unix.Unix_error _ -> Error Io_error)
;;

let marker_path t = Filename.concat t.graph_dir ".logseq-db-worker.derived-sidecars.json"

let valid_generation generation =
  match Graph_types.Uuid.of_string generation with
  | Ok _ -> true
  | Error _ -> false
;;

let generation = function
  | `Null -> Ok None
  | `String generation when valid_generation generation -> Ok (Some generation)
  | _ -> Error Invalid_marker
;;

let parse_marker = function
  | `Assoc fields when List.length fields = 3 ->
    (match
       ( List.assoc_opt "formatVersion" fields
       , List.assoc_opt "ftsRequiredGeneration" fields
       , List.assoc_opt "vectorRequiredGeneration" fields )
     with
     | Some (`Int 1), Some fts, Some vector ->
       (match generation fts, generation vector with
        | Ok fts_generation, Ok vector_generation ->
          Ok { fts_generation; vector_generation }
        | Error _, _ | _, Error _ -> Error Invalid_marker)
     | _ -> Error Invalid_marker)
  | _ -> Error Invalid_marker
;;

let read_marker t =
  let path = marker_path t in
  if not (Sys.file_exists path)
  then Ok { fts_generation = None; vector_generation = None }
  else (
    try
      let stat = Unix.lstat path in
      if stat.st_kind <> Unix.S_REG || stat.st_nlink <> 1
      then Error Invalid_marker
      else parse_marker (Yojson.Safe.from_file path)
    with
    | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _ -> Error Invalid_marker)
;;

let status t =
  match Ownership.revalidate t.owner with
  | Error error -> Error (Ownership_error error)
  | Ok () -> read_marker t
;;

let random_uuid_string () =
  let channel = open_in_bin "/dev/urandom" in
  let bytes =
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel 16 |> Bytes.of_string)
  in
  Bytes.set bytes 6 (Char.chr (Char.code (Bytes.get bytes 6) land 0x0f lor 0x40));
  Bytes.set bytes 8 (Char.chr (Char.code (Bytes.get bytes 8) land 0x3f lor 0x80));
  let buffer = Buffer.create 36 in
  Bytes.iteri
    (fun index byte ->
       if List.mem index [ 4; 6; 8; 10 ] then Buffer.add_char buffer '-';
       Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents buffer
;;

let marker_json status =
  Yojson.Safe.to_string
    (`Assoc
        [ "formatVersion", `Int 1
        ; ( "ftsRequiredGeneration"
          , match status.fts_generation with
            | None -> `Null
            | Some generation -> `String generation )
        ; ( "vectorRequiredGeneration"
          , match status.vector_generation with
            | None -> `Null
            | Some generation -> `String generation )
        ])
  ^ "\n"
;;

let write_all fd bytes =
  let rec loop offset =
    if offset < Bytes.length bytes
    then loop (offset + Unix.write fd bytes offset (Bytes.length bytes - offset))
  in
  loop 0;
  Unix.fsync fd
;;

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let write_marker t value =
  let path = marker_path t in
  let temporary = path ^ ".tmp-" ^ random_uuid_string () in
  Fun.protect
    ~finally:(fun () ->
      try Unix.unlink temporary with
      | Unix.Unix_error _ -> ())
    (fun () ->
       try
         let fd = Unix.openfile temporary [ Unix.O_CREAT; O_EXCL; O_WRONLY ] 0o600 in
         Fun.protect
           ~finally:(fun () ->
             try Unix.close fd with
             | Unix.Unix_error _ -> ())
           (fun () -> write_all fd (Bytes.of_string (marker_json value)));
         match Ownership.revalidate t.owner with
         | Error error -> Error (Ownership_error error)
         | Ok () ->
           Unix.rename temporary path;
           fsync_directory t.graph_dir;
           (match Ownership.revalidate t.owner with
            | Ok () -> Ok ()
            | Error error -> Error (Ownership_error error))
       with
       | Unix.Unix_error _ | Sys_error _ -> Error Io_error)
;;

let invalidate t =
  match Ownership.revalidate t.owner with
  | Error error -> Error (Ownership_error error)
  | Ok () ->
    (match read_marker t with
     | Error _ as error -> error
     | Ok _ ->
       let fts_generation = random_uuid_string () in
       let rec distinct_vector_generation () =
         let candidate = random_uuid_string () in
         if String.equal candidate fts_generation
         then distinct_vector_generation ()
         else candidate
       in
       let value =
         { fts_generation = Some fts_generation
         ; vector_generation = Some (distinct_vector_generation ())
         }
       in
       (match write_marker t value with
        | Ok () -> Ok value
        | Error _ as error -> error))
;;
