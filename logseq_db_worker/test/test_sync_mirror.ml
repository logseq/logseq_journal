module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module Mirror = Logseq_db_worker.Sync_mirror
module Graph_types = Logseq_db_worker.Graph_types
module Engine = Logseq_db_worker.Engine
module Protocol = Logseq_db_worker.Protocol
module Storage = Logseq_db_worker__Logseq_sqlite_storage
module Session = Logseq_db_worker__Storage_session
module Transit = Transit_core.Json
module Transit_codec = Transit_native.Transit.Json

let graph_id_text = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
let other_graph_id_text = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

let uuid value =
  match Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message
;;

let graph_id = uuid graph_id_text
let schema = Graph_types.{ major = 65; minor = 33 }

let write_all channel value =
  output_string channel value;
  flush channel
;;

let frame value =
  let payload = Transit_codec.to_string value in
  let length = String.length payload in
  let prefix =
    String.init 4 (fun index -> Char.chr ((length lsr ((3 - index) * 8)) land 0xff))
  in
  prefix ^ payload
;;

let make_remote_graph graph_dir remote_graph_id =
  let database_path = Filename.concat graph_dir "db.sqlite" in
  let connection =
    match Storage.open_database database_path with
    | Ok connection -> connection
    | Error _ -> T.fail "unable to open remote graph fixture"
  in
  let storage = Storage.datascript_storage connection in
  let db =
    match Storage.restore_database connection with
    | Ok db -> db
    | Error _ -> T.fail "unable to restore remote graph fixture"
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
    Session.stage_transact
      session
      [ entity "remote-flag" "logseq.kv/graph-remote?" (Bool true)
      ; entity "remote-uuid" "logseq.kv/graph-uuid" (Uuid remote_graph_id)
      ]
  in
  let staged =
    match staged with
    | Ok staged -> staged
    | Error _ -> T.fail "unable to stage remote identity fixture"
  in
  (match Session.commit_staged session staged with
   | Ok () -> ()
   | Error _ -> T.fail "unable to commit remote identity fixture");
  match Session.close session with
  | Ok () -> ()
  | Error _ -> T.fail "unable to close remote identity fixture"
;;

let set_schema_version graph_dir (schema : Graph_types.schema_version) =
  let database_path = Filename.concat graph_dir "db.sqlite" in
  let connection =
    match Storage.open_database database_path with
    | Ok connection -> connection
    | Error _ -> T.fail "unable to open schema-version fixture"
  in
  let storage = Storage.datascript_storage connection in
  let db =
    match Storage.restore_database connection with
    | Ok db -> db
    | Error _ -> T.fail "unable to restore schema-version fixture"
  in
  let session =
    Session.create
      ~db
      ~tail:(Datascript.Storage.restore_tail_groups storage)
      ~callbacks:(Storage.connection_callbacks connection)
  in
  let schema_entity =
    Datascript.Lookup_ref ("db/ident", Datascript.Keyword "logseq.kv/schema-version")
  in
  let value =
    Datascript.Map
      [ Datascript.Keyword "major", Datascript.Int schema.major
      ; Datascript.Keyword "minor", Datascript.Int schema.minor
      ]
  in
  let staged =
    match
      Session.stage_transact session [ Datascript.Add (schema_entity, "kv/value", value) ]
    with
    | Ok staged -> staged
    | Error _ -> T.fail "unable to stage schema-version fixture"
  in
  (match Session.commit_staged session staged with
   | Ok () -> ()
   | Error _ -> T.fail "unable to commit schema-version fixture");
  match Session.close session with
  | Ok () -> ()
  | Error _ -> T.fail "unable to close schema-version fixture"
;;

type sql_row =
  { addr : int
  ; content : string
  ; addresses : string option
  }

