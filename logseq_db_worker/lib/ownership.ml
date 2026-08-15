type target =
  | Snapshot_target
  | Native_target

type lock =
  { repo : string
  ; pid : int
  ; lock_id : string
  ; generation : string
  }

type t =
  { graph_dir : string
  ; lock_path : string
  ; owner_db : Sqlite3.db
  ; lock_id : string
  ; generation : string
  ; graph_device : int
  ; graph_inode : int
  ; mutable released : bool
  }

type error =
  | Already_owned
  | Ambiguous_stale_lock
  | Identity_changed
  | Not_owner
  | Invalid_sentinel

let random_uuid_string () =
  let channel = open_in_bin "/dev/urandom" in
  let bytes =
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel 16 |> Bytes.of_string)
  in
  Bytes.set bytes 6 (Char.chr ((Char.code (Bytes.get bytes 6) land 0x0f) lor 0x40));
  Bytes.set bytes 8 (Char.chr ((Char.code (Bytes.get bytes 8) land 0x3f) lor 0x80));
  let buffer = Buffer.create 36 in
  Bytes.iteri
    (fun index byte ->
       if List.mem index [ 4; 6; 8; 10 ] then Buffer.add_char buffer '-';
       Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents buffer
;;

let valid_uuid value =
  match Graph_types.Uuid.of_string value with
  | Ok _ -> true
  | Error _ -> false
;;

let read_lock path =
  try
    match Yojson.Safe.from_file path with
    | `Assoc fields when List.length fields = 6 ->
      (match
         List.assoc_opt "repo" fields,
         List.assoc_opt "pid" fields,
         List.assoc_opt "lock-id" fields,
         List.assoc_opt "owner-source" fields,
         List.assoc_opt "owner-generation" fields,
         List.assoc_opt "owner-protocol" fields
       with
       | ( Some (`String repo)
         , Some (`Int pid)
         , Some (`String lock_id)
         , Some (`String owner_source)
         , Some (`String generation)
         , Some (`Int 1) )
         when String.length repo > 0
              && pid > 0
              && valid_uuid lock_id
              && valid_uuid generation
              && List.mem owner_source [ "cli"; "electron"; "unknown" ] ->
         Some { repo; pid; lock_id; generation }
       | _ -> None)
    | _ -> None
  with
  | Sys_error _ | Yojson.Json_error _ -> None
;;

let pid_is_alive pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
  | Unix.Unix_error _ -> true
;;

let write_all fd value =
  let bytes = Bytes.of_string value in
  let rec loop offset =
    if offset < Bytes.length bytes
    then loop (offset + Unix.write fd bytes offset (Bytes.length bytes - offset))
  in
  loop 0;
  Unix.fsync fd
;;

let sentinel ~graph_name ~lock_id ~generation =
  Yojson.Safe.to_string
    (`Assoc
       [ "repo", `String graph_name
       ; "pid", `Int (Unix.getpid ())
       ; "lock-id", `String lock_id
       ; "owner-source", `String "unknown"
       ; "owner-generation", `String generation
       ; "owner-protocol", `Int 1
       ])
;;

let release_owner_db owner_db =
  ignore (Sqlite3.exec owner_db "ROLLBACK");
  ignore (Sqlite3.db_close owner_db)
;;

let acquire_owner_db graph_dir =
  let path = Filename.concat graph_dir ".logseq-db-worker.owner.sqlite" in
  try
    let db = Sqlite3.db_open path in
    let fail error =
      ignore (Sqlite3.db_close db);
      Error error
    in
    let initialize =
      [ "PRAGMA journal_mode = DELETE"
      ; "PRAGMA synchronous = FULL"
      ; "PRAGMA busy_timeout = 0"
      ; "CREATE TABLE IF NOT EXISTS owner_primitive (protocol INTEGER NOT NULL)"
      ]
    in
    let rec execute = function
      | [] ->
        (match Sqlite3.exec db "BEGIN IMMEDIATE" with
         | rc when Sqlite3.Rc.is_success rc -> Ok db
         | Sqlite3.Rc.BUSY | LOCKED -> fail Already_owned
         | _ -> fail Identity_changed)
      | statement :: rest ->
        (match Sqlite3.exec db statement with
         | rc when Sqlite3.Rc.is_success rc -> execute rest
         | Sqlite3.Rc.BUSY | LOCKED -> fail Already_owned
         | _ -> fail Identity_changed)
    in
    execute initialize
  with
  | Sqlite3.SqliteError _ -> Error Identity_changed
