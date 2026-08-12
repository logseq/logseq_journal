open Datascript

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok error_to_string = function
  | Ok value -> value
  | Error error -> fail "unexpected error: %s" (error_to_string error)
;;

let require_error _error_to_string = function
  | Ok _ -> fail "expected an error"
  | Error error -> error
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_database f =
  let root = Filename.temp_file "logseq-journal-storage-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let canonical_root = Unix.realpath root in
  let database_path =
    require_ok
      Journal_storage_path.Error.to_string
      (Journal_storage_path.resolve
         ~support_root:canonical_root
         ~relative_path:Journal_startup.database_relative_path)
  in
  require
    (Sys.is_directory (Filename.concat canonical_root "logseq_journal"))
    "OCaml storage path resolution did not create its private parent";
  Fun.protect
    ~finally:(fun () -> remove_tree canonical_root)
    (fun () -> f ~canonical_root ~database_path)
;;

let open_store_exn database_path =
  require_ok
    Journal_storage.Error.to_string
    (Journal_storage.open_store ~canonical_path:database_path)
;;

let close_exn store =
  require_ok Journal_storage.Error.to_string (Journal_storage.close store)
;;

let transact_exn store transaction =
  require_ok Journal_storage.Error.to_string (Journal_storage.transact store transaction)
;;

let tail_count_exn store =
  require_ok Journal_storage.Error.to_string (Journal_storage.tail_datom_count store)
;;

let sample_page_id = "0198a4be-4d21-7bd7-a729-7ad5d2591978"
let sample_block_id = "0198a4be-4d21-7bd7-c729-7ad5d2591978"
let sample_mutation_id = "0198a4be-4d21-7bd7-b729-7ad5d2591978"

let sample_capture_transaction _store =
  let page = Temp_id "sample-page" in
  let block = Temp_id "sample-block" in
  [ Add (page, "journal.page/id", Uuid sample_page_id)
  ; Add (page, "journal.page/day", Int 20260809)
  ; Add (page, "journal.page/title", String "2026-08-09")
  ; Add (block, "journal.block/id", Uuid sample_block_id)
  ; Add (block, "journal.block/page", Ref_to page)
  ; Add (block, "journal.block/parent", Ref_to page)
  ; Add (block, "journal.block/order", String "000000000001")
  ; Add (block, "journal.block/source", String "Persist one typed block")
  ; Add (block, "journal.block/task-state", Keyword "todo")
  ; Add (block, "journal.block/created-instant-unix-ms", Int 1_786_204_800_000)
  ; Add (block, "journal.block/created-local-day", Int 20260809)
  ; Add (block, "journal.block/created-local-minute", Int 0)
  ; Add (block, "journal.block/created-time-zone-id", String "Asia/Shanghai")
  ; Add (block, "journal.block/created-utc-offset-seconds", Int 28_800)
  ; Add (block, "journal.block/revision", Int 1)
  ; Add (block, "journal.block/last-mutation-id", Uuid sample_mutation_id)
  ]
;;

let sample_block_datoms store =
  let database = Journal_storage.current_db store in
  match Datascript.entid database "journal.block/id" (Uuid sample_block_id) with
  | None -> None
  | Some entity_id -> Some (Datascript.datoms database Eavt ~e:entity_id () |> List.of_seq)
;;

let require_value datoms attribute expected =
  require
    (List.exists
       (fun (datom : Datascript.datom) ->
          String.equal datom.a attribute && datom.v = expected)
       datoms)
    "persisted block is missing %s"
    attribute
;;

let require_sample_creation_metadata store =
  match sample_block_datoms store with
  | None -> fail "persisted block is missing"
  | Some datoms ->
    require_value datoms "journal.block/created-instant-unix-ms" (Int 1_786_204_800_000);
    require_value datoms "journal.block/created-local-day" (Int 20260809);
    require_value datoms "journal.block/created-local-minute" (Int 0);
    require_value datoms "journal.block/created-time-zone-id" (String "Asia/Shanghai");
    require_value datoms "journal.block/created-utc-offset-seconds" (Int 28_800)
;;

let test_first_store_close_reopen_and_restore () =
  with_temp_database (fun ~canonical_root:_ ~database_path ->
    let store, disposition = open_store_exn database_path in
    require (disposition = Journal_storage.Initialized) "new database must be initialized";
    require
      (String.equal database_path (Journal_storage.canonical_path store))
      "storage must retain the resolved canonical database path";
    require (tail_count_exn store = 0) "initial full store must have an empty tail";
    ignore (transact_exn store (sample_capture_transaction store));
    require (tail_count_exn store > 0) "typed transaction must create a nonempty tail";
    close_exn store;
    let restored, disposition = open_store_exn database_path in
    require (disposition = Journal_storage.Restored) "existing database must be restored";
    require_sample_creation_metadata restored;
    close_exn restored)
