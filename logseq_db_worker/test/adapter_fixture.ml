module T = Test_support
module Snapshot = Logseq_db_worker__Snapshot

type t =
  { support : string
  ; source_graph_dir : string
  ; token : Logseq_db_worker.Graph_types.Uuid.t
  ; config : Logseq_db_worker.Config.t
  ; resolved : Snapshot.resolved
  }

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_directory prefix f =
  let path = Filename.temp_file prefix "" in
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

let install_mutation_write_failure graph_dir =
  let db = Sqlite3.db_open (Filename.concat graph_dir "db.sqlite") in
  Sqlite3.Rc.check
    (Sqlite3.exec
       db
       "CREATE TRIGGER fail_mutation_write BEFORE UPDATE ON kvs BEGIN SELECT \
        RAISE(ABORT, 'injected mutation write failure'); END");
  T.require (Sqlite3.db_close db) "unable to install mutation write failure"
;;

let config support token =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Snapshot { token })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
  with
  | Ok config -> config
  | Error message -> T.fail "invalid adapter fixture config: %s" message
;;

let with_snapshot ?(fail_mutation_writes = false) f =
  with_temp_directory "logseq-db-worker-adapter-" (fun support ->
    let sources = Filename.concat support "sources" in
    Unix.mkdir sources 0o700;
    let source_graph_dir = create_oracle_graph sources "oracle-graph" in
    if fail_mutation_writes then install_mutation_write_failure source_graph_dir;
    let catalog =
      match Snapshot.create_catalog ~application_support_directory:support with
      | Ok catalog -> catalog
      | Error _ -> T.fail "unable to create adapter snapshot catalog"
    in
    let token =
      match Snapshot.create catalog ~source_graph_dir with
      | Ok token -> token
      | Error _ -> T.fail "unable to create adapter snapshot"
    in
    let resolved =
      match Snapshot.resolve catalog token with
      | Ok resolved -> resolved
      | Error _ -> T.fail "unable to resolve adapter snapshot"
    in
    f { support; source_graph_dir; token; config = config support token; resolved })
;;

let clone_with_mutation_write_failure fixture =
  install_mutation_write_failure fixture.resolved.graph_dir;
  let catalog =
    match Snapshot.create_catalog ~application_support_directory:fixture.support with
    | Ok catalog -> catalog
    | Error _ -> T.fail "unable to reopen adapter snapshot catalog"
  in
  let token =
    match Snapshot.create catalog ~source_graph_dir:fixture.resolved.graph_dir with
    | Ok token -> token
    | Error _ -> T.fail "unable to clone mutation-failure snapshot"
  in
  let resolved =
    match Snapshot.resolve catalog token with
    | Ok resolved -> resolved
    | Error _ -> T.fail "unable to resolve mutation-failure snapshot"
  in
  { fixture with token; config = config fixture.support token; resolved }
;;

type synced =
  { sync_support : string
  ; graph_id : Logseq_db_worker.Graph_types.Uuid.t
  ; graph_dir : string
  ; database_path : string
  ; sync_config : Logseq_db_worker.Config.t
  ; metadata : Logseq_db_worker__Sync_meta.t
  }

let make_directory path =
  let rec ensure current =
    if Sys.file_exists current
    then ()
    else (
      ensure (Filename.dirname current);
      Unix.mkdir current 0o700)
  in
  ensure path
;;

let add_remote_identity graph_dir graph_id_text =
  let database_path = Filename.concat graph_dir "db.sqlite" in
  let connection =
    match Logseq_db_worker__Logseq_sqlite_storage.open_database database_path with
    | Ok value -> value
    | Error _ -> T.fail "unable to open synced fixture"
  in
  let module Storage = Logseq_db_worker__Logseq_sqlite_storage in
  let module Session = Logseq_db_worker__Storage_session in
  let storage = Storage.datascript_storage connection in
  let db =
    match Storage.restore_database connection with
    | Ok value -> value
    | Error _ -> T.fail "unable to restore synced fixture"
  in
  let session =
    Session.create
      ~db
      ~tail:(Datascript.Storage.restore_tail_groups storage)
      ~callbacks:(Storage.connection_callbacks connection)
  in
  let entity id ident value =
    Datascript.Entity
      { db_id = Some (Temp_id id)
      ; attrs = [ "db/ident", One_value (Keyword ident); "kv/value", One_value value ]
      }
  in
  let staged =
    match
      Session.stage_transact
        session
        [ entity "remote-flag" "logseq.kv/graph-remote?" (Bool true)
        ; entity "remote-uuid" "logseq.kv/graph-uuid" (Uuid graph_id_text)
        ]
    with
    | Ok value -> value
    | Error _ -> T.fail "unable to stage synced fixture identity"
  in
  (match Session.commit_staged session staged with
   | Ok () -> ()
   | Error _ -> T.fail "unable to commit synced fixture identity");
  match Session.close session with
  | Ok () -> ()
  | Error _ -> T.fail "unable to close synced fixture identity"
;;

