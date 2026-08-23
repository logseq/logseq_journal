module T = Logseq_db_worker_test_support.Test_support
module Engine = Logseq_db_worker.Engine
module Snapshot = Logseq_db_worker__Snapshot
module Storage = Logseq_db_worker__Logseq_sqlite_storage
module Session = Logseq_db_worker__Storage_session
module Query = Logseq_db_worker__Query

let page_uuid_text = "11111111-1111-4111-8111-111111111111"
let parent_uuid_text = "22222222-2222-4222-8222-222222222222"
let first_child_uuid_text = "33333333-3333-4333-8333-333333333334"
let second_child_uuid_text = "44444444-4444-4444-8444-444444444445"
let sibling_uuid_text = "55555555-5555-4555-8555-555555555555"
let class_uuid_text = "66666666-6666-4666-8666-666666666666"
let property_uuid_text = "77777777-7777-4777-8777-777777777777"
let property_ident = "user.property/read-test"
let journal_uuid_text = "00000001-2026-0814-0000-000000000000"
let malformed_property_uuid_text = "99999999-9999-4999-8999-999999999999"
let malformed_property_ident = "user.property/malformed"

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_directory f =
  let path = Filename.temp_file "logseq-db-worker-engine-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let create_oracle_graph root graph_name =
  let open Yojson.Safe.Util in
  let graph_dir = Filename.concat root graph_name in
  Unix.mkdir graph_dir 0o700;
  let fixture = T.read_json (T.fixture "storage/logseq-65.33-create-page.json") in
  let database_path = Filename.concat graph_dir "db.sqlite" in
  let db = Sqlite3.db_open database_path in
  Sqlite3.Rc.check (Sqlite3.exec db (fixture |> member "tableSql" |> to_string));
  let statement =
    Sqlite3.prepare db "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
  in
  fixture
  |> member "rows"
  |> to_list
  |> List.iter (fun row ->
    Sqlite3.Rc.check (Sqlite3.reset statement);
    Sqlite3.Rc.check
      (Sqlite3.bind_int64 statement 1 (row |> member "addr" |> to_int |> Int64.of_int));
    Sqlite3.Rc.check
      (Sqlite3.bind_text statement 2 (row |> member "content" |> to_string));
    Sqlite3.Rc.check
      (Sqlite3.bind
         statement
         3
         (match row |> member "addresses" with
          | `Null -> Sqlite3.Data.NULL
          | `String value -> TEXT value
          | _ -> T.fail "oracle fixture has malformed addresses"));
    Sqlite3.Rc.check (Sqlite3.step statement));
  ignore (Sqlite3.finalize statement);
  T.require (Sqlite3.db_close db) "unable to close oracle graph fixture";
  graph_dir
;;

let seed_read_graph graph_dir =
  let connection =
    match Storage.open_database (Filename.concat graph_dir "db.sqlite") with
    | Ok connection -> connection
    | Error _ -> T.fail "unable to open read fixture storage"
  in
  let storage = Storage.datascript_storage connection in
  let db =
    match Storage.restore_database connection with
    | Ok db -> db
    | Error _ -> T.fail "unable to restore read fixture storage"
  in
  let page = Datascript.Lookup_ref ("block/uuid", Datascript.Uuid page_uuid_text) in
  let parent = Datascript.Temp_id "read-parent" in
  let first_child = Datascript.Temp_id "read-first-child" in
  let second_child = Datascript.Temp_id "read-second-child" in
  let sibling = Datascript.Temp_id "read-sibling" in
  let class_page = Datascript.Temp_id "read-class" in
  let property_page = Datascript.Temp_id "read-property" in
  let ident value = Datascript.Lookup_ref ("db/ident", Datascript.Keyword value) in
  let block id uuid title parent_ref order =
    [ Datascript.Add (id, "block/uuid", Uuid uuid)
    ; Add (id, "block/title", String title)
    ; Add (id, "block/parent", Ref_to parent_ref)
    ; Add (id, "block/page", Ref_to page)
    ; Add (id, "block/order", String order)
    ; Add (id, "block/created-at", Int 1_704_067_200_000)
    ; Add (id, "block/updated-at", Int 1_704_067_200_000)
    ]
  in
  let transaction =
    block parent parent_uuid_text "Parent" page "a0"
    @ block first_child first_child_uuid_text "First child" parent "a0"
    @ block second_child second_child_uuid_text "Second child" parent "a1"
    @ block sibling sibling_uuid_text "Sibling" page "a1"
    @ [ Datascript.Add (page, "block/parent", Ref_to page)
      ; Add (page, "block/page", Ref_to page)
      ; Add (first_child, "block/refs", Ref_to sibling)
      ; Add (first_child, "block/tags", Ref_to (ident "logseq.class/Task"))
      ; Add
          ( first_child
          , "logseq.property/status"
          , Ref_to (ident "logseq.property/status.todo") )
      ; Add (class_page, "block/uuid", Uuid class_uuid_text)
      ; Add (class_page, "block/name", String "oracle class")
      ; Add (class_page, "block/title", String "Oracle Class")
      ; Add (class_page, "block/created-at", Int 1_704_067_200_000)
      ; Add (class_page, "block/updated-at", Int 1_704_067_200_000)
      ; Add (class_page, "block/tags", Ref_to (ident "logseq.class/Tag"))
      ; Add (property_page, "block/uuid", Uuid property_uuid_text)
      ; Add (property_page, "block/name", String "read test")
      ; Add (property_page, "block/title", String "Read test")
      ; Add (property_page, "block/created-at", Int 1_704_067_200_000)
      ; Add (property_page, "block/updated-at", Int 1_704_067_200_000)
      ; Add (property_page, "block/tags", Ref_to (ident "logseq.class/Property"))
      ; Add (property_page, "db/ident", Keyword property_ident)
      ; Add (property_page, "db/valueType", Keyword "db.type/string")
      ; Add (property_page, "db/cardinality", Keyword "db.cardinality/one")
      ; Add (property_page, "logseq.property/type", Keyword "default")
      ; Add (parent, property_ident, String "Read value")
      ]
  in
  let session =
    Session.create
      ~db
      ~tail:(Datascript.Storage.restore_tail_groups storage)
      ~callbacks:(Storage.connection_callbacks connection)
  in
  let staged =
    match Session.stage_transact session transaction with
    | Ok staged -> staged
    | Error _ -> T.fail "unable to stage read fixture"
  in
  (match Session.commit_staged session staged with
   | Ok () -> ()
   | Error _ -> T.fail "unable to persist read fixture");
  (match Session.close session with
   | Ok () -> ()
   | Error _ -> T.fail "unable to close read fixture storage");
  let reopened =
    match Storage.open_database (Filename.concat graph_dir "db.sqlite") with
    | Ok connection -> connection
    | Error _ -> T.fail "unable to reopen read fixture storage"
  in
  (match Storage.validate_storage_header reopened with
   | Ok () -> ()
   | Error (Storage.Corrupt_storage message | Pragma_mismatch message) ->
     T.fail "read fixture storage is invalid: %s" message
   | Error _ -> T.fail "read fixture storage is invalid");
  match Storage.close (Storage.connection_callbacks reopened) with
  | Ok () -> ()
  | Error _ -> T.fail "unable to close validated read fixture"
;;

let transact_graph graph_dir transaction =
  let connection =
    match Storage.open_database (Filename.concat graph_dir "db.sqlite") with
    | Ok connection -> connection
    | Error _ -> T.fail "unable to open graph transaction fixture"
  in
  let storage = Storage.datascript_storage connection in
  let db =
    match Storage.restore_database connection with
    | Ok db -> db
    | Error _ -> T.fail "unable to restore graph transaction fixture"
  in
  let session =
    Session.create
      ~db
      ~tail:(Datascript.Storage.restore_tail_groups storage)
      ~callbacks:(Storage.connection_callbacks connection)
  in
  let staged =
    match Session.stage_transact session transaction with
    | Ok staged -> staged
    | Error _ -> T.fail "unable to stage graph transaction fixture"
  in
  (match Session.commit_staged session staged with
   | Ok () -> ()
   | Error _ -> T.fail "unable to persist graph transaction fixture");
  match Session.close session with
  | Ok () -> ()
  | Error _ -> T.fail "unable to close graph transaction fixture"
;;

let config support token =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Snapshot { token })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:262_144
      ~default_page_size:50
  with
  | Ok config -> config
  | Error message -> T.fail "invalid engine test config: %s" message