let database_rows database_path =
  let db = Sqlite3.db_open ~mode:`READONLY database_path in
  let rows = ref [] in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
       Sqlite3.Rc.check
         (Sqlite3.exec
            db
            "SELECT addr, content, addresses FROM kvs ORDER BY addr"
            ~cb:(fun row _ ->
              match row with
              | [| Some addr; Some content; addresses |] ->
                rows := { addr = int_of_string addr; content; addresses } :: !rows
              | _ -> T.fail "malformed KVS fixture row"));
       List.rev !rows)
;;

let write_snapshot path rows =
  let values =
    List.map
      (fun row ->
         Transit.Array
           [ Transit.Int row.addr
           ; Transit.String row.content
           ; (match row.addresses with
              | None -> Transit.Null
              | Some addresses -> Transit.String addresses)
           ])
      rows
  in
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> write_all channel (frame (Transit.Array values)))
;;

type fixture =
  { support : string
  ; snapshot_path : string
  ; rows : sql_row list
  ; checksum : string
  }

let graph_checksum database_path =
  let connection =
    match Storage.open_database database_path with
    | Ok connection -> connection
    | Error _ -> T.fail "unable to open checksum fixture"
  in
  Fun.protect
    ~finally:(fun () -> ignore (Storage.close (Storage.connection_callbacks connection)))
    (fun () ->
       match Storage.restore_database connection with
       | Error _ -> T.fail "unable to restore checksum fixture"
       | Ok db ->
         Logseq_db_worker.Sync_checksum.recompute
           ~e2ee:(Logseq_db_worker.Sync_checksum.graph_e2ee db)
           db)
;;

let with_fixture ?(remote_graph_id = graph_id_text) ?(schema_version = schema) f =
  F.with_temp_directory "logseq-sync-mirror-" (fun support ->
    let sources = Filename.concat support "sources" in
    Unix.mkdir sources 0o700;
    let source = F.create_oracle_graph sources "remote-source" in
    make_remote_graph source remote_graph_id;
    if schema_version <> schema then set_schema_version source schema_version;
    let source_database = Filename.concat source "db.sqlite" in
    let rows = database_rows source_database in
    let checksum = graph_checksum source_database in
    let snapshot_path = Filename.concat support "download.snapshot" in
    write_snapshot snapshot_path rows;
    f { support; snapshot_path; rows; checksum })
;;

let bootstrap fixture ?(graph_id = graph_id) ?checksum ?expected_rows () =
  let expected_rows = Option.value expected_rows ~default:(List.length fixture.rows) in
  let checksum = Option.value checksum ~default:fixture.checksum in
  Mirror.bootstrap
    ~application_support_directory:fixture.support
    ~graph_id
    ~applied_server_t:48192
    ~checksum
    ~expected_rows
    ~snapshot_path:fixture.snapshot_path
    ()
;;

let config ?(bootstrap = None) support =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:
        (Synced_graph { graph_id; graph_name = "Remote Notes"; e2ee = None; bootstrap })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:262_144
      ~default_page_size:50
  with
  | Ok config -> config
  | Error message -> T.fail "invalid synced engine config: %s" message
;;

let dependencies =
  Engine.
    { clocks =
        { epoch_ms = (fun () -> 1_704_067_200_000L)
        ; monotonic_ns = (fun () -> 1_000_000L)
        }
    ; cursor_authentication_key = Bytes.make 32 's'
    ; crypto = Logseq_db_worker.Sync_e2ee.unavailable_crypto
    ; unlock_graph_key =
        (fun ~user_id:_ ~encrypted_graph_key:_ -> Error "crypto unavailable")
    }
;;

let engine_bootstrap_target_case () =
  with_fixture (fun fixture ->
    let bootstrap : Logseq_db_worker.Config.synced_bootstrap =
      { snapshot_path = fixture.snapshot_path
      ; applied_server_t = 48192
      ; checksum = None
      ; expected_rows = List.length fixture.rows
      }
    in
    let engine =
      match
        Engine.open_ ~dependencies (config ~bootstrap:(Some bootstrap) fixture.support)
      with
      | Ok engine -> engine
      | Error error ->
        T.fail
          "engine did not activate its file-backed bootstrap target: %s"
          (Logseq_db_worker.Error.message error)
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         match Engine.execute engine (F.graph_info_request ()) with
         | Succeeded { success = Graph_info_result info; _ } ->
           T.require
             (info.mode = Graph_types.Synced_local_first)
             "bootstrapped engine opened in the wrong mode"
         | _ -> T.fail "bootstrapped engine graph info failed"))
;;

let engine_derives_bootstrap_schema_from_snapshot_case () =
  with_fixture (fun fixture ->
    let json =
      `Assoc
        [ "applicationSupportDirectory", `String fixture.support
        ; ( "target"
          , `Assoc
              [ ( "bootstrap"
                , `Assoc
                    [ "appliedServerT", `Int 48192
                    ; "checksum", `Null
                    ; "expectedRows", `Int (List.length fixture.rows)
                    ; "snapshotPath", `String fixture.snapshot_path
                    ] )
              ; "e2ee", `Null
              ; "kind", `String "syncedGraph"
              ; "graphId", `String graph_id_text
              ; "graphName", `String "Remote Notes"
              ] )
        ; "compatibilityProfile", `String "logseq-65.33-or-newer"
        ; "responseBudgetBytes", `Int 262_144
        ; "defaultPageSize", `Int 50
        ]
    in
    let config =
      match Logseq_db_worker.Config.of_yojson json with
      | Ok config -> config
      | Error error -> T.fail "schema-free bootstrap config was rejected: %s" error
    in
    let engine =
      match Engine.open_ ~dependencies config with
      | Ok engine -> engine
      | Error error ->
        T.fail
          "schema-free bootstrap did not activate: %s"
          (Logseq_db_worker.Error.message error)
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let resolved =
           match
             Mirror.resolve ~application_support_directory:fixture.support ~graph_id
           with
           | Ok resolved -> resolved
           | Error error ->
             T.fail
               "schema-derived mirror did not resolve: %s"
               (Mirror.error_message error)
         in
         T.require
           (resolved.metadata.schema = schema)
           "bootstrap metadata did not use the schema stored inside the snapshot"))
