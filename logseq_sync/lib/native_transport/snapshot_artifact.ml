module Failure_diagnostic = Logseq_db_types.Failure_diagnostic

let failure_message ~reason:reason_name source =
  Failure_diagnostic.(
    of_source ~operation:"decodeSnapshot" ~reason:reason_name source |> message)
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
  | Sys_error _ as error ->
    (* Missing artifacts are normal idempotent cleanup. Preserve the original
       unit completion if an artifact remains, but retain a safe support cause. *)
    if Sys.file_exists path
    then (
      let detail =
        Failure_diagnostic.of_source
          ~operation:"decodeSnapshot"
          ~reason:"cleanupFailed"
          (Printexc.to_string error)
      in
      try
        Printf.eprintf
          "journal: phase=cleanup operation=removeSnapshotArtifact code=cleanupPending \
           source=%s\n\
           %!"
          (Failure_diagnostic.source_class detail)
      with
      | _ -> ())
;;

let cleanup = List.iter remove_if_exists

let gzip_signature path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         try
           let first = input_char channel in
           let second = input_char channel in
           Ok (first = '\x1f' && second = '\x8b')
         with
         | End_of_file -> Ok false)
  with
  | Sys_error _ as error ->
    Error (failure_message ~reason:"resourceFailed" (Printexc.to_string error))
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
  | Failure source when source = "snapshot artifact exceeds its decompressed bound" ->
    remove_if_exists destination;
    Error "snapshot artifact exceeds its decompressed bound"
  | exception_ ->
    remove_if_exists destination;
    Error (failure_message ~reason:"resourceFailed" (Printexc.to_string exception_))
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
  | status ->
    remove_if_exists destination;
    Error
      (match status with
       | 1 -> "snapshot gzip input could not be opened"
       | 2 -> "snapshot gzip output could not be opened"
       | 3 -> "snapshot gzip decode failed"
       | 4 -> "snapshot gzip output write failed"
       | 5 -> "snapshot gzip decompressed limit exceeded"
       | _ -> "snapshot gzip layer is invalid")
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
                | Sys_error _ as error ->
                  fail
                    (failure_message
                       ~reason:"persistenceFailed"
                       (Printexc.to_string error)))
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
                      | Sys_error _ as error ->
                        fail
                          (failure_message
                             ~reason:"persistenceFailed"
                             (Printexc.to_string error))))))))
    | [] | [ _ ] -> Error "two private gzip staging paths are required")
;;