;;

let native_config support graph_dir =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Native_local_graph { graph_name = Filename.basename graph_dir; graph_dir })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:262_144
      ~default_page_size:50
  with
  | Ok config -> config
  | Error message -> T.fail "invalid native engine test config: %s" message
;;

let create_native_graph support =
  let source_root = Filename.concat support "native-graphs" in
  Unix.mkdir source_root 0o700;
  let graph = create_oracle_graph source_root "native-graph" in
  seed_read_graph graph;
  graph
;;

let create_inbox_graph support graph_name =
  let catalog =
    match Snapshot.create_catalog ~application_support_directory:support with
    | Ok catalog -> catalog
    | Error _ -> T.fail "unable to create native fallback catalog"
  in
  ignore catalog;
  let inbox = Filename.concat support "logseq-db-worker/inbox" in
  let graph = create_oracle_graph inbox graph_name in
  seed_read_graph graph;
  graph
;;

let ios_graph_path support graph_name =
  Filename.concat (Filename.concat support "graphs") graph_name
;;

let create_ios_native_graph support graph_name =
  let graphs = Filename.concat support "graphs" in
  if not (Sys.file_exists graphs) then Unix.mkdir graphs 0o700;
  let graph = create_oracle_graph graphs graph_name in
  seed_read_graph graph;
  graph
;;

let client_ops_database graph =
  let directory = Filename.concat graph "client-ops-" in
  if not (Sys.file_exists directory) then Unix.mkdir directory 0o700;
  Filename.concat directory "db.sqlite"
;;

let seed_client_ops_history graph =
  let db = Sqlite3.db_open (client_ops_database graph) in
  Sqlite3.Rc.check (Sqlite3.exec db "CREATE TABLE client_ops(id INTEGER PRIMARY KEY)");
  Sqlite3.Rc.check (Sqlite3.exec db "INSERT INTO client_ops VALUES(1)");
  T.require (Sqlite3.db_close db) "unable to close client-operation history fixture"
;;

let seed_empty_client_ops graph =
  let db = Sqlite3.db_open (client_ops_database graph) in
  Sqlite3.Rc.check (Sqlite3.exec db "CREATE TABLE client_ops(id INTEGER PRIMARY KEY)");
  Sqlite3.Rc.check (Sqlite3.exec db "CREATE TABLE sync_conflicts(id INTEGER PRIMARY KEY)");
  Sqlite3.Rc.check
    (Sqlite3.exec db "CREATE TABLE sync_meta(key TEXT PRIMARY KEY, value TEXT)");
  T.require (Sqlite3.db_close db) "unable to close empty client-operation fixture"
;;

let seed_client_ops_graph_uuid graph =
  let db = Sqlite3.db_open (client_ops_database graph) in
  Sqlite3.Rc.check
    (Sqlite3.exec db "CREATE TABLE sync_meta(key TEXT PRIMARY KEY, value TEXT)");
  Sqlite3.Rc.check
    (Sqlite3.exec
       db
       "INSERT INTO sync_meta VALUES('graph-uuid', \
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')");
  T.require (Sqlite3.db_close db) "unable to close client-operation RTC fixture"
;;

let dependencies =
  Engine.
    { clocks =
        { epoch_ms = (fun () -> 1_704_067_200_000L)
        ; monotonic_ns = (fun () -> 1_000_000L)
        }
    ; cursor_authentication_key = Bytes.make 32 'k'
    ; crypto = Logseq_db_worker.Sync_e2ee.unavailable_crypto
    ; unlock_graph_key =
        (fun ~user_id:_ ~encrypted_graph_key:_ -> Error "crypto unavailable")
    }
;;

let require_corrupt_native_open support graph =
  match Engine.open_ ~dependencies (native_config support graph) with
  | Error error ->
    T.require
      (Logseq_db_worker.Error.code error = Corrupt_storage)
      "invalid native graph returned the wrong error"
  | Ok engine ->
    ignore (Engine.close engine);
    T.fail "invalid native graph opened"
;;

let require_native_open support graph =
  match Engine.open_ ~dependencies (native_config support graph) with
  | Ok engine ->
    T.require (Engine.close engine = Ok ()) "unable to close admitted native graph"
  | Error error ->
    T.fail
      "lightweight startup validation rejected the native graph: %s"
      (Logseq_db_worker.Error.message error)
;;

let remove_storage_tail graph =
  let db = Sqlite3.db_open (Filename.concat graph "db.sqlite") in
  Sqlite3.Rc.check (Sqlite3.exec db "DELETE FROM kvs WHERE addr = 1");
  T.require (Sqlite3.db_close db) "unable to close incomplete storage fixture"
;;

type engine_harness =
  { engine : Engine.t
  ; resolved : Snapshot.resolved
  ; token : Logseq_db_worker.Graph_types.Uuid.t
  ; catalog : Snapshot.catalog
  ; support : string
  }

let install_mutation_write_failure graph_dir =
  let db = Sqlite3.db_open (Filename.concat graph_dir "db.sqlite") in
  Sqlite3.Rc.check
    (Sqlite3.exec
       db
       "CREATE TRIGGER fail_mutation_write BEFORE UPDATE ON kvs BEGIN SELECT \
        RAISE(ABORT, 'injected mutation write failure'); END");
  T.require (Sqlite3.db_close db) "unable to install mutation write failure"
;;

let with_snapshot_engine_context
      ?(fail_mutation_writes = false)
      ?(prepare_source = fun _graph_dir -> ())
      f
  =
  with_temp_directory (fun support ->
    let source_root = Filename.concat support "sources" in
    Unix.mkdir source_root 0o700;
    let source = create_oracle_graph source_root "oracle-graph" in
    seed_read_graph source;
    if fail_mutation_writes then install_mutation_write_failure source;
    prepare_source source;
    let catalog =
      match Snapshot.create_catalog ~application_support_directory:support with
      | Ok catalog -> catalog
      | Error _ -> T.fail "unable to create engine snapshot catalog"
    in
    let token =
      match Snapshot.create catalog ~source_graph_dir:source with
      | Ok token -> token
      | Error _ -> T.fail "unable to create engine snapshot"
    in
    let resolved =
      match Snapshot.resolve catalog token with
      | Ok resolved -> resolved
      | Error _ -> T.fail "unable to resolve engine snapshot"
    in
    let engine =
      match Engine.open_ ~dependencies (config support token) with
      | Ok engine -> engine
      | Error error ->
        T.fail
          "valid snapshot did not open: %s (%s)"
          (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code error))
          (Logseq_db_worker.Error.message error)
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () -> f { engine; resolved; token; catalog; support }))
;;

let with_snapshot_engine f =
  with_snapshot_engine_context (fun harness -> f harness.engine harness.resolved)
;;

let request_id =
  match
    Logseq_db_worker.Graph_types.Uuid.of_string "33333333-3333-4333-8333-333333333333"
  with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message
;;

let uuid value =
  match Logseq_db_worker.Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message
;;

let execute_read engine command =
  Engine.execute
    engine
    Logseq_db_worker.Protocol.{ api_version; request_id; command = Read command }
;;

let execute_save
      ?(request_id = request_id)
      ?(mutation_id = uuid "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
      ?expected_basis
      engine
      title
  =
  let expected_basis =
    match expected_basis, Engine.basis engine with
    | Some basis, _ -> basis
    | None, Some basis -> basis
    | None, None -> T.fail "engine has no current basis"
  in
  Engine.execute
    engine
    Logseq_db_worker.Protocol.
      { api_version
      ; request_id
      ; command =
          Mutate
            (Structural
               (Save_block
                  { block = uuid parent_uuid_text
                  ; title
                  ; context = { mutation_id; expected_basis }
                  }))
      }
;;

let execute_structural ?(request_id = request_id) ~mutation_id engine build =
  let expected_basis =
    match Engine.basis engine with
    | Some basis -> basis
    | None -> T.fail "engine has no current basis"
  in
  Engine.execute
    engine
    Logseq_db_worker.Protocol.
      { api_version
      ; request_id
      ; command = Mutate (Structural (build { mutation_id; expected_basis }))
      }
;;

let require_applied_once previous = function
  | Logseq_db_worker.Protocol.Succeeded
      { basis
      ; success = Mutation_result { status = Applied; basis_before; basis_after; _ }
      ; _
      } ->
    T.require
      (basis_before = previous)
      "structural mutation reported the wrong basisBefore";
    T.require
      (basis_after = Int64.succ previous && basis = basis_after)
      "structural mutation did not advance basis exactly once";
    basis_after
  | Failed failure ->
    T.fail
      "structural mutation failed: %s (%s)"
      (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code failure.error))
      (Logseq_db_worker.Error.message failure.error)
  | _ -> T.fail "structural mutation did not return Applied"