;;

let engine_reports_unsupported_bootstrap_schema_case () =
  with_fixture
    ~schema_version:Graph_types.{ major = 65; minor = 32 }
    (fun fixture ->
       let bootstrap : Logseq_db_worker.Config.synced_bootstrap =
         { snapshot_path = fixture.snapshot_path
         ; applied_server_t = 48192
         ; checksum = None
         ; expected_rows = List.length fixture.rows
         }
       in
       match
         Engine.open_ ~dependencies (config ~bootstrap:(Some bootstrap) fixture.support)
       with
       | Error error ->
         T.require
           (Logseq_db_worker.Error.code error = Unsupported_schema)
           "unsupported synced snapshot schema returned the wrong engine error";
         T.require
           (String.starts_with
              ~prefix:"App upgrade required."
              (Logseq_db_worker.Error.message error))
           "unsupported synced snapshot schema did not return upgrade guidance"
       | Ok engine ->
         ignore (Engine.close engine);
         T.fail "engine opened an unsupported synced snapshot schema")
;;

let valid_bootstrap_case () =
  with_fixture (fun fixture ->
    let resolved =
      match bootstrap fixture () with
      | Ok resolved -> resolved
      | Error error ->
        T.fail "valid remote snapshot failed: %s" (Mirror.error_message error)
    in
    T.require
      (String.equal (Filename.basename resolved.graph_dir) graph_id_text)
      "mirror directory is not keyed by server graph UUID";
    T.require
      (database_rows resolved.database_path = fixture.rows)
      "snapshot KVS rows changed during bootstrap";
    T.require (resolved.metadata.format_version = 2) "sync_meta version changed";
    T.require
      (Graph_types.Uuid.equal resolved.metadata.graph_id graph_id)
      "sync_meta graph id changed";
    T.require (resolved.metadata.schema = schema) "sync_meta schema changed";
    T.require (resolved.metadata.applied_server_t = 48192) "sync_meta cursor changed";
    T.require
      (String.equal resolved.metadata.checksum fixture.checksum)
      "sync_meta checksum changed";
    match Mirror.resolve ~application_support_directory:fixture.support ~graph_id with
    | Ok reopened ->
      T.require (reopened.metadata = resolved.metadata) "resolved sync_meta changed"
    | Error error ->
      T.fail "activated mirror did not resolve: %s" (Mirror.error_message error))
;;

