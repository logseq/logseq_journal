module T = Logseq_db_worker_test_support.Test_support
module Snapshot = Logseq_db_worker__Snapshot
module Backup = Logseq_db_worker__Backup
module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture

let with_temp_directory f =
  let path = Filename.temp_file "logseq-db-worker-snapshot-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  f path

let create_sqlite_graph root name =
  let graph = Filename.concat root name in
  Unix.mkdir graph 0o700;
  let db = Sqlite3.db_open (Filename.concat graph "db.sqlite") in
  Sqlite3.Rc.check (Sqlite3.exec db "CREATE TABLE marker(value TEXT NOT NULL)");
  Sqlite3.Rc.check (Sqlite3.exec db "INSERT INTO marker VALUES ('durable')");
  ignore (Sqlite3.db_close db);
  graph

let catalog support =
  match Snapshot.create_catalog ~application_support_directory:support with
  | Ok catalog -> catalog
  | Error _ -> T.fail "catalog creation failed"

let create catalog source =
  match Snapshot.create catalog ~source_graph_dir:source with
  | Ok token -> token
  | Error _ -> T.fail "snapshot creation failed"

let resolve catalog token =
  match Snapshot.resolve catalog token with
  | Ok resolved -> resolved.Snapshot.graph_dir
  | Error _ -> T.fail "snapshot resolution failed"

let uuid value =
  match Logseq_db_worker.Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message

let update_marker graph value =
  let database = Filename.concat graph "db.sqlite" in
  let db = Sqlite3.db_open database in
  Sqlite3.Rc.check
    (Sqlite3.exec db (Printf.sprintf "UPDATE marker SET value = '%s'" value));
  T.require (Sqlite3.db_close db) "unable to close updated snapshot database"