;;

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let test_legacy_database_is_never_opened_or_changed () =
  with_temp_database (fun ~canonical_root ~database_path ->
    require
      (String.ends_with ~suffix:"/logseq_journal/store.sqlite3" database_path)
      "storage resolved an obsolete database leaf";
    let legacy_path = Filename.concat canonical_root "logseq_journal/journal.sqlite3" in
    let sentinel = "legacy database sentinel" in
    write_file legacy_path sentinel;
    let store, _ = open_store_exn database_path in
    close_exn store;
    require (String.equal (read_file legacy_path) sentinel) "legacy database was changed")
;;

let boundary_transaction count =
  List.init count (fun index ->
    Add
      ( Entity_id (10_000 + index)
      , Journal_schema.Attr.block_last_mutation_id
      , Uuid (Printf.sprintf "00000000-0000-4000-8000-%012d" index) ))
;;

let test_tail_compaction_boundary () =
  let run count expected_tail =
    with_temp_database (fun ~canonical_root:_ ~database_path ->
      let store, _ = open_store_exn database_path in
      let report = transact_exn store (boundary_transaction count) in
      require
        (List.length report.tx_data = count)
        "expected %d committed datoms, got %d"
        count
        (List.length report.tx_data);
      require
        (tail_count_exn store = expected_tail)
        "expected tail count %d after %d datoms, got %d"
        expected_tail
        count
        (tail_count_exn store);
      close_exn store)
  in
  run 32 32;
  run 33 0
;;

let execute_sql database_path sql =
  let database = Sqlite3.db_open database_path in
  Fun.protect
    ~finally:(fun () ->
      require (Sqlite3.db_close database) "failed to close corruption test database")
    (fun () ->
       let result = Sqlite3.exec database sql in
       require
         (Sqlite3.Rc.is_success result)
         "SQLite command failed: %s"
         (Sqlite3.Rc.to_string result))
;;

let backup_directory database_path =
  Filename.concat (Filename.dirname database_path) "backups"
;;

let backup_files database_path =
  let directory = backup_directory database_path in
  match Sys.readdir directory with
  | entries ->
    entries
    |> Array.to_list
    |> List.filter (fun name ->
      String.starts_with ~prefix:"journal-" name
      && String.ends_with ~suffix:".sqlite3" name)
    |> List.sort String.compare
  | exception Sys_error _ -> []
;;

let temporary_backup_files database_path =
  let directory = backup_directory database_path in
  match Sys.readdir directory with
  | entries ->
    entries
    |> Array.to_list
    |> List.filter (fun name -> String.ends_with ~suffix:".tmp" name)
  | exception Sys_error _ -> []
;;

let copy_file source destination =
  let source_fd = Unix.openfile source [ Unix.O_RDONLY ] 0 in
  let destination_fd =
    Unix.openfile destination [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.close source_fd;
      Unix.close destination_fd)
    (fun () ->
       let buffer = Bytes.create 65_536 in
       let rec write offset length =
         if length > 0
         then (
           let written = Unix.single_write destination_fd buffer offset length in
           write (offset + written) (length - written))
       in
       let rec loop () =
         match Unix.read source_fd buffer 0 (Bytes.length buffer) with
         | 0 -> ()
         | read ->
           write 0 read;
           loop ()
       in
       loop ();
       Unix.fsync destination_fd)
;;

let test_clean_close_writes_restorable_bounded_atomic_backups () =
  with_temp_database (fun ~canonical_root ~database_path ->
    for iteration = 0 to 4 do
      let store, _ = open_store_exn database_path in
      if iteration = 0
      then ignore (transact_exn store (sample_capture_transaction store))
      else
        ignore
          (transact_exn
             store
             [ Add
                 ( Entity_id (20_000 + iteration)
                 , Journal_schema.Attr.block_last_mutation_id
                 , Uuid (Printf.sprintf "80000000-0000-4000-9000-%012d" iteration) )
             ]);
      close_exn store;
      require
        (temporary_backup_files database_path = [])
        "clean close left a temporary backup"
    done;
    let backups = backup_files database_path in
    require (List.length backups = 3) "backup retention is not exactly three";
    let newest = List.hd (List.rev backups) in
    let restore_directory = Filename.concat canonical_root "restore" in
    Unix.mkdir restore_directory 0o700;
    let restore_path = Filename.concat restore_directory "journal.sqlite3" in
    copy_file (Filename.concat (backup_directory database_path) newest) restore_path;
    let restored, disposition = open_store_exn restore_path in
    require (disposition = Journal_storage.Restored) "backup did not restore as a store";
    require_sample_creation_metadata restored;
    close_exn restored;
    let backups_before_terminal = backup_files database_path in
    let terminal, _ = open_store_exn database_path in
    Journal_storage.quarantine terminal Journal_process_recovery.Storage_failure;
    close_exn terminal;
    require
      (backup_files database_path = backups_before_terminal)
      "terminal storage published a new backup")
;;

