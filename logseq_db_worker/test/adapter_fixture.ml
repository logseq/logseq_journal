open Logseq_db_types.Mutation
module T = Test_support

type resolved = { graph_dir : string }

type t =
  { support : string
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t
  ; config : Logseq_db_worker.Config.t
  ; attachment : Logseq_db_worker.Engine.attachment
  ; resolved : resolved
  }

let managed_user_id = "managed-fixture-user"
let managed_base_url = "https://api.logseq.io"

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

let rec ensure_directory path =
  if Sys.file_exists path
  then ()
  else (
    ensure_directory (Filename.dirname path);
    Unix.mkdir path 0o700)
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

let uuid value =
  Logseq_db_types.Graph_types.Uuid.of_string value
  |> Result.fold ~ok:Fun.id ~error:(fun message -> T.fail "%s" message)
;;

let config support _graph_id =
  Logseq_db_worker.Config.create
    ~application_support_directory:support
    ~target:(Managed_sync { base_url = managed_base_url })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
    ~default_page_size:Logseq_db_worker.Protocol.default_page_size
  |> Result.fold ~ok:Fun.id ~error:(fun message ->
    T.fail "invalid managed fixture config: %s" message)
;;

let install_catalog support graph_id =
  let root = Filename.concat support "logseq-db-worker/sync-catalogs" in
  ensure_directory root;
  let digest =
    Digestif.SHA256.digest_string (managed_user_id ^ "\000" ^ managed_base_url)
    |> Digestif.SHA256.to_hex
  in
  let graph_id = Logseq_db_types.Graph_types.Uuid.to_string graph_id in
  Yojson.Safe.to_file
    (Filename.concat root (digest ^ ".json"))
    (`Assoc
        [ "userId", `String managed_user_id
        ; "baseUrl", `String managed_base_url
        ; ( "graphs"
          , `List
              [ `Assoc
                  [ "graphId", `String graph_id
                  ; "name", `String "oracle-graph"
                  ; ( "schema"
                    , `Assoc [ "major", `Int 65; "minor", `Int 33; "exact", `Bool true ] )
                  ; "encrypted", `Bool true
                  ]
              ] )
        ; "selectedGraph", `String graph_id
        ])
;;

let add_remote_identity graph_dir graph_id =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Session = Logseq_db_storage.Storage_session in
  let connection =
    Storage.open_database (Filename.concat graph_dir "db.sqlite") |> Result.get_ok
  in
  let storage = Storage.datascript_storage connection in
  let database = Storage.restore_database connection |> Result.get_ok in
  let session =
    Session.create
      ~db:database
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
    Session.stage_transact
      session
      [ entity "remote-flag" "logseq.kv/graph-remote?" (Bool true)
      ; entity
          "remote-uuid"
          "logseq.kv/graph-uuid"
          (Uuid (Logseq_db_types.Graph_types.Uuid.to_string graph_id))
      ]
    |> Result.get_ok
  in
  Session.commit_staged session staged |> Result.get_ok;
  Session.close session |> Result.get_ok
;;

let prepare_mirror graph_dir graph_id =
  add_remote_identity graph_dir graph_id;
  let checkpoint =
    Logseq_db_types.Sync_checkpoint.create
      ~graph_id
      ~schema:Logseq_db_types.Graph_types.{ major = 65; minor = 33 }
      ~applied_server_t:0
      ~checksum:"0000000000000000"
    |> Result.get_ok
  in
  let sqlite = Sqlite3.db_open (Filename.concat graph_dir "db.sqlite") in
  (match
     Logseq_db_storage.Sync_checkpoint_store.initialize_database sqlite checkpoint
   with
   | Ok () -> ()
   | Error message -> T.fail "unable to initialize managed checkpoint: %s" message);
  (match Logseq_db_storage.Sync_outbox_store.initialize_database sqlite with
   | Ok () -> ()
   | Error message -> T.fail "unable to initialize managed outbox: %s" message);
  T.require (Sqlite3.db_close sqlite) "managed fixture SQLite close failed";
  checkpoint
;;

let with_managed ?(fail_mutation_writes = false) f =
  with_temp_directory "logseq-db-worker-adapter-" (fun support ->
    let graph_id = uuid "60000000-0000-4000-8000-000000000001" in
    let graph_id_text = Logseq_db_types.Graph_types.Uuid.to_string graph_id in
    let root = Filename.concat support "logseq-db-worker/synced-graphs" in
    ensure_directory root;
    let graph_dir = create_oracle_graph root graph_id_text in
    let checkpoint = prepare_mirror graph_dir graph_id in
    install_catalog support graph_id;
    if fail_mutation_writes then install_mutation_write_failure graph_dir;
    let attachment =
      Logseq_db_worker.Engine.
        { graph_id
        ; graph_name = "oracle-graph"
        ; graph_dir
        ; database_path = Filename.concat graph_dir "db.sqlite"
        ; checkpoint
        }
    in
    f
      { support
      ; graph_id
      ; config = config support graph_id
      ; attachment
      ; resolved = { graph_dir }
      })
;;

let with_missing_managed f =
  with_managed (fun fixture ->
    remove_tree fixture.resolved.graph_dir;
    f fixture)
;;

let dependencies =
  Logseq_db_worker.Engine.
    { clocks =
        { epoch_ms = (fun () -> 1_704_067_200_000L)
        ; monotonic_ns = (fun () -> 1_000_000L)
        }
    ; cursor_authentication_key = Bytes.make 32 'a'
    }
;;

let open_engine ?(dependencies = dependencies) fixture =
  Logseq_db_worker.Engine.open_
    ~dependencies
    ~response_budget_bytes:fixture.config.response_budget_bytes
    fixture.attachment
  |> Result.map (fun engine ->
    Logseq_db_worker.Engine.restore_managed_projection engine |> Result.get_ok;
    engine)
;;

let attachment_for_config config =
  let root =
    Filename.concat
      config.Logseq_db_worker.Config.application_support_directory
      "logseq-db-worker/synced-graphs"
  in
  match Sys.readdir root |> Array.to_list with
  | [ graph_id_text ] ->
    let graph_id = uuid graph_id_text in
    let graph_dir = Filename.concat root graph_id_text in
    let database_path = Filename.concat graph_dir "db.sqlite" in
    let checkpoint =
      Logseq_db_storage.Sync_checkpoint_store.read_path database_path |> Result.get_ok
    in
    Logseq_db_worker.Engine.
      { graph_id; graph_name = "oracle-graph"; graph_dir; database_path; checkpoint }
  | entries -> T.fail "expected one managed fixture mirror, got %d" (List.length entries)
;;

let open_configured_engine ?(dependencies = dependencies) config =
  Logseq_db_worker.Engine.open_
    ~dependencies
    ~response_budget_bytes:config.Logseq_db_worker.Config.response_budget_bytes
    (attachment_for_config config)
  |> Result.map (fun engine ->
    Logseq_db_worker.Engine.restore_managed_projection engine |> Result.get_ok;
    engine)
;;

let apply_managed_mutation engine mutation =
  let prepared =
    Logseq_db_worker.Engine.prepare_managed_mutation
      engine
      ~identity:(Logseq_db_types.Mutation.identify mutation)
      mutation
    |> Result.get_ok
  in
  let expected_precondition =
    Logseq_db_worker.Engine.authoritative_precondition engine |> Result.get_ok
  in
  let checkpoint = Logseq_db_worker.Engine.sync_checkpoint engine |> Result.get_ok in
  match
    Logseq_db_worker.Engine.apply_authoritative
      engine
      ~expected_precondition
      [ Logseq_db_worker.Engine.prepared_mutation_operations prepared ]
      ~projection_transactions:[]
      ~checkpoint
      ~outbox_records:[]
  with
  | Ok (basis_before, basis_after, changed_uuids, _) ->
    Logseq_db_types.Mutation.
      { status = Applied
      ; basis_before
      ; basis_after
      ; changed_uuids
      ; changed_uuids_truncated = false
      }
  | Error Authoritative_conflict -> T.fail "managed fixture mutation conflicted"
  | Error (Authoritative_apply_failed message) ->
    T.fail "managed fixture mutation failed: %s" message
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
