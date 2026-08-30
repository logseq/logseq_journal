type progress =
  { received_bytes : int
  ; total_bytes : int option
  ; datom_count : int option
  }

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
