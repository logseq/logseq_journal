let maximum_cache_bytes = 1024 * 1024

let is_directory path =
  try (Unix.lstat path).Unix.st_kind = Unix.S_DIR with
  | Unix.Unix_error _ -> false
;;

let ensure_directory path =
  if Sys.file_exists path
  then if is_directory path then Ok () else Error (path ^ " is not a directory")
  else (
    try
      Unix.mkdir path 0o700;
      Ok ()
    with
    | exception_ -> Error (Printexc.to_string exception_))
;;

let cache_root application_support_directory =
  Filename.concat
    (Filename.concat application_support_directory "logseq-db-worker")
    "sync-catalogs"
;;

let ensure_root application_support_directory =
  if
    Filename.is_relative application_support_directory
    || not (is_directory application_support_directory)
  then Error "application-support directory is invalid"
  else (
    let worker = Filename.concat application_support_directory "logseq-db-worker" in
    Result.bind (ensure_directory worker) (fun () ->
      let root = cache_root application_support_directory in
      Result.map (fun () -> root) (ensure_directory root)))
;;

let cache_path root ~user_id ~base_url =
  let digest =
    Digestif.SHA256.digest_string (user_id ^ "\000" ^ base_url) |> Digestif.SHA256.to_hex
  in
  Filename.concat root (digest ^ ".json")
;;

let regular_single_link path =
  try
    let stat = Unix.lstat path in
    stat.st_kind = Unix.S_REG && stat.st_nlink = 1
  with
  | Unix.Unix_error _ -> false
;;

let read_bounded path =
  if not (regular_single_link path)
  then Error "catalog cache is not a private regular file"
  else (
    let length = (Unix.stat path).st_size in
    if length < 0 || length > maximum_cache_bytes
    then Error "catalog cache exceeds its size bound"
    else (
      try
        let channel = open_in_bin path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () -> Ok (really_input_string channel length))
      with
      | exception_ -> Error (Printexc.to_string exception_)))
;;

let load ~application_support_directory ~user_id ~base_url =
  Result.bind (ensure_root application_support_directory) (fun root ->
    let path = cache_path root ~user_id ~base_url in
    if not (Sys.file_exists path)
    then Ok None
    else
      Result.bind (read_bounded path) (fun source ->
        try
          Result.bind
            (Catalog.of_yojson (Yojson.Safe.from_string source))
            (fun cache ->
               if
                 String.equal (Catalog.user_id cache) user_id
                 && String.equal (Catalog.base_url cache) base_url
               then Ok (Some cache)
               else Error "catalog cache scope does not match its file")
        with
        | Yojson.Json_error _ -> Error "catalog cache is not valid JSON"))
;;

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let save ~application_support_directory cache =
  Result.bind (ensure_root application_support_directory) (fun root ->
    let source = Catalog.to_yojson cache |> Yojson.Safe.to_string in
    if String.length source > maximum_cache_bytes
    then Error "catalog cache exceeds its size bound"
    else (
      let destination =
        cache_path
          root
          ~user_id:(Catalog.user_id cache)
          ~base_url:(Catalog.base_url cache)
      in
      let temporary = Filename.temp_file ~temp_dir:root ".catalog-" ".tmp" in
      let cleanup () =
        try Sys.remove temporary with
        | Sys_error _ -> ()
      in
      try
        Unix.chmod temporary 0o600;
        let channel = open_out_bin temporary in
        Fun.protect
          ~finally:(fun () -> close_out_noerr channel)
          (fun () ->
             output_string channel source;
             flush channel;
             Unix.fsync (Unix.descr_of_out_channel channel));
        Unix.rename temporary destination;
        fsync_directory root;
        Ok ()
      with
      | exception_ ->
        cleanup ();
        Error (Printexc.to_string exception_)))
;;