;;

let acquire ~target ~graph_dir =
  try
    let graph_dir = Unix.realpath graph_dir in
    let graph_stat = Unix.stat graph_dir in
    if graph_stat.st_kind <> Unix.S_DIR
    then Error Identity_changed
    else
      match acquire_owner_db graph_dir with
      | Error _ as error -> error
      | Ok owner_db ->
        let fail error =
          release_owner_db owner_db;
          Error error
        in
        let lock_path = Filename.concat graph_dir "db-worker.lock" in
        let graph_name = Filename.basename graph_dir in
        let inspect_existing () =
          if not (Sys.file_exists lock_path)
          then Ok ()
          else
            match read_lock lock_path with
            | None -> Error Invalid_sentinel
            | Some lock when not (String.equal lock.repo graph_name) ->
              Error Invalid_sentinel
            | Some lock when pid_is_alive lock.pid -> Error Already_owned
            | Some _ when target = Snapshot_target -> Error Ambiguous_stale_lock
            | Some _ ->
              (try
                 Unix.unlink lock_path;
                 Ok ()
               with
               | Unix.Unix_error _ -> Error Ambiguous_stale_lock)
        in
        (match inspect_existing () with
         | Error error -> fail error
         | Ok () ->
           let lock_id = random_uuid_string () in
           let generation = random_uuid_string () in
           (try
              let fd =
                Unix.openfile lock_path [ Unix.O_CREAT; O_EXCL; O_WRONLY ] 0o600
              in
              Fun.protect
                ~finally:(fun () -> Unix.close fd)
                (fun () ->
                   write_all fd (sentinel ~graph_name ~lock_id ~generation));
              Ok
                { graph_dir
                ; lock_path
                ; owner_db
                ; lock_id
                ; generation
                ; graph_device = graph_stat.st_dev
                ; graph_inode = graph_stat.st_ino
                ; released = false
                }
            with
            | Unix.Unix_error (Unix.EEXIST, _, _) -> fail Ambiguous_stale_lock
            | Unix.Unix_error _ -> fail Identity_changed))
  with
  | Unix.Unix_error _ -> Error Identity_changed
;;

let revalidate owner =
  if owner.released
  then Error Not_owner
  else
    try
      let stat = Unix.stat owner.graph_dir in
      if stat.st_dev <> owner.graph_device || stat.st_ino <> owner.graph_inode
      then Error Identity_changed
      else
        match read_lock owner.lock_path with
        | Some lock
          when lock.pid = Unix.getpid ()
               && String.equal lock.repo (Filename.basename owner.graph_dir)
               && String.equal lock.lock_id owner.lock_id
               && String.equal lock.generation owner.generation ->
          (match Sqlite3.exec owner.owner_db "SELECT protocol FROM owner_primitive LIMIT 1" with
           | rc when Sqlite3.Rc.is_success rc -> Ok ()
           | _ -> Error Identity_changed)
        | _ -> Error Identity_changed
    with
    | Unix.Unix_error _ | Sqlite3.SqliteError _ -> Error Identity_changed
;;

let release owner =
  if owner.released
  then Error Not_owner
  else
    let validation = revalidate owner in
    let unlink_result =
      match validation with
      | Error error -> Error error
      | Ok () ->
        (match read_lock owner.lock_path with
         | Some lock
           when String.equal lock.lock_id owner.lock_id
                && String.equal lock.generation owner.generation ->
           (try
              Unix.unlink owner.lock_path;
              Ok ()
            with
            | Unix.Unix_error _ -> Error Not_owner)
         | _ -> Error Identity_changed)
    in
    release_owner_db owner.owner_db;
    owner.released <- true;
    unlink_result
;;

let generation owner = owner.generation
let graph_dir owner = owner.graph_dir
