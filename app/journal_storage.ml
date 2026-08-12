type disposition =
  | Initialized
  | Restored

type state =
  | Ready
  | Terminal
  | Closed

type operation =
  | Open
  | Restore
  | Initialize
  | Transact
  | Inspect_tail
  | Close
  | Backup

module Error = struct
  type t =
    | Path_quarantined
    | Invalid_path of string
    | Backend_failure of operation
    | Unsupported_store of string
    | Invalid_state of state

  let operation_name = function
    | Open -> "open"
    | Restore -> "restore"
    | Initialize -> "initialize"
    | Transact -> "transact"
    | Inspect_tail -> "inspect tail"
    | Close -> "close"
    | Backup -> "backup"
  ;;

  let state_name = function
    | Ready -> "ready"
    | Terminal -> "terminal"
    | Closed -> "closed"
  ;;

  let to_string = function
    | Path_quarantined -> "database path is quarantined until OS process restart"
    | Invalid_path message -> "invalid canonical database path: " ^ message
    | Backend_failure operation ->
      "DataScript SQLite backend failed during " ^ operation_name operation
    | Unsupported_store message -> "unsupported journal store: " ^ message
    | Invalid_state state -> "journal storage is not ready: " ^ state_name state
  ;;

  let is_path_quarantined = function
    | Path_quarantined -> true
    | Invalid_path _ | Backend_failure _ | Unsupported_store _ | Invalid_state _ -> false
  ;;
end

type t =
  { canonical_path : string
  ; session : Datascript_sqlite.session
  ; storage : Datascript.storage
  ; mutable database : Datascript.db
  ; mutable state : state
  }

let canonical_path store = store.canonical_path
let state store = store.state
let current_db store = store.database

let validate_path canonical_path =
  if Filename.is_relative canonical_path
  then Error (Error.Invalid_path "path must be absolute")
  else (
    let parent = Filename.dirname canonical_path in
    match Unix.realpath parent with
    | canonical_parent when String.equal canonical_parent parent ->
      (match Unix.lstat canonical_path with
       | { Unix.st_kind = Unix.S_LNK; _ } ->
         Error (Error.Invalid_path "database leaf must not be a symbolic link")
       | { Unix.st_kind = Unix.S_REG; _ }
       | (exception Unix.Unix_error (Unix.ENOENT, _, _)) -> Ok ()
       | _ -> Error (Error.Invalid_path "database leaf must be a regular file"))
    | _ -> Error (Error.Invalid_path "parent must already be canonical")
    | exception Unix.Unix_error _ ->
      Error (Error.Invalid_path "parent must exist and be accessible"))
;;

let tombstone canonical_path reason =
  Journal_process_recovery.quarantine ~canonical_path reason
;;

let backend_error canonical_path operation =
  tombstone canonical_path Journal_process_recovery.Storage_failure;
  Error (Error.Backend_failure operation)
;;

let close_session_after_failure canonical_path session =
  match Datascript_sqlite.close session with
  | () -> ()
  | exception _ ->
    tombstone canonical_path Journal_process_recovery.Lifecycle_outcome_unknown
;;

let initialize canonical_path session storage =
  match
    let database = Datascript.empty_db ~schema:Journal_schema.data_script ~storage () in
    let report =
      Datascript.transact database (Journal_repository.initialize_store_transaction ())
    in
    Datascript.store ~storage report.db_after;
    report.db_after
  with
  | database ->
    Ok ({ canonical_path; session; storage; database; state = Ready }, Initialized)
  | exception _ ->
    close_session_after_failure canonical_path session;
    backend_error canonical_path Initialize
;;

let admit_restored canonical_path session storage database =
  match Journal_repository.validate_store database with
  | Ok () -> Ok ({ canonical_path; session; storage; database; state = Ready }, Restored)
  | Error error ->
    close_session_after_failure canonical_path session;
    Error (Error.Unsupported_store (Journal_repository.Error.to_string error))
;;

let restore_or_initialize canonical_path session storage =
  match Datascript.restore storage with
  | Some database -> admit_restored canonical_path session storage database
  | None ->
    (match Datascript.storage_addresses storage with
     | [] -> initialize canonical_path session storage
     | _ :: _ ->
       close_session_after_failure canonical_path session;
       backend_error canonical_path Restore)
  | exception _ ->
    close_session_after_failure canonical_path session;
    backend_error canonical_path Restore
;;

let open_store ~canonical_path =
  match Journal_process_recovery.find_tombstone ~canonical_path with
  | Some _ -> Error Error.Path_quarantined
  | None ->
    (match validate_path canonical_path with
     | Error _ as error -> error
     | Ok () ->
       (match Datascript_sqlite.open_session canonical_path with
        | session ->
          let storage = Datascript_sqlite.storage session in
          restore_or_initialize canonical_path session storage
        | exception _ -> backend_error canonical_path Open))
;;

let quarantine store reason =
  tombstone store.canonical_path reason;
  store.state <- Terminal
;;