let computed_checksum_bootstrap_case () =
  with_fixture (fun fixture ->
    let resolved =
      match
        Mirror.bootstrap
          ~application_support_directory:fixture.support
          ~graph_id
          ~applied_server_t:48192
          ~expected_rows:(List.length fixture.rows)
          ~snapshot_path:fixture.snapshot_path
          ()
      with
      | Ok resolved -> resolved
      | Error error ->
        T.fail "checksum-free snapshot bootstrap failed: %s" (Mirror.error_message error)
    in
    let connection =
      match Storage.open_database resolved.database_path with
      | Ok connection -> connection
      | Error _ -> T.fail "computed-checksum mirror did not reopen"
    in
    let db =
      match Storage.restore_database connection with
      | Ok db -> db
      | Error _ -> T.fail "computed-checksum mirror did not restore"
    in
    let expected =
      Logseq_db_worker.Sync_checksum.recompute
        ~e2ee:(Logseq_db_worker.Sync_checksum.graph_e2ee db)
        db
    in
    T.require
      (String.equal resolved.metadata.checksum expected)
      "snapshot bootstrap did not compute the pinned upstream checksum";
    ignore (Storage.close (Storage.connection_callbacks connection)))
;;

let encrypted_snapshot_materializes_plaintext_case () =
  with_fixture (fun fixture ->
    let resolved =
      match
        Mirror.bootstrap
          ~application_support_directory:fixture.support
          ~graph_id
          ~applied_server_t:48192
          ~expected_rows:(List.length fixture.rows)
          ~snapshot_path:fixture.snapshot_path
          ~decrypt_protected:(fun ciphertext -> Ok ("decrypted:" ^ ciphertext))
          ()
      with
      | Ok resolved -> resolved
      | Error error ->
        T.fail "encrypted snapshot bootstrap failed: %s" (Mirror.error_message error)
    in
    let connection =
      match Storage.open_database resolved.database_path with
      | Ok connection -> connection
      | Error _ -> T.fail "decrypted snapshot did not reopen"
    in
    let db =
      match Storage.restore_database connection with
      | Ok db -> db
      | Error _ -> T.fail "decrypted snapshot did not restore"
    in
    let protected =
      Datascript.datoms db Datascript.Eavt ()
      |> Seq.filter (fun datom ->
        List.mem datom.Datascript.a Logseq_db_worker.Sync_e2ee.protected_attributes)
      |> List.of_seq
    in
    T.require (protected <> []) "snapshot fixture has no protected values";
    List.iter
      (fun datom ->
         match datom.Datascript.v with
         | Datascript.String value ->
           T.require
             (String.starts_with ~prefix:"decrypted:" value)
             "protected snapshot value was persisted as ciphertext"
         | _ -> T.fail "protected snapshot value lost its string type")
      protected;
    ignore (Storage.close (Storage.connection_callbacks connection)))
;;

let atomic_rejection_case () =
  let reject label prepare call =
    with_fixture (fun fixture ->
      prepare fixture;
      (match call fixture with
       | Error _ -> ()
       | Ok _ -> T.fail "%s was accepted" label);
      let active =
        Mirror.graph_directory ~application_support_directory:fixture.support ~graph_id
      in
      T.require (not (Sys.file_exists active)) "%s exposed an active mirror" label;
      let root = Filename.dirname active in
      if Sys.file_exists root
      then
        Sys.readdir root
        |> Array.iter (fun entry ->
          T.require
            (not (String.starts_with ~prefix:".stage-" entry))
            "%s left staging debris"
            label))
  in
  reject
    "truncated snapshot"
    (fun fixture ->
       let channel = open_out_bin fixture.snapshot_path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr channel)
         (fun () -> output_string channel "\000\000\000\010{}"))
    (fun fixture -> bootstrap fixture ());
  reject
    "advertised row-count mismatch"
    (fun _ -> ())
    (fun fixture -> bootstrap fixture ~expected_rows:(List.length fixture.rows + 1) ());
  reject
    "invalid checksum"
    (fun _ -> ())
    (fun fixture -> bootstrap fixture ~checksum:"not-a-checksum" ());
  reject
    "snapshot checksum mismatch"
    (fun _ -> ())
    (fun fixture -> bootstrap fixture ~checksum:"0000000000000000" ())
;;

let identity_mismatch_case () =
  with_fixture ~remote_graph_id:other_graph_id_text (fun fixture ->
    match bootstrap fixture () with
    | Error _ ->
      let active =
        Mirror.graph_directory ~application_support_directory:fixture.support ~graph_id
      in
      T.require (not (Sys.file_exists active)) "identity mismatch activated a mirror"
    | Ok _ -> T.fail "snapshot for another remote graph was accepted")
;;