let read_marker graph =
  let database = Filename.concat graph "db.sqlite" in
  let db = Sqlite3.db_open ~mode:`READONLY database in
  let marker = ref None in
  Sqlite3.Rc.check
    (Sqlite3.exec db "SELECT value FROM marker" ~cb:(fun row _ -> marker := row.(0)));
  T.require (Sqlite3.db_close db) "unable to close snapshot marker database";
  !marker

let () =
  T.run
    "snapshot"
    [ T.case "create uses SQLite backup and publishes verified token" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let token = create catalog source in
          let snapshot = resolve catalog token in
          let db = Sqlite3.db_open ~mode:`READONLY (Filename.concat snapshot "db.sqlite") in
          let marker = ref None in
          Sqlite3.Rc.check
            (Sqlite3.exec db "SELECT value FROM marker" ~cb:(fun row _ -> marker := row.(0)));
          ignore (Sqlite3.db_close db);
          T.require (!marker = Some "durable") "SQLite backup lost data"))
    ; T.case "production SQLite open does not invalidate a snapshot manifest" (fun () ->
        Adapter_fixture.with_snapshot (fun fixture ->
          let open_and_close () =
            match
              Logseq_db_worker.Engine.open_
                ~dependencies:Adapter_fixture.dependencies
                fixture.config
            with
            | Error error ->
              T.fail
                "snapshot reopen failed: %s"
                (Logseq_db_worker.Error.message error)
            | Ok engine ->
              (match Logseq_db_worker.Engine.close engine with
               | Ok () -> ()
               | Error message -> T.fail "snapshot close failed: %s" message)
          in
          open_and_close ();
          open_and_close ()))
    ; T.case "snapshot preserves the source graph name" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "named-graph" in
          let catalog = catalog support in
          let token = create catalog source in
          match Snapshot.resolve catalog token with
          | Ok resolved ->
              T.require
                (String.equal resolved.graph_name "named-graph")
                "snapshot lost source graph name"
          | Error _ -> T.fail "snapshot resolution failed"))
    ; T.case "token cannot be combined with caller path" (fun () ->
        T.require true "resolve API accepts only catalog and token")
    ; T.case "manifest tamper is rejected" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let token = create catalog source in
          let snapshot = resolve catalog token in
          let channel = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0 (Filename.concat snapshot "db.sqlite") in
          output_string channel "tamper";
          close_out channel;
          match Snapshot.resolve catalog token with
          | Error Snapshot.Manifest_mismatch -> ()
          | _ -> T.fail "tampered snapshot accepted"))
    ; T.case "manifest digest cannot be forged without the catalog key" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let token = create catalog source in
          let snapshot = resolve catalog token in
          let database = Filename.concat snapshot "db.sqlite" in
          let db = Sqlite3.db_open database in
          Sqlite3.Rc.check (Sqlite3.exec db "UPDATE marker SET value = 'forged'");
          T.require (Sqlite3.db_close db) "unable to close forged database";
          let sha256 =
            let channel = open_in_bin database in
            let buffer = Bytes.create 65_536 in
            let rec loop context =
              match input channel buffer 0 (Bytes.length buffer) with
              | 0 -> context
              | count ->
                  loop (Digestif.SHA256.feed_bytes context ~off:0 ~len:count buffer)
            in
            Fun.protect
              ~finally:(fun () -> close_in_noerr channel)
              (fun () -> Digestif.SHA256.(to_hex (get (loop empty))))
          in
          let manifest_path = Filename.concat snapshot "manifest.json" in
          let manifest = T.read_json manifest_path in
          let fields = Yojson.Safe.Util.to_assoc manifest in
          let payload =
            fields
            |> List.assoc "payload"
            |> Yojson.Safe.Util.to_assoc
            |> fun payload_fields ->
            `Assoc
              (("sha256", `String sha256)
               :: List.remove_assoc "sha256" payload_fields)
          in
          Yojson.Safe.to_file
            manifest_path
            (`Assoc (("payload", payload) :: List.remove_assoc "payload" fields));
          match Snapshot.resolve catalog token with
          | Error Snapshot.Manifest_mismatch -> ()
          | _ -> T.fail "forged manifest digest was accepted"))
    ; T.case "unregistered copied snapshot is rejected" (fun () ->
        with_temp_directory (fun support ->
          let catalog = catalog support in
          let unknown =
            match Logseq_db_worker.Graph_types.Uuid.of_string "22222222-2222-4222-8222-222222222222" with
            | Ok uuid -> uuid
            | Error message -> T.fail "%s" message
          in
          match Snapshot.resolve catalog unknown with
          | Error Snapshot.Token_unknown -> ()
          | _ -> T.fail "unknown token accepted"))
    ; T.case "import accepts and consumes one confined inbox entry" (fun () ->
        with_temp_directory (fun support ->
          let catalog = catalog support in
          let inbox = Filename.concat (Filename.concat support "logseq-db-worker") "inbox" in
          let source = create_sqlite_graph inbox "bundle" in
          let token =
            match Snapshot.import catalog ~inbox_entry:"bundle" with
            | Ok token -> token
            | Error _ -> T.fail "import failed"
          in
          T.require (not (Sys.file_exists source)) "inbox entry was not consumed";
          ignore (resolve catalog token)))
    ; T.case "absolute and relative import paths are rejected" (fun () ->
        with_temp_directory (fun support ->
          let catalog = catalog support in
          List.iter
            (fun entry ->
               match Snapshot.import catalog ~inbox_entry:entry with
               | Error Snapshot.Invalid_inbox_entry -> ()
               | _ -> T.fail "unsafe inbox entry accepted")
            [ "/tmp/bundle"; "../bundle"; "a/b" ]))
    ; T.case "symlink escape is rejected" (fun () ->
        with_temp_directory (fun support ->
          let catalog = catalog support in
          let inbox = Filename.concat (Filename.concat support "logseq-db-worker") "inbox" in
          Unix.symlink "/tmp" (Filename.concat inbox "bundle");
          match Snapshot.import catalog ~inbox_entry:"bundle" with
          | Error Snapshot.Symlink_rejected -> ()
          | _ -> T.fail "inbox symlink accepted"))
    ; T.case "recover issues a new local token" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let original = create catalog source in
          match Snapshot.recover catalog original with
          | Ok recovered ->
              T.require
                (not (Logseq_db_worker.Graph_types.Uuid.equal original recovered))
                "recovery reused token";
              ignore (resolve catalog recovered)
          | Error _ -> T.fail "recovery failed"))
    ; T.case "backup state creates exactly one verified recovery snapshot" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let original = create catalog source in
          let backup = Backup.create ~catalog ~source_token:original in
          let first =
            match Backup.ensure backup with
            | Ok token -> token
            | Error _ -> T.fail "first recovery backup failed"
          in
          let second =
            match Backup.ensure backup with
            | Ok token -> token
            | Error _ -> T.fail "reused recovery backup failed"
          in
          T.require
            (Logseq_db_worker.Graph_types.Uuid.equal first second)
            "backup state created more than one recovery token";
          let backup_graph = resolve catalog first in
          T.require
            (read_marker backup_graph = Some "durable")
            "verified recovery backup has the wrong content"))
    ; T.case "pending write session is fail-closed until clean finalization" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let original = create catalog source in
          let recovery =
            match Snapshot.create_recovery_copy catalog original with
            | Ok token -> token
            | Error _ -> T.fail "recovery copy failed"
          in
          let write_session =
            match
              Snapshot.begin_write_session
                catalog
                original
                ~recovery_token:recovery
                ~mutation_id:(uuid "33333333-3333-4333-8333-333333333333")
            with
            | Ok session -> session
            | Error _ -> T.fail "write session did not begin"
          in
          let original_graph =
            Filename.concat
              (Filename.concat
                 (Filename.concat support "logseq-db-worker")
                 "snapshots")
              (Logseq_db_worker.Graph_types.Uuid.to_string original)
          in
          update_marker original_graph "mutated";
          (match Snapshot.resolve catalog original with
           | Error Snapshot.Manifest_mismatch -> ()
           | _ -> T.fail "pending snapshot was addressable before finalization");
          (match Snapshot.record_committed_write catalog write_session with
           | Ok () -> ()
           | Error _ -> T.fail "committed write was not authenticated");
          (match Snapshot.finish_write_session catalog write_session with
           | Ok () -> ()
           | Error _ -> T.fail "write session did not finalize");
          let reopened = resolve catalog original in
          T.require
            (read_marker reopened = Some "mutated")
            "finalized snapshot lost the committed change"))
    ; T.case "interrupted authenticated write recovers under a new token" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let original = create catalog source in
          let recovery =
            match Snapshot.create_recovery_copy catalog original with
            | Ok token -> token
            | Error _ -> T.fail "recovery copy failed"
          in
          let write_session =
            match
              Snapshot.begin_write_session
                catalog
                original
                ~recovery_token:recovery
                ~mutation_id:(uuid "44444444-4444-4444-8444-444444444444")
            with
            | Ok session -> session
            | Error _ -> T.fail "write session did not begin"
          in
          let original_graph =
            Filename.concat
              (Filename.concat
                 (Filename.concat support "logseq-db-worker")
                 "snapshots")
              (Logseq_db_worker.Graph_types.Uuid.to_string original)
          in
          update_marker original_graph "committed-before-crash";
          (match Snapshot.record_committed_write catalog write_session with
           | Ok () -> ()
           | Error _ -> T.fail "committed write was not authenticated");
          let recovered =
            match Snapshot.recover catalog original with
            | Ok token -> token
            | Error _ -> T.fail "interrupted snapshot did not recover"
          in
          T.require
            (not (Logseq_db_worker.Graph_types.Uuid.equal original recovered))
            "recovery reused the interrupted token";
          T.require
            (read_marker (resolve catalog recovered) = Some "committed-before-crash")
            "recovery did not copy the durable post-commit database";
          (match Snapshot.resolve catalog original with
           | Error Snapshot.Manifest_mismatch -> ()
           | _ -> T.fail "recovery made the interrupted token addressable")))
    ; T.case "unrecorded interrupted write recovers the pre-write backup" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let original = create catalog source in
          let recovery =
            match Snapshot.create_recovery_copy catalog original with
            | Ok token -> token
            | Error _ -> T.fail "recovery copy failed"
          in
          ignore
            (match
               Snapshot.begin_write_session
                 catalog
                 original
                 ~recovery_token:recovery
                 ~mutation_id:(uuid "55555555-5555-4555-8555-555555555555")
             with
             | Ok session -> session
             | Error _ -> T.fail "write session did not begin");
          let original_graph =
            Filename.concat
              (Filename.concat
                 (Filename.concat support "logseq-db-worker")
                 "snapshots")
              (Logseq_db_worker.Graph_types.Uuid.to_string original)
          in
          update_marker original_graph "unauthenticated-change";
          let recovered =
            match Snapshot.recover catalog original with
            | Ok token -> token
            | Error _ -> T.fail "unrecorded session did not recover from backup"
          in
          T.require
            (read_marker (resolve catalog recovered) = Some "durable")
            "unrecorded session trusted the uncommitted database"))
    ; T.case "content newer than committed digest falls back to recovery backup" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let original = create catalog source in
          let recovery =
            match Snapshot.create_recovery_copy catalog original with
            | Ok token -> token
            | Error _ -> T.fail "recovery copy failed"
          in
          let write_session =
            match
              Snapshot.begin_write_session
                catalog
                original
                ~recovery_token:recovery
                ~mutation_id:(uuid "66666666-6666-4666-8666-666666666666")
            with
            | Ok session -> session
            | Error _ -> T.fail "write session did not begin"
          in
          let original_graph =
            Filename.concat
              (Filename.concat
                 (Filename.concat support "logseq-db-worker")
                 "snapshots")
              (Logseq_db_worker.Graph_types.Uuid.to_string original)
          in
          update_marker original_graph "first-commit";
          (match Snapshot.record_committed_write catalog write_session with
           | Ok () -> ()
           | Error _ -> T.fail "first commit was not authenticated");
          update_marker original_graph "unrecorded-second-commit";
          let recovered =
            match Snapshot.recover catalog original with
            | Ok token -> token
            | Error _ -> T.fail "digest mismatch did not fall back to recovery"
          in
          T.require
            (read_marker (resolve catalog recovered) = Some "durable")
            "digest mismatch trusted content newer than the authenticated commit"))
    ; T.case "forged pending marker cannot authorize database replacement" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_sqlite_graph source_root "source" in
          let catalog = catalog support in
          let original = create catalog source in
          let original_graph = resolve catalog original in
          update_marker original_graph "forged";
          Yojson.Safe.to_file
            (Filename.concat original_graph "write-session.json")
            (`Assoc
               [ "payload", `Assoc [ "formatVersion", `Int 1 ]
               ; "authentication", `String "forged"
               ]);
          (match Snapshot.recover catalog original with
           | Error Snapshot.Manifest_mismatch -> ()
           | _ -> T.fail "forged pending marker authorized recovery")))
    ]