let transact store transaction =
  match store.state with
  | (Terminal | Closed) as state -> Error (Error.Invalid_state state)
  | Ready ->
    (match Datascript.transact store.database transaction with
     | report ->
       store.database <- report.db_after;
       Ok report
     | exception _ ->
       quarantine store Journal_process_recovery.Storage_failure;
       Error (Error.Backend_failure Transact))
;;

let tail_datom_count store =
  match store.state with
  | (Terminal | Closed) as state -> Error (Error.Invalid_state state)
  | Ready ->
    (match Datascript.Storage.restore_tail_groups store.storage with
     | tail -> Ok (Datascript.Storage.tail_datom_count tail)
     | exception _ ->
       quarantine store Journal_process_recovery.Storage_failure;
       Error (Error.Backend_failure Inspect_tail))
;;

let backup_directory canonical_path =
  Filename.concat (Filename.dirname canonical_path) "backups"
;;

let ensure_backup_directory canonical_path =
  let directory = backup_directory canonical_path in
  match Unix.lstat directory with
  | { Unix.st_kind = Unix.S_DIR; _ } -> directory
  | _ -> failwith "journal backup path is not a directory"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    Unix.mkdir directory 0o700;
    directory
;;

let close_noerr descriptor =
  match Unix.close descriptor with
  | () -> ()
  | exception _ -> ()
;;

let copy_and_sync ~source ~destination =
  let source_descriptor = Unix.openfile source [ Unix.O_RDONLY ] 0 in
  let destination_descriptor =
    match
      Unix.openfile destination [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    with
    | descriptor -> descriptor
    | exception error ->
      close_noerr source_descriptor;
      raise error
  in
  Fun.protect
    ~finally:(fun () ->
      close_noerr source_descriptor;
      close_noerr destination_descriptor)
    (fun () ->
       let buffer = Bytes.create 65_536 in
       let rec write offset length =
         if length > 0
         then (
           let written = Unix.single_write destination_descriptor buffer offset length in
           if written = 0 then failwith "journal backup write made no progress";
           write (offset + written) (length - written))
       in
       let rec read () =
         match Unix.read source_descriptor buffer 0 (Bytes.length buffer) with
         | 0 -> ()
         | length ->
           write 0 length;
           read ()
       in
       read ();
       Unix.fsync destination_descriptor)
;;

let is_backup_name name =
  String.starts_with ~prefix:"journal-" name && String.ends_with ~suffix:".sqlite3" name
;;

let prune_backups directory =
  let backups =
    Sys.readdir directory
    |> Array.to_list
    |> List.filter (fun name ->
      is_backup_name name
      &&
      match Unix.lstat (Filename.concat directory name) with
      | { Unix.st_kind = Unix.S_REG; _ } -> true
      | _ | (exception Unix.Unix_error _) -> false)
    |> List.sort String.compare
  in
  let obsolete_count = max 0 (List.length backups - 3) in
  backups
  |> List.filteri (fun index _ -> index < obsolete_count)
  |> List.iter (fun name -> Unix.unlink (Filename.concat directory name))
;;

let sync_directory directory =
  let descriptor = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> close_noerr descriptor)
    (fun () -> Unix.fsync descriptor)
;;

let publish_backup store basis =
  let directory = ensure_backup_directory store.canonical_path in
  let stem = Printf.sprintf "journal-%016x" basis in
  let final_path = Filename.concat directory (stem ^ ".sqlite3") in
  if Sys.file_exists final_path
  then prune_backups directory
  else (
    let temporary_path = Filename.concat directory (stem ^ ".tmp") in
    (match Unix.lstat temporary_path with
     | { Unix.st_kind = Unix.S_REG; _ } -> Unix.unlink temporary_path
     | _ -> failwith "journal backup temporary path is unsafe"
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    Fun.protect
      ~finally:(fun () ->
        match Unix.lstat temporary_path with
        | { Unix.st_kind = Unix.S_REG; _ } -> Unix.unlink temporary_path
        | _ | (exception Unix.Unix_error _) -> ())
      (fun () ->
         copy_and_sync ~source:store.canonical_path ~destination:temporary_path;
         Unix.rename temporary_path final_path;
         sync_directory directory);
    prune_backups directory)
;;

let close store =
  match store.state with
  | Closed -> Ok ()
  | Terminal ->
    (match Datascript_sqlite.close store.session with
     | () ->
       store.state <- Closed;
       Ok ()
     | exception _ ->
       quarantine store Journal_process_recovery.Lifecycle_outcome_unknown;
       Error (Error.Backend_failure Close))
  | Ready ->
    let basis = store.database.max_tx in
    (match Datascript_sqlite.close store.session with
     | () ->
       store.state <- Closed;
       (match publish_backup store basis with
        | () -> Ok ()
        | exception _ -> Error (Error.Backend_failure Backup))
     | exception _ ->
       quarantine store Journal_process_recovery.Lifecycle_outcome_unknown;
       Error (Error.Backend_failure Close))
;;