let existing_mirror_is_not_replaced_case () =
  with_fixture (fun fixture ->
    let first =
      match bootstrap fixture () with
      | Ok resolved -> resolved
      | Error error -> T.fail "first bootstrap failed: %s" (Mirror.error_message error)
    in
    let before = database_rows first.database_path in
    let channel = open_out_bin fixture.snapshot_path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel "corrupt replacement");
    (match bootstrap fixture () with
     | Error Mirror.Mirror_exists -> ()
     | Error error ->
       T.fail "existing mirror returned wrong error: %s" (Mirror.error_message error)
     | Ok _ -> T.fail "existing mirror was implicitly replaced");
    T.require (database_rows first.database_path = before) "existing mirror changed")
;;

let read_only_engine_case () =
  with_fixture (fun fixture ->
    let resolved =
      match bootstrap fixture () with
      | Ok resolved -> resolved
      | Error error -> T.fail "bootstrap failed: %s" (Mirror.error_message error)
    in
    let engine =
      match Engine.open_ ~dependencies (config fixture.support) with
      | Ok engine -> engine
      | Error error ->
        T.fail "synced mirror did not open: %s" (Logseq_db_worker.Error.message error)
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let info = Engine.execute engine (F.graph_info_request ()) in
         let basis =
           match info with
           | Succeeded { success = Graph_info_result info; basis; _ } ->
             T.require
               (info.mode = Graph_types.Synced_local_first)
               "synced graph reported wrong mode";
             T.require
               (List.mem
                  (Graph_types.Synced_graph_identity graph_id)
                  info.admission_facts)
               "synced admission fact is missing";
             basis
           | _ -> T.fail "synced Graph_info failed"
         in
         let mutation =
           F.create_page_request
             ~basis
             ~request_id:"10000000-0000-4000-8000-000000000010"
             ~mutation_id:"20000000-0000-4000-8000-000000000010"
             ~page_uuid:"30000000-0000-4000-8000-000000000010"
             ~title:"Must remain pending later"
         in
         (match Engine.execute engine mutation with
          | Failed { error; _ } ->
            T.require
              (Logseq_db_worker.Error.code error = Unsupported_semantics)
              "synced direct mutation returned the wrong error"
          | Succeeded _ -> T.fail "synced read-only engine committed a direct mutation");
         T.require
           (database_rows resolved.database_path = fixture.rows)
           "synced direct mutation changed authoritative KVS"))
;;

let corrupt_sync_meta_case () =
  with_fixture (fun fixture ->
    let resolved =
      match bootstrap fixture () with
      | Ok resolved -> resolved
      | Error error -> T.fail "bootstrap failed: %s" (Mirror.error_message error)
    in
    let db = Sqlite3.db_open resolved.database_path in
    Sqlite3.Rc.check
      (Sqlite3.exec db "UPDATE sync_meta SET checksum = 'bad' WHERE singleton = 1");
    T.require (Sqlite3.db_close db) "unable to close tampered sync_meta";
    (match Mirror.resolve ~application_support_directory:fixture.support ~graph_id with
     | Error _ -> ()
     | Ok _ -> T.fail "corrupt sync_meta resolved");
    match Engine.open_ ~dependencies (config fixture.support) with
    | Error error ->
      T.require
        (Logseq_db_worker.Error.code error = Corrupt_storage)
        "corrupt sync_meta returned the wrong engine error"
    | Ok engine ->
      ignore (Engine.close engine);
      T.fail "engine opened corrupt sync_meta")
;;

let confirmed_delete_removes_only_selected_mirror_case () =
  with_fixture (fun fixture ->
    let resolved =
      match bootstrap fixture () with
      | Ok resolved -> resolved
      | Error error -> T.fail "bootstrap failed: %s" (Mirror.error_message error)
    in
    let unrelated = Filename.concat fixture.support "keep-me" in
    let channel = open_out_bin unrelated in
    close_out channel;
    (match Mirror.delete ~application_support_directory:fixture.support ~graph_id with
     | Ok () -> ()
     | Error error -> T.fail "mirror deletion failed: %s" (Mirror.error_message error));
    T.require
      (not (Sys.file_exists resolved.graph_dir))
      "mirror directory survived deletion";
    T.require (Sys.file_exists unrelated) "mirror deletion escaped its graph directory";
    T.require
      (Mirror.resolve ~application_support_directory:fixture.support ~graph_id
       = Error Mirror.Mirror_missing)
      "deleted mirror still resolves")