let with_synced f =
  with_temp_directory "logseq-db-worker-synced-" (fun support ->
    let graph_id_text = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" in
    let graph_id =
      match Logseq_db_worker.Graph_types.Uuid.of_string graph_id_text with
      | Ok value -> value
      | Error message -> T.fail "%s" message
    in
    let graph_dir =
      Logseq_db_worker.Sync_mirror.graph_directory
        ~application_support_directory:support
        ~graph_id
    in
    let root = Filename.dirname graph_dir in
    make_directory root;
    let created = create_oracle_graph root graph_id_text in
    T.require (String.equal created graph_dir) "synced fixture path changed";
    add_remote_identity graph_dir graph_id_text;
    let database_path = Filename.concat graph_dir "db.sqlite" in
    let module Storage = Logseq_db_worker__Logseq_sqlite_storage in
    let connection =
      match Storage.open_database database_path with
      | Ok value -> value
      | Error _ -> T.fail "unable to reopen synced fixture"
    in
    let db =
      match Storage.restore_database connection with
      | Ok value -> value
      | Error _ -> T.fail "unable to restore synced checksum fixture"
    in
    let checksum = Logseq_db_worker.Sync_checksum.recompute ~e2ee:false db in
    (match Storage.close (Storage.connection_callbacks connection) with
     | Ok () -> ()
     | Error _ -> T.fail "unable to close synced checksum fixture");
    let metadata =
      match
        Logseq_db_worker__Sync_meta.create
          ~graph_id
          ~schema:Logseq_db_worker.Graph_types.{ major = 65; minor = 33 }
          ~applied_server_t:40
          ~checksum
      with
      | Ok value -> value
      | Error message -> T.fail "%s" message
    in
    let sqlite = Sqlite3.db_open database_path in
    (match Logseq_db_worker__Sync_meta.initialize_database sqlite metadata with
     | Ok () -> ()
     | Error message -> T.fail "unable to initialize synced fixture: %s" message);
    T.require (Sqlite3.db_close sqlite) "unable to close synced fixture metadata";
    let config =
      match
        Logseq_db_worker.Config.create
          ~application_support_directory:support
          ~target:
            (Synced_graph
               { graph_id; graph_name = "Remote Notes"; e2ee = None; bootstrap = None })
          ~compatibility_profile:Logseq_65_33_or_newer
          ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
          ~default_page_size:Logseq_db_worker.Protocol.default_page_size
      with
      | Ok value -> value
      | Error message -> T.fail "invalid synced config: %s" message
    in
    f
      { sync_support = support
      ; graph_id
      ; graph_dir
      ; database_path
      ; sync_config = config
      ; metadata
      })
;;

let sync_receive_request ~request_id ~transport ~payload =
  let request_id =
    match Logseq_db_worker.Graph_types.Uuid.of_string request_id with
    | Ok value -> value
    | Error message -> T.fail "%s" message
  in
  Logseq_db_worker.Protocol.
    { api_version; request_id; command = Sync_receive { transport; payload } }
;;

let sync_pull_wire (fixture : synced) ~title =
  let tx =
    Yojson.Safe.to_string
      (`List
          [ `List
              [ `String "~:db/add"
              ; `List
                  [ `String "~:block/uuid"
                  ; `String "~u11111111-1111-4111-8111-111111111111"
                  ]
              ; `String "~:block/title"
              ; `String title
              ; `Int 536870914
              ]
          ])
  in
  let module Storage = Logseq_db_worker__Logseq_sqlite_storage in
  let connection =
    match Storage.open_database fixture.database_path with
    | Ok value -> value
    | Error _ -> T.fail "unable to open synced pull fixture"
  in
  let db =
    match Storage.restore_database connection with
    | Ok value -> value
    | Error _ -> T.fail "unable to restore synced pull fixture"
  in
  let operations =
    match Logseq_db_worker.Sync_tx.decode ~db tx with
    | Ok value -> value
    | Error message -> T.fail "unable to decode synced pull fixture: %s" message
  in
  let checksum =
    Datascript.db_with operations db
    |> Logseq_db_worker.Sync_checksum.recompute ~e2ee:false
  in
  (match Storage.close (Storage.connection_callbacks connection) with
   | Ok () -> ()
   | Error _ -> T.fail "unable to close synced pull fixture");
  Yojson.Safe.to_string
    (`Assoc
        [ "type", `String "pull/ok"
        ; "t", `Int 41
        ; "checksum", `String checksum
        ; ( "txs"
          , `List
              [ `Assoc
                  [ "t", `Int 41; "tx", `String tx; "outliner-op", `String "save-block" ]
              ] )
        ])
;;

let uuid value =
  match Logseq_db_worker.Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message
;;

let missing_config support = config support (uuid "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")

let dependencies =
  Logseq_db_worker.Engine.
    { clocks =
        { epoch_ms = (fun () -> 1_704_067_200_000L)
        ; monotonic_ns = (fun () -> 1_000_000L)
        }
    ; cursor_authentication_key = Bytes.make 32 'a'
    ; crypto = Logseq_db_worker.Sync_e2ee.unavailable_crypto
    ; unlock_graph_key =
        (fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
          Error "crypto unavailable")
    }
;;

let graph_info_request ?(request_id = "10000000-0000-4000-8000-000000000001") () =
  Logseq_db_worker.Protocol.
    { api_version; request_id = uuid request_id; command = Read Graph_info }
;;

let create_page_request ~basis ~request_id ~mutation_id ~page_uuid ~title =
  Logseq_db_worker.Protocol.
    { api_version
    ; request_id = uuid request_id
    ; command =
        Mutate
          (Page
             (Create_page
                { title
                ; kind = Create_ordinary_page { uuid = uuid page_uuid }
                ; context = { mutation_id = uuid mutation_id; expected_basis = basis }
                }))
    }
;;
