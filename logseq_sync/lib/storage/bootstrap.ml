type progress =
  { received_bytes : int
  ; total_bytes : int option
  ; datom_count : int option
  }

type baseline = { server_t : int }

type content_encoding =
  [ `Gzip
  | `Identity
  ]

type snapshot_metadata =
  { key : string
  ; url : Uri.t
  ; content_encoding : content_encoding option
  }

let maximum_gzip_layers = 2

let exact_fields expected fields =
  List.length expected = List.length fields
  && List.for_all (fun name -> List.mem_assoc name fields) expected
;;

let decode_json_object label source f =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields -> f fields
    | _ -> Error (label ^ " must be a JSON object")
  with
  | Yojson.Json_error _ -> Error (label ^ " is not valid JSON")
;;

let valid_checksum = function
  | None | Some `Null -> true
  | Some (`String value) ->
    String.length value = 16
    && String.for_all
         (function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false)
         value
  | Some _ -> false
;;

let decode_baseline source =
  decode_json_object "snapshot baseline pull" source (fun fields ->
    let names = List.map fst fields in
    let required = [ "type"; "t"; "txs" ] in
    let valid_names = required @ [ "checksum" ] in
    if
      not
        (List.for_all (fun name -> List.mem name names) required
         && List.for_all (fun name -> List.mem name valid_names) names
         && List.length names = List.length (List.sort_uniq String.compare names))
    then Error "snapshot baseline pull fields are invalid"
    else (
      match
        ( List.assoc "type" fields
        , List.assoc "t" fields
        , List.assoc "txs" fields
        , List.assoc_opt "checksum" fields )
      with
      | `String "pull/ok", `Int server_t, `List _, checksum
        when server_t >= 0 && valid_checksum checksum -> Ok { server_t }
      | _ -> Error "snapshot baseline pull is invalid"))
;;

let valid_snapshot_url url =
  String.equal (Option.value (Uri.scheme url) ~default:"") "https"
  && (match Uri.host url with
      | Some host -> String.length host > 0
      | None -> false)
  && Uri.userinfo url = None
  && Uri.fragment url = None
;;

let decode_snapshot_metadata source =
  decode_json_object "snapshot metadata" source (fun fields ->
    let expected =
      match List.mem_assoc "content-encoding" fields with
      | true -> [ "ok"; "key"; "url"; "content-encoding" ]
      | false -> [ "ok"; "key"; "url" ]
    in
    if not (exact_fields expected fields)
    then Error "snapshot metadata fields are invalid"
    else (
      let encoding =
        match List.assoc_opt "content-encoding" fields with
        | None | Some `Null -> Ok None
        | Some (`String "gzip") -> Ok (Some `Gzip)
        | Some (`String "identity") -> Ok (Some `Identity)
        | Some _ -> Error "snapshot content encoding is invalid"
      in
      match
        List.assoc "ok" fields, List.assoc "key" fields, List.assoc "url" fields, encoding
      with
      | `Bool true, `String key, `String url, Ok content_encoding
        when String.length key > 0 ->
        let url = Uri.of_string url in
        if valid_snapshot_url url
        then Ok { key; url; content_encoding }
        else Error "snapshot download URL is invalid"
      | _, _, _, Error message -> Error message
      | _ -> Error "snapshot metadata is invalid"))
;;

let artifact_row_count headers =
  let value =
    List.find_map
      (fun (name, value) ->
         if String.equal (String.lowercase_ascii name) "x-snapshot-row-count"
         then Some value
         else None)
      headers
  in
  match Option.bind value int_of_string_opt with
  | Some value when value > 0 -> Ok value
  | _ -> Error "snapshot row-count header is invalid"
;;

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let cleanup = List.iter remove_if_exists

let gzip_signature path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         let first = Char.code (input_char channel) in
         let second = Char.code (input_char channel) in
         match first, second with
         | 0x1f, 0x8b -> Ok true
         | _, _ -> Ok false
         | exception End_of_file -> Ok false)
  with
  | Sys_error message -> Error message
;;

let copy_file ~maximum_bytes source destination =
  try
    let input_channel = open_in_bin source in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input_channel)
      (fun () ->
         let output_channel =
           open_out_gen
             [ Open_wronly; Open_creat; Open_excl; Open_binary ]
             0o600
             destination
         in
         Fun.protect
           ~finally:(fun () -> close_out_noerr output_channel)
           (fun () ->
              let buffer = Bytes.create 16_384 in
              let copied = ref 0 in
              let rec loop () =
                let count = input input_channel buffer 0 (Bytes.length buffer) in
                if count > 0
                then (
                  if !copied + count > maximum_bytes
                  then failwith "snapshot artifact exceeds its decompressed bound";
                  output output_channel buffer 0 count;
                  copied := !copied + count;
                  loop ())
              in
              loop ()));
    Ok ()
  with
  | Sys_error message ->
    remove_if_exists destination;
    Error message
  | exception_ ->
    remove_if_exists destination;
    Error (Printexc.to_string exception_)
;;

let nonempty path =
  try (Unix.stat path).st_size > 0 with
  | Unix.Unix_error _ -> false
;;

let decompress ~decompress_gzip ~maximum_bytes source destination =
  remove_if_exists destination;
  match decompress_gzip source destination maximum_bytes with
  | 0 when nonempty destination -> Ok ()
  | 0 ->
    remove_if_exists destination;
    Error "snapshot gzip layer is empty"
  | _ ->
    remove_if_exists destination;
    Error "snapshot gzip layer is invalid"
;;

let peel_gzip_layers ~decompress_gzip ~maximum_bytes ~source ~destination ~temporary_paths
  =
  if maximum_bytes <= 0
  then Error "snapshot decompressed bound must be positive"
  else (
    match temporary_paths with
    | first :: second :: _ ->
      cleanup [ destination; first; second ];
      let fail message =
        cleanup [ destination; first; second ];
        Error message
      in
      (match gzip_signature source with
       | Error message -> fail message
       | Ok false -> copy_file ~maximum_bytes source destination
       | Ok true ->
         (match decompress ~decompress_gzip ~maximum_bytes source first with
          | Error message -> fail message
          | Ok () ->
            (match gzip_signature first with
             | Error message -> fail message
             | Ok false ->
               (try
                  Sys.rename first destination;
                  cleanup [ second ];
                  Ok ()
                with
                | Sys_error message -> fail message)
             | Ok true ->
               (match decompress ~decompress_gzip ~maximum_bytes first second with
                | Error message -> fail message
                | Ok () ->
                  (match gzip_signature second with
                   | Error message -> fail message
                   | Ok true -> fail "snapshot exceeds the supported gzip layer count"
                   | Ok false ->
                     (try
                        Sys.rename second destination;
                        cleanup [ first ];
                        Ok ()
                      with
                      | Sys_error message -> fail message))))))
    | [] | [ _ ] -> Error "two private gzip staging paths are required")
;;
