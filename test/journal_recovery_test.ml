let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_paths test =
  let root = Filename.temp_file "journal-recovery-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let parent = Filename.concat root "logseq_journal" in
  Unix.mkdir parent 0o700;
  let canonical = Filename.concat parent "store.sqlite3" in
  let legacy = Filename.concat parent "journal.sqlite3" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> test canonical legacy)
;;

let test_tombstones_are_scoped_to_the_exact_canonical_store () =
  with_paths (fun canonical legacy ->
    Journal_process_recovery.quarantine
      ~canonical_path:canonical
      Journal_process_recovery.Storage_failure;
    require
      (Option.is_some (Journal_process_recovery.find_tombstone ~canonical_path:canonical))
      "canonical crash boundary was not retained";
    require
      (Option.is_none (Journal_process_recovery.find_tombstone ~canonical_path:legacy))
      "legacy path was discovered or quarantined")
;;

let test_recovery_policy_is_not_supplied_by_the_host_wire () =
  let startup : Journal_startup.t =
    { application_support_root = "/tmp/logseq-journal-recovery"
    ; expected_schema_version = Journal_schema.version
    ; initial_calendar =
        { instant_unix_ms = 1_786_204_800_000L
        ; local_day = 20260809
        ; local_minute_of_day = 0
        ; locale = "en_US"
        ; time_zone_id = "Asia/Shanghai"
        ; utc_offset_seconds = 28_800
        ; generation = 9L
        ; lifecycle_generation = 0L
        }
    ; access_mode = Recovery_only
    ; diagnostic_mode = Operational_only
    }
  in
  let encoded =
    match Journal_startup.encode startup with
    | Ok encoded -> encoded
    | Error error ->
      fail "recovery startup rejected: %s" (Journal_startup.Error.to_string error)
  in
  let decoded =
    match Journal_startup.decode encoded with
    | Ok decoded -> decoded
    | Error error ->
      fail "recovery startup did not decode: %s" (Journal_startup.Error.to_string error)
  in
  require
    (decoded.access_mode = Read_write)
    "host startup wire selected recovery-only policy";
  require
    (String.equal Journal_startup.database_relative_path "logseq_journal/store.sqlite3")
    "recovery startup selected an obsolete store"
;;

let () =
  test_tombstones_are_scoped_to_the_exact_canonical_store ();
  test_recovery_policy_is_not_supplied_by_the_host_wire ()
;;