;;

let deployed_snapshot_decryptor () =
  let crypto =
    { Logseq_db_worker.Sync_e2ee.unavailable_crypto with
      decrypt_aes_gcm =
        (fun ~key:_ ~iv:_ ~ciphertext ->
          Ok (Transit_codec.to_string (Transit.String ciphertext)))
    }
  in
  fun ciphertext ->
    match
      Logseq_db_worker.Sync_e2ee.decrypt_value
        ~crypto
        ~graph_key:"deployed-snapshot-contract"
        ciphertext
    with
    | Ok (Transit.String plaintext) -> Ok plaintext
    | Ok _ -> Error "deployed snapshot decrypted to a non-string value"
    | Error _ as error -> error
;;

let deployed_snapshot_contract_case () =
  match
    ( Sys.getenv_opt "LOGSEQ_DB_SYNC_REAL_SNAPSHOT_PATH"
    , Sys.getenv_opt "LOGSEQ_DB_SYNC_REAL_GRAPH_ID"
    , Sys.getenv_opt "LOGSEQ_DB_SYNC_REAL_SERVER_T"
    , Sys.getenv_opt "LOGSEQ_DB_SYNC_REAL_ROW_COUNT" )
  with
  | Some snapshot_path, Some graph_id_text, Some server_t, Some row_count ->
    F.with_temp_directory "logseq-real-sync-mirror-" (fun support ->
      let graph_id = uuid graph_id_text in
      let checksum =
        match Sys.getenv_opt "LOGSEQ_DB_SYNC_REAL_CHECKSUM" with
        | Some value when not (String.equal value "") -> Some value
        | None | Some _ -> None
      in
      let decrypt_protected =
        match Sys.getenv_opt "LOGSEQ_DB_SYNC_REAL_VALIDATE_E2EE" with
        | Some "true" -> Some (deployed_snapshot_decryptor ())
        | None -> None
        | Some _ -> T.fail "LOGSEQ_DB_SYNC_REAL_VALIDATE_E2EE must be true"
      in
      match
        Mirror.bootstrap
          ~application_support_directory:support
          ~graph_id
          ~applied_server_t:(int_of_string server_t)
          ?checksum
          ~expected_rows:(int_of_string row_count)
          ~snapshot_path
          ?decrypt_protected
          ()
      with
      | Error error ->
        T.fail "deployed snapshot bootstrap failed: %s" (Mirror.error_message error)
      | Ok resolved ->
        T.require
          (Sys.file_exists resolved.database_path)
          "deployed snapshot did not activate a mirror")
  | None, None, None, None -> ()
  | _ -> T.fail "deployed snapshot contract environment is incomplete"
;;

let cases =
  [ T.case "atomically bootstrap and resolve an upstream snapshot" valid_bootstrap_case
  ; T.case
      "compute checksum when snapshot metadata omits it"
      computed_checksum_bootstrap_case
  ; T.case
      "materialize encrypted snapshots as plaintext mirrors"
      encrypted_snapshot_materializes_plaintext_case
  ; T.case
      "activate a file-backed bootstrap target during engine open"
      engine_bootstrap_target_case
  ; T.case
      "derive bootstrap schema from the snapshot instead of the catalog"
      engine_derives_bootstrap_schema_from_snapshot_case
  ; T.case
      "report an unsupported schema discovered inside a synced snapshot"
      engine_reports_unsupported_bootstrap_schema_case
  ; T.case
      "reject incomplete snapshot and metadata before activation"
      atomic_rejection_case
  ; T.case "reject a snapshot for another remote graph" identity_mismatch_case
  ; T.case
      "never replace an existing mirror implicitly"
      existing_mirror_is_not_replaced_case
  ; T.case "open a synced mirror read-only and reject direct writes" read_only_engine_case
  ; T.case "reject corrupt versioned sync_meta" corrupt_sync_meta_case
  ; T.case
      "confirmed deletion removes only the selected mirror"
      confirmed_delete_removes_only_selected_mirror_case
  ; T.case
      "bootstrap a deployed snapshot when its contract is provided"
      deployed_snapshot_contract_case
  ]
;;

let () = T.run "sync mirror" cases