;;

let snapshot_entry_count support =
  let snapshots =
    Filename.concat (Filename.concat support "logseq-db-worker") "snapshots"
  in
  Sys.readdir snapshots
  |> Array.to_list
  |> List.filter (fun name -> String.length name = 36)
  |> List.length
;;

let garbage_address_base = 2_000_000

let insert_unreachable_rows ?(payload_bytes = 0) graph_dir count =
  let db = Sqlite3.db_open (Filename.concat graph_dir "db.sqlite") in
  let statement =
    Sqlite3.prepare db "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, NULL)"
  in
  let payload =
    if payload_bytes = 0 then "unreachable" else String.make payload_bytes 'x'
  in
  Sqlite3.Rc.check (Sqlite3.exec db "BEGIN IMMEDIATE");
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize statement))
    (fun () ->
       for index = 0 to count - 1 do
         Sqlite3.Rc.check (Sqlite3.reset statement);
         Sqlite3.Rc.check (Sqlite3.bind_int statement 1 (garbage_address_base + index));
         Sqlite3.Rc.check (Sqlite3.bind_text statement 2 payload);
         Sqlite3.Rc.check (Sqlite3.step statement)
       done);
  Sqlite3.Rc.check (Sqlite3.exec db "COMMIT");
  T.require (Sqlite3.db_close db) "unable to close unreachable-address fixture"
;;

let unreachable_address_count graph_dir =
  let db = Sqlite3.db_open (Filename.concat graph_dir "db.sqlite") in
  let count = ref None in
  Sqlite3.Rc.check
    (Sqlite3.exec
       db
       (Printf.sprintf "SELECT count(*) FROM kvs WHERE addr >= %d" garbage_address_base)
       ~cb:(fun row _ -> count := Option.map int_of_string row.(0)));
  T.require (Sqlite3.db_close db) "unable to close unreachable-address counter";
  match !count with
  | Some count -> count
  | None -> T.fail "unable to count unreachable addresses"
;;

let physical_unreachable_address_count graph_dir =
  let connection =
    match Storage.open_database (Filename.concat graph_dir "db.sqlite") with
    | Ok connection -> connection
    | Error _ -> T.fail "unable to open unreachable-address fixture"
  in
  let count =
    match Storage.garbage_stats (Storage.connection_callbacks connection) with
    | Ok stats -> stats.unreachable_address_count
    | Error _ -> T.fail "unable to derive fixture reachability"
  in
  (match Storage.close (Storage.connection_callbacks connection) with
   | Ok () -> ()
   | Error _ -> T.fail "unable to close unreachable-address fixture");
  count
;;

let fill_unreachable_addresses graph_dir target =
  let existing = physical_unreachable_address_count graph_dir in
  T.require
    (existing < target)
    "fixture already exceeds the requested GC threshold: %d >= %d"
    existing
    target;
  let added = target - existing in
  insert_unreachable_rows graph_dir added;
  added
;;

let install_gc_delete_failure graph_dir =
  let db = Sqlite3.db_open (Filename.concat graph_dir "db.sqlite") in
  Sqlite3.Rc.check
    (Sqlite3.exec
       db
       (Printf.sprintf
          "CREATE TRIGGER fail_gc_delete BEFORE DELETE ON kvs WHEN OLD.addr >= %d BEGIN \
           SELECT RAISE(ABORT, 'injected GC delete failure'); END"
          garbage_address_base));
  T.require (Sqlite3.db_close db) "unable to install GC delete failure"
;;

let recovery_token graph_dir =
  let open Yojson.Safe.Util in
  Yojson.Safe.from_file (Filename.concat graph_dir "write-session.json")
  |> member "payload"
  |> member "recoveryToken"
  |> to_string
;;