let test_unchanged_basis_deduplicates_backup () =
  with_temp_database (fun ~canonical_root:_ ~database_path ->
    let first, _ = open_store_exn database_path in
    close_exn first;
    let second, _ = open_store_exn database_path in
    close_exn second;
    require
      (List.length (backup_files database_path) = 1)
      "unchanged basis created duplicate backups")
;;

let test_backup_failure_does_not_quarantine_canonical_store () =
  with_temp_database (fun ~canonical_root:_ ~database_path ->
    let store, _ = open_store_exn database_path in
    let blocker = backup_directory database_path in
    let channel = open_out_bin blocker in
    close_out channel;
    ignore (require_error Journal_storage.Error.to_string (Journal_storage.close store));
    require
      (temporary_backup_files database_path = [])
      "backup failure left a temporary file";
    Sys.remove blocker;
    let reopened, disposition = open_store_exn database_path in
    require
      (disposition = Journal_storage.Restored)
      "backup failure quarantined the canonical store";
    close_exn reopened)
;;

let backup_checks =
  [ "bounded-atomic", test_clean_close_writes_restorable_bounded_atomic_backups
  ; "deduplicate", test_unchanged_basis_deduplicates_backup
  ; "failure-cleanup", test_backup_failure_does_not_quarantine_canonical_store
  ]
;;

let run_backup_checks () =
  match Sys.getenv_opt "JOURNAL_BACKUP_CHECK" with
  | None -> List.iter (fun (_, test) -> test ()) backup_checks
  | Some selected ->
    (match List.assoc_opt selected backup_checks with
     | Some test -> test ()
     | None -> fail "unknown backup check %S" selected)
;;

let require_quarantined database_path =
  let error =
    require_error
      Journal_storage.Error.to_string
      (Journal_storage.open_store ~canonical_path:database_path)
  in
  require
    (Journal_storage.Error.is_path_quarantined error)
    "expected path quarantine, got: %s"
    (Journal_storage.Error.to_string error)
;;

let test_corrupt_root_tombstones_before_same_process_reopen () =
  with_temp_database (fun ~canonical_root:_ ~database_path ->
    let store, _ = open_store_exn database_path in
    close_exn store;
    execute_sql database_path "update kvs set payload = 'not transit' where address = '0'";
    let first_error =
      require_error
        Journal_storage.Error.to_string
        (Journal_storage.open_store ~canonical_path:database_path)
    in
    require
      (not (Journal_storage.Error.is_path_quarantined first_error))
      "the surfaced restore error must be reported before quarantine blocks retries";
    require
      (Option.is_some
         (Journal_process_recovery.find_tombstone ~canonical_path:database_path))
      "restore failure must install a process-lifetime tombstone";
    require_quarantined database_path)
;;

let test_missing_root_with_existing_nodes_is_not_reinitialized () =
  with_temp_database (fun ~canonical_root:_ ~database_path ->
    let store, _ = open_store_exn database_path in
    close_exn store;
    execute_sql database_path "delete from kvs where address = '0'";
    ignore
      (require_error
         Journal_storage.Error.to_string
         (Journal_storage.open_store ~canonical_path:database_path));
    require_quarantined database_path)
;;

let test_lifecycle_outcome_tombstone_survives_service_replacement () =
  with_temp_database (fun ~canonical_root:_ ~database_path ->
    let store, _ = open_store_exn database_path in
    Journal_storage.quarantine store Journal_process_recovery.Lifecycle_outcome_unknown;
    close_exn store;
    require_quarantined database_path)
;;

let test_database_busy_enters_terminal_recovery_state () =
  with_temp_database (fun ~canonical_root:_ ~database_path ->
    let store, _ = open_store_exn database_path in
    let competing = Sqlite3.db_open database_path in
    Fun.protect
      ~finally:(fun () ->
        ignore (Sqlite3.exec competing "ROLLBACK");
        require (Sqlite3.db_close competing) "failed to close competing SQLite handle";
        ignore (Journal_storage.close store))
      (fun () ->
         let begin_result = Sqlite3.exec competing "BEGIN EXCLUSIVE" in
         require
           (Sqlite3.Rc.is_success begin_result)
           "failed to acquire competing SQLite lock: %s"
           (Sqlite3.Rc.to_string begin_result);
         ignore
           (require_error
              Journal_storage.Error.to_string
              (Journal_storage.transact store (boundary_transaction 33)));
         require
           (Journal_storage.state store = Journal_storage.Terminal)
           "database-busy failure did not enter Terminal"))
;;

let () =
  test_first_store_close_reopen_and_restore ();
  test_legacy_database_is_never_opened_or_changed ();
  test_tail_compaction_boundary ();
  run_backup_checks ();
  test_corrupt_root_tombstones_before_same_process_reopen ();
  test_missing_root_with_existing_nodes_is_not_reinitialized ();
  test_lifecycle_outcome_tombstone_survives_service_replacement ();
  test_database_busy_enters_terminal_recovery_state ()
;;