let () =
  T.run
    "engine open"
    [ T.case "snapshot open owns the graph before SQLite use" (fun () ->
        with_snapshot_engine (fun _engine resolved ->
          T.require
            (Sys.file_exists
               (Filename.concat resolved.Snapshot.graph_dir "db-worker.lock"))
            "snapshot owner sentinel is missing"))
    ; T.case "missing iOS native graph imports its same-name inbox entry" (fun () ->
        with_temp_directory (fun support ->
          let graph_name = "logseq_journal" in
          let graph = ios_graph_path support graph_name in
          let inbox = create_inbox_graph support graph_name in
          let engine =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "missing iOS native graph did not import its inbox fallback: %s"
                (Logseq_db_worker.Error.message error)
          in
          Fun.protect
            ~finally:(fun () -> ignore (Engine.close engine))
            (fun () ->
               T.require
                 (Sys.file_exists (Filename.concat graph "db.sqlite"))
                 "native fallback did not publish db.sqlite";
               T.require
                 (not (Sys.file_exists inbox))
                 "successful native fallback did not consume the inbox entry";
               match execute_read engine Graph_info with
               | Succeeded { success = Graph_info_result info; _ } ->
                 T.require
                   (info.mode = Logseq_db_worker.Graph_types.Native_read_write)
                   "imported native fallback opened in snapshot mode";
                 T.require
                   (String.equal info.graph_dir (Unix.realpath graph))
                   "imported native fallback reported the wrong graph directory"
               | _ -> T.fail "imported native fallback Graph_info failed")))
    ; T.case "corrupt iOS native graph is replaced from its inbox entry" (fun () ->
        with_temp_directory (fun support ->
          let graph_name = "logseq_journal" in
          let graph = create_ios_native_graph support graph_name in
          remove_storage_tail graph;
          let inbox = create_inbox_graph support graph_name in
          let engine =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "corrupt iOS native graph did not import its inbox fallback: %s"
                (Logseq_db_worker.Error.message error)
          in
          Fun.protect
            ~finally:(fun () -> ignore (Engine.close engine))
            (fun () ->
               T.require
                 (not (Sys.file_exists inbox))
                 "successful corrupt-native fallback did not consume the inbox entry";
               match execute_read engine Graph_info with
               | Succeeded { success = Graph_info_result info; _ } ->
                 T.require
                   (info.mode = Logseq_db_worker.Graph_types.Native_read_write)
                   "replacement graph opened in snapshot mode"
               | _ -> T.fail "replacement native Graph_info failed")))
    ; T.case "valid iOS native graph ignores a pending inbox entry" (fun () ->
        with_temp_directory (fun support ->
          let graph_name = "logseq_journal" in
          let graph = create_ios_native_graph support graph_name in
          let inbox = create_inbox_graph support graph_name in
          let parent =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid parent_uuid_text)
          in
          transact_graph
            inbox
            [ Datascript.Add (parent, "block/title", Datascript.String "Inbox replacement")
            ];
          let engine =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "valid iOS native graph did not open: %s"
                (Logseq_db_worker.Error.message error)
          in
          Fun.protect
            ~finally:(fun () -> ignore (Engine.close engine))
            (fun () ->
               T.require
                 (Sys.file_exists inbox)
                 "valid native graph consumed an unused inbox entry";
               match
                 execute_read engine (Get_block { block = uuid parent_uuid_text })
               with
               | Succeeded { success = Block_result block; _ } ->
                 T.require
                   (String.equal block.title "Parent")
                   "valid native graph was replaced by its inbox entry"
               | _ -> T.fail "valid native graph Get_block failed")))
    ; T.case "locked iOS native graph never falls back to inbox" (fun () ->
        with_temp_directory (fun support ->
          let graph_name = "logseq_journal" in
          let graph = create_ios_native_graph support graph_name in
          let inbox = create_inbox_graph support graph_name in
          let owner =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "unable to hold iOS native graph ownership: %s"
                (Logseq_db_worker.Error.message error)
          in
          Fun.protect
            ~finally:(fun () -> ignore (Engine.close owner))
            (fun () ->
               match Engine.open_ ~dependencies (native_config support graph) with
               | Error error ->
                 T.require
                   (Logseq_db_worker.Error.code error = Graph_locked)
                   "locked native graph returned the wrong error";
                 T.require
                   (Sys.file_exists inbox)
                   "locked native graph consumed its inbox entry"
               | Ok engine ->
                 ignore (Engine.close engine);
                 T.fail "locked native graph was replaced from inbox")))
    ; T.case "invalid inbox cannot replace a corrupt iOS native graph" (fun () ->
        with_temp_directory (fun support ->
          let graph_name = "logseq_journal" in
          let graph = create_ios_native_graph support graph_name in
          remove_storage_tail graph;
          let catalog =
            match Snapshot.create_catalog ~application_support_directory:support with
            | Ok catalog -> catalog
            | Error _ -> T.fail "unable to create invalid inbox catalog"
          in
          ignore catalog;
          let inbox = Filename.concat support "logseq-db-worker/inbox" in
          Unix.symlink
            (Filename.concat support "outside-inbox")
            (Filename.concat inbox graph_name);
          require_corrupt_native_open support graph;
          T.require
            (Sys.file_exists (Filename.concat graph "db.sqlite"))
            "invalid inbox removed the corrupt native graph"))
    ; T.case "non-iOS native graph never falls back to inbox" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          remove_storage_tail graph;
          let inbox = create_inbox_graph support (Filename.basename graph) in
          require_corrupt_native_open support graph;
          T.require
            (Sys.file_exists inbox)
            "non-iOS native graph consumed an inbox fallback"))
    ; T.case
        "native graph opens exclusively and reports native read-write mode"
        (fun () ->
           with_temp_directory (fun support ->
             let graph = create_native_graph support in
             let engine =
               match Engine.open_ ~dependencies (native_config support graph) with
               | Ok engine -> engine
               | Error error ->
                 T.fail
                   "native graph did not open: %s"
                   (Logseq_db_worker.Error.message error)
             in
             Fun.protect
               ~finally:(fun () -> ignore (Engine.close engine))
               (fun () ->
                  match execute_read engine Graph_info with
                  | Succeeded { success = Graph_info_result info; _ } ->
                    T.require
                      (info.mode = Logseq_db_worker.Graph_types.Native_read_write)
                      "native graph reported the wrong mode";
                    T.require
                      (String.equal info.graph_dir (Unix.realpath graph))
                      "native graph reported the wrong directory"
                  | _ -> T.fail "native Graph_info failed")))
    ; T.case "startup does not scan non-page self-parent relationships" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let parent =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid parent_uuid_text)
          in
          transact_graph
            graph
            [ Datascript.Add (parent, "block/parent", Datascript.Ref_to parent) ];
          require_native_open support graph))
    ; T.case "page self-parent may omit block/page" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let page =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid page_uuid_text)
          in
          transact_graph graph [ Datascript.RetractAttr (page, "block/page") ];
          let engine =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "native page root without block/page did not open: %s"
                (Logseq_db_worker.Error.message error)
          in
          T.require
            (Engine.close engine = Ok ())
            "unable to close native page root fixture"))
    ; T.case "startup does not scan page target relationships" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let page =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid page_uuid_text)
          in
          let parent =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid parent_uuid_text)
          in
          transact_graph
            graph
            [ Datascript.Add (page, "block/page", Datascript.Ref_to parent) ];
          require_native_open support graph))
    ; T.case "startup does not scan parent cycles" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let parent =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid parent_uuid_text)
          in
          let child =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid first_child_uuid_text)
          in
          transact_graph
            graph
            [ Datascript.Add (parent, "block/parent", Datascript.Ref_to child) ];
          require_native_open support graph))
    ; T.case "startup does not scan duplicate sibling orders" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let first_child =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid first_child_uuid_text)
          in
          transact_graph
            graph
            [ Datascript.Add (first_child, "block/order", Datascript.String "a1") ];
          require_native_open support graph))
    ; T.case
        "first native mutation backs up, invalidates sidecars, and persists"
        (fun () ->
           with_temp_directory (fun support ->
             let graph = create_native_graph support in
             let engine =
               match Engine.open_ ~dependencies (native_config support graph) with
               | Ok engine -> engine
               | Error error ->
                 T.fail
                   "native graph did not open: %s"
                   (Logseq_db_worker.Error.message error)
             in
             Fun.protect
               ~finally:(fun () -> ignore (Engine.close engine))
               (fun () ->
                  T.require
                    (snapshot_entry_count support = 0)
                    "native open created an eager backup";
                  (match execute_save engine "Native persisted title" with
                   | Succeeded { success = Mutation_result { status = Applied; _ }; _ } ->
                     ()
                   | _ -> T.fail "native Save_block failed");
                  T.require
                    (snapshot_entry_count support = 1)
                    "first native mutation did not create exactly one recovery backup";
                  (match
                     Yojson.Safe.from_file
                       (Filename.concat graph ".logseq-db-worker.derived-sidecars.json")
                   with
                   | `Assoc fields ->
                     T.require
                       (List.assoc_opt "formatVersion" fields = Some (`Int 1))
                       "native sidecar marker version mismatch";
                     T.require
                       (match List.assoc_opt "ftsRequiredGeneration" fields with
                        | Some (`String generation) -> String.length generation = 36
                        | _ -> false)
                       "native FTS invalidation is missing";
                     T.require
                       (match List.assoc_opt "vectorRequiredGeneration" fields with
                        | Some (`String generation) -> String.length generation = 36
                        | _ -> false)
                       "native vector invalidation is missing"
                   | _ -> T.fail "native sidecar marker is malformed");
                  match
                    execute_read engine (Get_block { block = uuid parent_uuid_text })
                  with
                  | Succeeded { success = Block_result block; _ } ->
                    T.require
                      (String.equal block.title "Native persisted title")
                      "native mutation was not installed"
                  | _ -> T.fail "native mutation was not readable")))
    ; T.case "empty client-operation store is admitted for native writes" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          seed_empty_client_ops graph;
          match Engine.open_ ~dependencies (native_config support graph) with
          | Ok engine -> ignore (Engine.close engine)
          | Error error ->
            T.fail
              "empty client-operation store was rejected: %s"
              (Logseq_db_worker.Error.message error)))
    ; T.case "non-empty client-operation history is rejected explicitly" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          seed_client_ops_history graph;
          match Engine.open_ ~dependencies (native_config support graph) with
          | Error error ->
            T.require
              (Logseq_db_worker.Error.code error = Unsupported_semantics)
              "client-operation history returned the wrong error";
            T.require
              (String.equal
                 (Logseq_db_worker.Error.message error)
                 "Native graph client-operation history is not supported.")
              "client-operation history used the generic native-disabled error"
          | Ok engine ->
            ignore (Engine.close engine);
            T.fail "non-empty client-operation history was admitted"))
    ; T.case "client-operation graph UUID is rejected as ambiguous sync state" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          seed_client_ops_graph_uuid graph;
          match Engine.open_ ~dependencies (native_config support graph) with
          | Error error ->
            T.require
              (Logseq_db_worker.Error.code error = Ambiguous_sync_state)
              "client-operation graph UUID returned the wrong error"
          | Ok engine ->
            ignore (Engine.close engine);
            T.fail "client-operation graph UUID was admitted"))
    ; T.case "ambiguous client-operation path fails closed" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          Unix.symlink
            (Filename.concat support "missing-client-operations")
            (Filename.concat graph "client-ops-");
          match Engine.open_ ~dependencies (native_config support graph) with
          | Error error ->
            T.require
              (Logseq_db_worker.Error.code error = Unsupported_semantics)
              "ambiguous client-operation path returned the wrong error"
          | Ok engine ->
            ignore (Engine.close engine);
            T.fail "ambiguous client-operation path was admitted"))
    ; T.case "malformed native sidecar marker blocks the main mutation" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let engine =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "native graph did not open: %s"
                (Logseq_db_worker.Error.message error)
          in
          Fun.protect
            ~finally:(fun () -> ignore (Engine.close engine))
            (fun () ->
               let basis = Option.get (Engine.basis engine) in
               Yojson.Safe.to_file
                 (Filename.concat graph ".logseq-db-worker.derived-sidecars.json")
                 (`Assoc []);
               (match execute_save engine "Must not reach native DB" with
                | Failed failure ->
                  T.require
                    (Logseq_db_worker.Error.code failure.error = Corrupt_storage)
                    "malformed sidecar marker returned the wrong error"
                | _ -> T.fail "malformed sidecar marker did not block mutation");
               T.require
                 (Engine.basis engine = Some basis)
                 "blocked native mutation advanced basis";
               match
                 execute_read engine (Get_block { block = uuid parent_uuid_text })
               with
               | Succeeded { success = Block_result block; _ } ->
                 T.require
                   (String.equal block.title "Parent")
                   "blocked native mutation changed data"
               | _ -> T.fail "native graph was unreadable after blocked mutation")))
    ; T.case "native ownership tamper terminalizes before mutation" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let engine =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "native graph did not open: %s"
                (Logseq_db_worker.Error.message error)
          in
          Yojson.Safe.to_file (Filename.concat graph "db-worker.lock") (`Assoc []);
          let terminalized =
            try
              ignore (execute_save engine "Must not commit after tamper");
              false
            with
            | Engine.Fatal_storage_error _ -> true
          in
          T.require terminalized "native ownership tamper was not terminal";
          T.require
            (Engine.basis engine = None)
            "tampered native Engine still exposes a basis";
          ignore (Engine.close engine)))
    ; T.case "Graph_info reports admitted official graph facts" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          let request =
            Logseq_db_worker.Protocol.
              { api_version; request_id; command = Read Graph_info }
          in
          match Engine.execute engine request with
          | Succeeded { success = Graph_info_result info; basis; _ } ->
            T.require (String.equal info.graph_name "oracle-graph") "wrong graph name";
            T.require (info.schema = { major = 65; minor = 33 }) "wrong schema";
            T.require (basis = info.basis && basis > 0L) "wrong graph basis";
            T.require
              (List.mem
                 Logseq_db_worker.Graph_types.Ownership_verified
                 info.admission_facts)
              "ownership admission fact is missing"
          | _ -> T.fail "Graph_info did not succeed"))
    ; T.case "Get_page resolves UUID and typed normalized name" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          let check selector =
            match execute_read engine (Get_page { page = selector }) with
            | Succeeded { success = Page_result page; _ } ->
              T.require
                (Logseq_db_worker.Graph_types.Uuid.equal page.uuid (uuid page_uuid_text))
                "Get_page returned the wrong UUID";
              T.require
                (String.equal page.name "oracle page")
                "Get_page returned the wrong name";
              T.require
                (String.equal page.title "Oracle Page")
                "Get_page returned the wrong title";
              T.require (page.kind = Ordinary_page) "Get_page returned the wrong kind"
            | _ -> T.fail "Get_page did not succeed"
          in
          check (Page_by_uuid (uuid page_uuid_text));
          check (Page_by_name { name = "ORACLE PAGE"; kind = Only_ordinary_pages })))
    ; T.case "Get_block returns the bounded structural projection" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          match execute_read engine (Get_block { block = uuid parent_uuid_text }) with
          | Succeeded { success = Block_result block; _ } ->
            T.require
              (String.equal block.title "Parent")
              "Get_block returned the wrong title";
            T.require
              (Logseq_db_worker.Graph_types.Uuid.equal block.parent (uuid page_uuid_text))
              "Get_block returned the wrong parent";
            T.require
              (Logseq_db_worker.Graph_types.Uuid.equal block.page (uuid page_uuid_text))
              "Get_block returned the wrong page";
            T.require (String.equal block.order "a0") "Get_block returned the wrong order";
            T.require
              (List.exists
                 (fun (property : Logseq_db_worker.Graph_types.property_summary) ->
                    String.equal property.ident property_ident
                    && property.values = [ Default_value "Read value" ])
                 block.properties)
              "Get_block omitted its typed property summary"
          | _ -> T.fail "Get_block did not succeed"))
    ; T.case "Get_children paginates in Logseq order" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          let first =
            match
              execute_read
                engine
                (Get_children { parent = uuid page_uuid_text; limit = 1; cursor = None })
            with
            | Succeeded { success = Children_result page; _ } -> page
            | _ -> T.fail "first Get_children page did not succeed"
          in
          (match first.items with
           | [ block ] ->
             T.require (String.equal block.title "Parent") "wrong first child"
           | _ -> T.fail "wrong first child page size");
          let cursor =
            match first.continuation with
            | Some cursor -> cursor
            | None -> T.fail "Get_children omitted its continuation"
          in
          match
            execute_read
              engine
              (Get_children
                 { parent = uuid page_uuid_text; limit = 1; cursor = Some cursor })
          with
          | Succeeded { success = Children_result page; _ } ->
            (match page.items with
             | [ block ] ->
               T.require (String.equal block.title "Sibling") "wrong second child"
             | _ -> T.fail "wrong second child page size");
            T.require (page.continuation = None) "terminal page returned a cursor"
          | _ -> T.fail "second Get_children page did not succeed"))
    ; T.case "collection cursors bind query fingerprint and basis" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          let cursor =
            match
              execute_read
                engine
                (Get_children { parent = uuid page_uuid_text; limit = 1; cursor = None })
            with
            | Succeeded { success = Children_result { continuation = Some cursor; _ }; _ }
              -> cursor
            | _ -> T.fail "unable to obtain a collection cursor"
          in
          (match
             execute_read
               engine
               (Get_siblings
                  { block = uuid first_child_uuid_text; limit = 1; cursor = Some cursor })
           with
           | Failed failure ->
             T.require
               (Logseq_db_worker.Error.code failure.error = Conflict)
               "filter-changed cursor returned the wrong error"
           | _ -> T.fail "cursor crossed query fingerprints");
          let payload =
            match
              Query.decode_cursor
                ~key:dependencies.cursor_authentication_key
                ~now_ms:(dependencies.clocks.epoch_ms ())
                cursor
            with
            | Ok payload -> payload
            | Error _ -> T.fail "unable to decode generated cursor"
          in
          let stale =
            match
              Query.encode_cursor
                ~key:dependencies.cursor_authentication_key
                { payload with basis = Int64.pred payload.basis }
            with
            | Ok cursor -> cursor
            | Error _ -> T.fail "unable to encode stale-basis cursor"
          in
          match
            execute_read
              engine
              (Get_children
                 { parent = uuid page_uuid_text; limit = 1; cursor = Some stale })
          with
          | Failed failure ->
            T.require
              (Logseq_db_worker.Error.code failure.error = Conflict)
              "stale-basis cursor returned the wrong error"
          | _ -> T.fail "stale-basis cursor was accepted"))
    ; T.case "Get_page_tree returns bounded preorder depths" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          match
            execute_read
              engine
              (Get_page_tree
                 { page = uuid page_uuid_text
                 ; maximum_depth = 2
                 ; limit = 10
                 ; cursor = None
                 })
          with
          | Succeeded { success = Page_tree_result page; _ } ->
            let actual =
              List.map
                (fun (item : Logseq_db_worker.Graph_types.block_tree_item) ->
                   item.block.title, item.depth)
                page.items
            in
            T.require
              (actual = [ "Parent", 0; "First child", 1; "Second child", 1; "Sibling", 0 ])
              "Get_page_tree returned the wrong preorder";
            T.require (page.continuation = None) "complete tree returned a cursor"
          | _ -> T.fail "Get_page_tree did not succeed"))
    ; T.case "Get_ancestors is nearest-first and Get_siblings reports position" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          (match
             execute_read
               engine
               (Get_ancestors { block = uuid first_child_uuid_text; limit = 10 })
           with
           | Succeeded { success = Ancestors_result [ parent ]; _ } ->
             T.require (String.equal parent.title "Parent") "wrong nearest ancestor"
           | _ -> T.fail "Get_ancestors did not succeed");
          match
            execute_read
              engine
              (Get_siblings
                 { block = uuid second_child_uuid_text; limit = 10; cursor = None })
          with
          | Succeeded { success = Siblings_result result; _ } ->
            T.require (result.current_index = 1) "wrong sibling position";
            T.require
              (List.map
                 (fun (block : Logseq_db_worker.Graph_types.block) -> block.title)
                 result.siblings.items
               = [ "First child"; "Second child" ])
              "wrong sibling order"
          | _ -> T.fail "Get_siblings did not succeed"))
    ; T.case "List_pages preserves typed ordinary-page identity" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          match
            execute_read
              engine
              (List_pages { kind = Only_ordinary_pages; limit = 50; cursor = None })
          with
          | Succeeded { success = Pages_result page; _ } ->
            T.require
              (List.exists
                 (fun (summary : Logseq_db_worker.Graph_types.page_summary) ->
                    Logseq_db_worker.Graph_types.Uuid.equal
                      summary.uuid
                      (uuid page_uuid_text)
                    && String.equal summary.title "Oracle Page"
                    && summary.kind = Ordinary_page)
                 page.items)
              "List_pages omitted the oracle page"
          | _ -> T.fail "List_pages did not succeed"))
    ; T.case "List_pages filters journals before projecting unrelated pages" (fun () ->
        let prepare_source graph_dir =
          let journal = Datascript.Temp_id "list-pages-journal" in
          let malformed_property = Datascript.Temp_id "list-pages-malformed-property" in
          let oracle_page =
            Datascript.Lookup_ref ("block/uuid", Datascript.Uuid page_uuid_text)
          in
          let property_class =
            Datascript.Lookup_ref ("db/ident", Datascript.Keyword "logseq.class/Property")
          in
          transact_graph
            graph_dir
            [ Datascript.Add (journal, "block/uuid", Uuid journal_uuid_text)
            ; Add (journal, "block/name", String "aug 14th, 2026")
            ; Add (journal, "block/title", String "Aug 14th, 2026")
            ; Add (journal, "block/journal-day", Int 20260814)
            ; Add (journal, "block/created-at", Int 1_776_038_400_000)
            ; Add (journal, "block/updated-at", Int 1_776_038_400_000)
            ; Add (malformed_property, "block/uuid", Uuid malformed_property_uuid_text)
            ; Add (malformed_property, "db/ident", Keyword malformed_property_ident)
            ; Add (malformed_property, "block/tags", Ref_to property_class)
            ; Add (oracle_page, malformed_property_ident, String "ignored")
            ]
        in
        with_snapshot_engine_context ~prepare_source (fun harness ->
          match
            execute_read
              harness.engine
              (List_pages { kind = Only_journals; limit = 50; cursor = None })
          with
          | Succeeded { success = Pages_result { items = [ journal ]; _ }; _ } ->
            T.require
              (Logseq_db_worker.Graph_types.Uuid.equal
                 journal.uuid
                 (uuid journal_uuid_text))
              "List_pages returned the wrong journal"
          | Succeeded { success = Pages_result _; _ } ->
            T.fail "List_pages returned the wrong journals"
          | _ -> T.fail "List_pages projected an unrelated ordinary page"))
    ; T.case "List_tags and List_properties return typed definitions" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          (match execute_read engine (List_tags { limit = 50; cursor = None }) with
           | Succeeded { success = Tags_result page; _ } ->
             T.require
               (List.exists
                  (fun (tag : Logseq_db_worker.Graph_types.tag_summary) ->
                     Logseq_db_worker.Graph_types.Uuid.equal
                       tag.uuid
                       (uuid class_uuid_text)
                     && String.equal tag.title "Oracle Class")
                  page.items)
               "List_tags omitted the user class"
           | _ -> T.fail "List_tags did not succeed");
          let check scope =
            match
              execute_read engine (List_properties { scope; limit = 50; cursor = None })
            with
            | Succeeded { success = Properties_result page; _ } ->
              T.require
                (List.exists
                   (fun (property : Logseq_db_worker.Graph_types.property_definition) ->
                      Logseq_db_worker.Graph_types.Uuid.equal
                        property.uuid
                        (uuid property_uuid_text)
                      && String.equal property.ident property_ident
                      && property.schema.property_type = Default
                      && property.schema.cardinality = One)
                   page.items)
                "List_properties omitted the user property"
            | _ -> T.fail "List_properties did not succeed"
          in
          check User_properties;
          check (Properties_for_block (uuid parent_uuid_text))))
    ; T.case "List_tasks uses typed task relations and filters" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          let filter =
            Logseq_db_worker.Graph_types.
              { states = [ Todo ]
              ; page = Some (uuid page_uuid_text)
              ; scheduled_from = None
              ; scheduled_through = None
              ; deadline_from = None
              ; deadline_through = None
              }
          in
          match
            execute_read engine (List_tasks { filter; limit = 50; cursor = None })
          with
          | Succeeded { success = Tasks_result page; _ } ->
            (match page.items with
             | [ task ] ->
               T.require (task.state = Todo) "List_tasks returned the wrong state";
               T.require
                 (String.equal task.block.title "First child")
                 "List_tasks returned the wrong block"
             | _ -> T.fail "List_tasks returned the wrong number of tasks")
          | _ -> T.fail "List_tasks did not succeed"))
    ; T.case "Get_references preserves direction and relation kind" (fun () ->
        with_snapshot_engine (fun engine _resolved ->
          let check target direction expected_source expected_target =
            match
              execute_read
                engine
                (Get_references { target; direction; limit = 50; cursor = None })
            with
            | Succeeded { success = References_result page; _ } ->
              T.require
                (List.exists
                   (fun (reference : Logseq_db_worker.Graph_types.reference) ->
                      Logseq_db_worker.Graph_types.Uuid.equal
                        reference.source
                        expected_source
                      && Logseq_db_worker.Graph_types.Uuid.equal
                           reference.target
                           expected_target
                      && reference.kind = Block_reference)
                   page.items)
                "Get_references omitted the block reference"
            | _ -> T.fail "Get_references did not succeed"
          in
          check
            (uuid first_child_uuid_text)
            Referred_from
            (uuid first_child_uuid_text)
            (uuid sibling_uuid_text);
          check
            (uuid sibling_uuid_text)
            Referring_to
            (uuid first_child_uuid_text)
            (uuid sibling_uuid_text)))
    ; T.case
        "Save_block commits once, creates recovery, finalizes, and reopens"
        (fun () ->
           with_snapshot_engine_context (fun harness ->
             let basis_before = Option.get (Engine.basis harness.engine) in
             let basis_after =
               match execute_save harness.engine "Persisted title" with
               | Succeeded
                   { basis
                   ; success =
                       Mutation_result
                         { status = Applied
                         ; basis_before = reported_before
                         ; basis_after = reported_after
                         ; changed_uuids
                         ; changed_uuids_truncated = false
                         }
                   ; _
                   } ->
                 T.require (reported_before = basis_before) "wrong mutation basisBefore";
                 T.require
                   (basis = reported_after && basis > basis_before)
                   "mutation basis did not advance exactly once";
                 T.require
                   (List.exists
                      (Logseq_db_worker.Graph_types.Uuid.equal (uuid parent_uuid_text))
                      changed_uuids)
                   "mutation omitted the changed block UUID";
                 basis
               | _ -> T.fail "Save_block did not return Applied"
             in
             T.require
               (snapshot_entry_count harness.support = 2)
               "first mutation did not create exactly one recovery snapshot";
             T.require
               (Sys.file_exists
                  (Filename.concat harness.resolved.graph_dir "write-session.json"))
               "successful mutation has no pending write marker";
             (match
                execute_read harness.engine (Get_block { block = uuid parent_uuid_text })
              with
              | Succeeded { basis; success = Block_result block; _ } ->
                T.require
                  (basis = basis_after)
                  "read observed the wrong post-mutation basis";
                T.require
                  (String.equal block.title "Persisted title")
                  "live Engine did not install db_after"
              | _ -> T.fail "post-mutation read failed");
             (match Engine.close harness.engine with
              | Ok () -> ()
              | Error message -> T.fail "mutation close failed: %s" message);
             T.require
               (not
                  (Sys.file_exists
                     (Filename.concat harness.resolved.graph_dir "write-session.json")))
               "clean close retained the pending write marker";
             ignore
               (match Snapshot.resolve harness.catalog harness.token with
                | Ok resolved -> resolved
                | Error _ -> T.fail "cleanly finalized snapshot did not resolve");
             let reopened =
               match
                 Engine.open_ ~dependencies (config harness.support harness.token)
               with
               | Ok engine -> engine
               | Error _ -> T.fail "mutated snapshot did not reopen"
             in
             Fun.protect
               ~finally:(fun () -> ignore (Engine.close reopened))
               (fun () ->
                  match
                    execute_read reopened (Get_block { block = uuid parent_uuid_text })
                  with
                  | Succeeded { success = Block_result block; _ } ->
                    T.require
                      (String.equal block.title "Persisted title")
                      "reopened snapshot lost Save_block"
                  | _ -> T.fail "reopened mutation read failed")))
    ; T.case "Save_block No_change advances neither basis nor backup state" (fun () ->
        with_snapshot_engine_context (fun harness ->
          let basis = Option.get (Engine.basis harness.engine) in
          (match execute_save harness.engine "Parent" with
           | Succeeded
               { basis = response_basis
               ; success =
                   Mutation_result
                     { status = No_change
                     ; basis_before
                     ; basis_after
                     ; changed_uuids = []
                     ; changed_uuids_truncated = false
                     }
               ; _
               } ->
             T.require
               (response_basis = basis && basis_before = basis && basis_after = basis)
               "No_change advanced its basis"
           | _ -> T.fail "identical Save_block did not return No_change");
          T.require
            (snapshot_entry_count harness.support = 1)
            "No_change created a recovery backup";
          T.require
            (not
               (Sys.file_exists
                  (Filename.concat harness.resolved.graph_dir "write-session.json")))
            "No_change began a write session"))
    ; T.case "all structural commands commit once and persist through reopen" (fun () ->
        with_snapshot_engine_context (fun harness ->
          let open Logseq_db_worker.Protocol in
          let inserted = uuid "88888888-8888-4888-8888-888888888881" in
          let mutation index =
            uuid (Printf.sprintf "a0000000-0000-4000-8000-%012x" index)
          in
          let request index =
            uuid (Printf.sprintf "b0000000-0000-4000-8000-%012x" index)
          in
          let basis0 = Option.get (Engine.basis harness.engine) in
          let basis1 =
            execute_structural
              ~request_id:(request 1)
              ~mutation_id:(mutation 1)
              harness.engine
              (fun context ->
                 Insert_blocks
                   { roots =
                       [ { uuid = inserted; title = "Structural trace"; children = [] } ]
                   ; position = Relative (After (uuid parent_uuid_text))
                   ; context
                   })
            |> require_applied_once basis0
          in
          (match execute_read harness.engine (Get_block { block = inserted }) with
           | Succeeded { success = Block_result block; _ } ->
             T.require
               (Logseq_db_worker.Graph_types.Uuid.equal
                  block.parent
                  (uuid page_uuid_text))
               "insert did not create a page root"
           | _ -> T.fail "inserted block was not readable");
          let basis2 =
            execute_structural
              ~request_id:(request 2)
              ~mutation_id:(mutation 2)
              harness.engine
              (fun context ->
                 Move_blocks
                   { roots = [ inserted ]
                   ; position = After (uuid sibling_uuid_text)
                   ; context
                   })
            |> require_applied_once basis1
          in
          let basis3 =
            execute_structural
              ~request_id:(request 3)
              ~mutation_id:(mutation 3)
              harness.engine
              (fun context ->
                 Move_up_down { roots = [ inserted ]; direction = Up; context })
            |> require_applied_once basis2
          in
          let basis4 =
            execute_structural
              ~request_id:(request 4)
              ~mutation_id:(mutation 4)
              harness.engine
              (fun context ->
                 Indent_outdent { roots = [ inserted ]; direction = Indent; context })
            |> require_applied_once basis3
          in
          (match execute_read harness.engine (Get_block { block = inserted }) with
           | Succeeded { success = Block_result block; _ } ->
             T.require
               (Logseq_db_worker.Graph_types.Uuid.equal
                  block.parent
                  (uuid parent_uuid_text))
               "indent did not reparent beneath the left sibling"
           | _ -> T.fail "indented block was not readable");
          let basis5 =
            execute_structural
              ~request_id:(request 5)
              ~mutation_id:(mutation 5)
              harness.engine
              (fun context ->
                 Indent_outdent
                   { roots = [ inserted ]; direction = Direct_outdent; context })
            |> require_applied_once basis4
          in
          let _basis6 =
            execute_structural
              ~request_id:(request 6)
              ~mutation_id:(mutation 6)
              harness.engine
              (fun context -> Delete_blocks { roots = [ inserted ]; context })
            |> require_applied_once basis5
          in
          (match execute_read harness.engine (Get_block { block = inserted }) with
           | Failed failure ->
             T.require
               (Logseq_db_worker.Error.code failure.error = Not_found)
               "deleted block returned the wrong error"
           | _ -> T.fail "deleted block remained readable");
          (match Engine.close harness.engine with
           | Ok () -> ()
           | Error message -> T.fail "structural trace close failed: %s" message);
          let reopened =
            match Engine.open_ ~dependencies (config harness.support harness.token) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "structural trace did not reopen: %s"
                (Logseq_db_worker.Error.message error)
          in
          Fun.protect
            ~finally:(fun () -> ignore (Engine.close reopened))
            (fun () ->
               match execute_read reopened (Get_block { block = inserted }) with
               | Failed failure ->
                 T.require
                   (Logseq_db_worker.Error.code failure.error = Not_found)
                   "reopened delete returned the wrong error"
               | _ -> T.fail "reopened graph resurrected the deleted block")))
    ; T.case "stale expected basis conflicts before backup or staging effects" (fun () ->
        with_snapshot_engine_context (fun harness ->
          let basis = Option.get (Engine.basis harness.engine) in
          match
            execute_save
              ~expected_basis:(Int64.pred basis)
              harness.engine
              "Rejected stale title"
          with
          | Failed failure ->
            T.require
              (Logseq_db_worker.Error.code failure.error = Conflict)
              "stale mutation returned the wrong error";
            T.require (failure.basis = Some basis) "conflict omitted current basis";
            T.require
              (snapshot_entry_count harness.support = 1)
              "stale mutation created a recovery backup"
          | _ -> T.fail "stale mutation was accepted"))
    ; T.case "live mutation ID cache reuses only the identical command" (fun () ->
        with_snapshot_engine_context (fun harness ->
          let mutation_id = uuid "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" in
          let request_a = uuid "f0000000-0000-4000-8000-000000000001" in
          let request_b = uuid "f0000000-0000-4000-8000-000000000002" in
          let basis_before = Option.get (Engine.basis harness.engine) in
          let first =
            execute_save
              ~request_id:request_a
              ~mutation_id
              ~expected_basis:basis_before
              harness.engine
              "Cached title"
          in
          let second =
            execute_save
              ~request_id:request_b
              ~mutation_id
              ~expected_basis:basis_before
              harness.engine
              "Cached title"
          in
          let mutation (response : Logseq_db_worker.Protocol.response) =
            match response with
            | Succeeded { success = Mutation_result mutation; _ } -> mutation
            | _ -> T.fail "cached mutation did not succeed"
          in
          let first_mutation = mutation first in
          let second_mutation = mutation second in
          T.require
            (first_mutation = second_mutation)
            "mutation cache changed the original result";
          T.require
            (snapshot_entry_count harness.support = 2)
            "cached mutation created another recovery snapshot";
          match
            execute_save
              ~mutation_id
              ~expected_basis:basis_before
              harness.engine
              "Different command"
          with
          | Failed failure ->
            T.require
              (Logseq_db_worker.Error.code failure.error = Conflict)
              "mutation ID reuse returned the wrong error"
          | _ -> T.fail "mutation ID was reused for a different command"))
    ; T.case "GC does not run below the frozen unreachable-address threshold" (fun () ->
        let added = ref 0 in
        with_snapshot_engine_context
          ~prepare_source:(fun graph_dir ->
            added := fill_unreachable_addresses graph_dir 255)
          (fun harness ->
             (match execute_save harness.engine "Below GC threshold" with
              | Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
              | _ -> T.fail "below-threshold mutation failed");
             T.require
               (unreachable_address_count harness.resolved.graph_dir = !added)
               "GC ran below the 256-address threshold"))
    ; T.case "GC runs at the frozen unreachable-address threshold" (fun () ->
        with_snapshot_engine_context
          ~prepare_source:(fun graph_dir ->
            ignore (fill_unreachable_addresses graph_dir 256 : int))
          (fun harness ->
             (match execute_save harness.engine "Count-triggered GC" with
              | Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
              | _ -> T.fail "count-triggered GC mutation failed");
             T.require
               (unreachable_address_count harness.resolved.graph_dir = 0)
               "GC did not delete thresholded unreachable addresses";
             T.require
               (snapshot_entry_count harness.support = 2)
               "count-triggered GC ran without a recovery backup"))
    ; T.case "GC runs after sixteen MiB of SQLite growth" (fun () ->
        with_temp_directory (fun support ->
          let graph = create_native_graph support in
          let engine =
            match Engine.open_ ~dependencies (native_config support graph) with
            | Ok engine -> engine
            | Error error ->
              T.fail
                "native growth fixture did not open: %s"
                (Logseq_db_worker.Error.message error)
          in
          Fun.protect
            ~finally:(fun () -> ignore (Engine.close engine))
            (fun () ->
               insert_unreachable_rows ~payload_bytes:((17 * 1_024 * 1_024) + 1) graph 1;
               (match execute_save engine "Growth-triggered GC" with
                | Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
                | _ -> T.fail "growth-triggered GC mutation failed");
               T.require
                 (unreachable_address_count graph = 0)
                 "GC did not run after the frozen file-growth threshold")))
    ; T.case "threshold GC verifies an existing recovery backup" (fun () ->
        with_snapshot_engine_context (fun harness ->
          (match execute_save harness.engine "First committed title" with
           | Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
           | _ -> T.fail "first mutation failed before backup verification");
          let basis = Option.get (Engine.basis harness.engine) in
          insert_unreachable_rows
            ~payload_bytes:((17 * 1_024 * 1_024) + 1)
            harness.resolved.graph_dir
            1;
          let recovery = recovery_token harness.resolved.graph_dir in
          Yojson.Safe.to_file
            (Filename.concat
               (Filename.concat
                  (Filename.concat harness.support "logseq-db-worker")
                  "snapshots")
               (Filename.concat recovery "manifest.json"))
            (`Assoc []);
          (match
             execute_save
               ~request_id:(uuid "c1000000-0000-4000-8000-000000000001")
               ~mutation_id:(uuid "d1000000-0000-4000-8000-000000000001")
               harness.engine
               "Must not commit with invalid backup"
           with
           | Failed failure ->
             T.require
               (Logseq_db_worker.Error.code failure.error = Corrupt_storage)
               "invalid GC backup returned the wrong error"
           | _ -> T.fail "threshold GC trusted an invalid recovery backup");
          T.require
            (Engine.basis harness.engine = Some basis)
            "invalid GC backup advanced the graph basis";
          T.require
            (unreachable_address_count harness.resolved.graph_dir = 1)
            "invalid GC backup allowed physical deletion";
          match
            execute_read harness.engine (Get_block { block = uuid parent_uuid_text })
          with
          | Succeeded { success = Block_result block; _ } ->
            T.require
              (String.equal block.title "First committed title")
              "invalid GC backup allowed the second mutation to commit"
          | _ -> T.fail "Engine was not reusable after GC backup rejection"))
    ; T.case "threshold GC revalidates ownership before physical deletion" (fun () ->
        with_snapshot_engine_context (fun harness ->
          (match execute_save harness.engine "Backup before GC ownership check" with
           | Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
           | _ -> T.fail "first mutation failed before GC ownership test");
          insert_unreachable_rows harness.resolved.graph_dir 256;
          Yojson.Safe.to_file
            (Filename.concat harness.resolved.graph_dir "db-worker.lock")
            (`Assoc []);
          let terminalized =
            try
              ignore
                (execute_save
                   ~request_id:(uuid "c2000000-0000-4000-8000-000000000001")
                   ~mutation_id:(uuid "d2000000-0000-4000-8000-000000000001")
                   harness.engine
                   "Must not delete after ownership tamper");
              false
            with
            | Engine.Fatal_storage_error _ -> true
          in
          T.require terminalized "GC ownership tamper was not terminal";
          T.require
            (unreachable_address_count harness.resolved.graph_dir = 256)
            "GC deleted addresses after ownership changed"))
    ; T.case "GC delete failure is fatal and preserves recovery evidence" (fun () ->
        let added = ref 0 in
        with_snapshot_engine_context
          ~prepare_source:(fun graph_dir ->
            added := fill_unreachable_addresses graph_dir 256;
            install_gc_delete_failure graph_dir)
          (fun harness ->
             let terminalized =
               try
                 ignore (execute_save harness.engine "Must not survive GC failure");
                 false
               with
               | Engine.Fatal_storage_error _ -> true
             in
             T.require terminalized "GC delete failure was not terminal";
             T.require
               (Engine.basis harness.engine = None)
               "fatal GC Engine exposes a basis";
             T.require
               (unreachable_address_count harness.resolved.graph_dir = !added)
               "failed GC exposed partial physical deletion";
             T.require
               (snapshot_entry_count harness.support = 2)
               "failed GC discarded its recovery backup";
             T.require
               (not
                  (Sys.file_exists
                     (Filename.concat harness.resolved.graph_dir "db-worker.lock")))
               "failed GC retained graph ownership"))
    ; T.case "backup failure blocks the graph write" (fun () ->
        with_snapshot_engine_context (fun harness ->
          let snapshots =
            Filename.concat
              (Filename.concat harness.support "logseq-db-worker")
              "snapshots"
          in
          let basis = Option.get (Engine.basis harness.engine) in
          Unix.chmod snapshots 0o500;
          Fun.protect
            ~finally:(fun () -> Unix.chmod snapshots 0o700)
            (fun () ->
               match execute_save harness.engine "Must not persist" with
               | Failed failure ->
                 T.require
                   (Logseq_db_worker.Error.code failure.error = Corrupt_storage)
                   "backup failure returned the wrong error";
                 T.require
                   (Engine.basis harness.engine = Some basis)
                   "backup failure advanced basis";
                 (match
                    execute_read
                      harness.engine
                      (Get_block { block = uuid parent_uuid_text })
                  with
                  | Succeeded { success = Block_result block; _ } ->
                    T.require
                      (String.equal block.title "Parent")
                      "backup failure installed the staged database"
                  | _ -> T.fail "Engine unusable after recoverable backup failure")
               | _ -> T.fail "backup failure did not block mutation")))
    ; T.case "mutation persistence failure terminalizes the Engine" (fun () ->
        with_snapshot_engine_context ~fail_mutation_writes:true (fun harness ->
          let raised =
            try
              ignore (execute_save harness.engine "Fatal write");
              false
            with
            | Engine.Fatal_storage_error _ -> true
          in
          T.require raised "persistence failure did not raise Fatal_storage_error";
          T.require (Engine.basis harness.engine = None) "fatal Engine exposes a basis";
          let later_raised =
            try
              ignore
                (execute_read
                   harness.engine
                   (Get_block { block = uuid parent_uuid_text }));
              false
            with
            | Engine.Fatal_storage_error _ -> true
          in
          T.require later_raised "fatal Engine accepted a later request";
          T.require
            (Sys.file_exists
               (Filename.concat harness.resolved.graph_dir "write-session.json"))
            "fatal session discarded recovery evidence";
          T.require
            (not
               (Sys.file_exists
                  (Filename.concat harness.resolved.graph_dir "db-worker.lock")))
            "fatal session retained graph ownership"))
    ; T.case "completed close removes only the owned sentinel" (fun () ->
        with_temp_directory (fun support ->
          let source_root = Filename.concat support "sources" in
          Unix.mkdir source_root 0o700;
          let source = create_oracle_graph source_root "oracle-graph" in
          let catalog =
            match Snapshot.create_catalog ~application_support_directory:support with
            | Ok catalog -> catalog
            | Error _ -> T.fail "unable to create catalog"
          in
          let token =
            match Snapshot.create catalog ~source_graph_dir:source with
            | Ok token -> token
            | Error _ -> T.fail "unable to create snapshot"
          in
          let resolved =
            match Snapshot.resolve catalog token with
            | Ok resolved -> resolved
            | Error _ -> T.fail "unable to resolve snapshot"
          in
          let engine =
            match Engine.open_ ~dependencies (config support token) with
            | Ok engine -> engine
            | Error _ -> T.fail "unable to open snapshot"
          in
          (match Engine.close engine with
           | Ok () -> ()
           | Error message -> T.fail "engine close failed: %s" message);
          T.require
            (not (Sys.file_exists (Filename.concat resolved.graph_dir "db-worker.lock")))
            "owned sentinel remains after close";
          T.require (Engine.basis engine = None) "closed engine still exposes a basis"))
    ; T.case "unknown snapshot token fails as graphNotFound" (fun () ->
        with_temp_directory (fun support ->
          let token =
            match
              Logseq_db_worker.Graph_types.Uuid.of_string
                "44444444-4444-4444-8444-444444444444"
            with
            | Ok token -> token
            | Error message -> T.fail "%s" message
          in
          match Engine.open_ ~dependencies (config support token) with
          | Error error ->
            T.require
              (Logseq_db_worker.Error.code error = Graph_not_found)
              "unknown snapshot returned the wrong error"
          | Ok engine ->
            ignore (Engine.close engine);
            T.fail "unknown snapshot opened"))
    ]
;;
