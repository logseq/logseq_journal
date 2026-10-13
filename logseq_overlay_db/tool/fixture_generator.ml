let server_cursor_of_int value =
  Logseq_db_types.Server_cursor.of_int64 (Int64.of_int value) |> Result.get_ok
;;

module Graph = Logseq_db_types.Graph_types
module Types = Logseq_overlay_db.Types

let uuid text =
  match Graph.Uuid.of_string text with
  | Ok uuid -> uuid
  | Error message -> invalid_arg message
;;

let block_uuid ordinal = uuid (Printf.sprintf "20000000-0000-4000-8000-%012d" ordinal)
let mutation_uuid ordinal = uuid (Printf.sprintf "90000000-0000-4000-8000-%012d" ordinal)

let ensure_directory path =
  let rec create path =
    if Sys.file_exists path
    then ()
    else (
      create (Filename.dirname path);
      Unix.mkdir path 0o700)
  in
  create path
;;

type fixture_row =
  { addr : int
  ; content : string
  ; addresses : string option
  }
[@@deriving yojson { strict = false }]

type storage_fixture =
  { table_sql : string [@key "tableSql"]
  ; rows : fixture_row list
  }
[@@deriving yojson { strict = false }]

let seed_mirror ~application_support_directory ~block_count =
  let graph_id = uuid "60000000-0000-4000-8000-000000000001" in
  let directory =
    Filename.concat
      application_support_directory
      (Filename.concat "logseq-db-worker/synced-graphs" (Graph.Uuid.to_string graph_id))
  in
  ensure_directory directory;
  let database_path = Filename.concat directory "db.sqlite" in
  let rec repository_root path =
    if Sys.file_exists (Filename.concat path "dune-project")
    then path
    else repository_root (Filename.dirname path)
  in
  let fixture =
    Filename.concat
      (repository_root (Sys.getcwd ()))
      "logseq_db_worker/test/fixtures/storage/logseq-65.33-create-page.json"
    |> Yojson.Safe.from_file
    |> storage_fixture_of_yojson
    |> Result.get_ok
  in
  let sqlite = Sqlite3.db_open database_path in
  Sqlite3.Rc.check (Sqlite3.exec sqlite fixture.table_sql);
  let statement =
    Sqlite3.prepare sqlite "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
  in
  fixture.rows
  |> List.iter (fun (row : fixture_row) ->
    Sqlite3.Rc.check (Sqlite3.reset statement);
    Sqlite3.Rc.check (Sqlite3.bind_int statement 1 row.addr);
    Sqlite3.Rc.check (Sqlite3.bind_text statement 2 row.content);
    Sqlite3.Rc.check
      (Sqlite3.bind
         statement
         3
         (match row.addresses with
          | None -> Sqlite3.Data.NULL
          | Some value -> TEXT value));
    Sqlite3.Rc.check (Sqlite3.step statement));
  ignore (Sqlite3.finalize statement);
  if not (Sqlite3.db_close sqlite) then failwith "unable to close storage fixture";
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Session = Logseq_db_storage.Storage_session in
  let connection = Storage.open_database database_path |> Result.get_ok in
  let database = Storage.restore_database connection |> Result.get_ok in
  let session =
    Session.create
      ~tail:
        (Datascript.Storage.restore_tail_groups (Storage.datascript_storage connection))
      ~callbacks:(Storage.connection_callbacks connection)
  in
  let page = Datascript.Temp_id "performance-page" in
  let overflow_page = Datascript.Temp_id "performance-overflow-page" in
  let remote id ident value =
    Datascript.Entity
      { db_id = Some (Temp_id id)
      ; attrs = [ "db/ident", One_value (Keyword ident); "kv/value", One_value value ]
      }
  in
  let page_ops =
    [ Datascript.Add (page, "block/uuid", Uuid "10000000-0000-4000-8000-000000000001")
    ; Add (page, "block/name", String "performance fixture")
    ; Add (page, "block/title", String "Performance fixture")
    ; Add (overflow_page, "block/uuid", Uuid "10000000-0000-4000-8000-000000000002")
    ; Add (overflow_page, "block/name", String "performance overflow fixture")
    ; Add (overflow_page, "block/title", String "Performance overflow fixture")
    ]
  in
  let journal_ops =
    List.init 512 (fun index ->
      let entity = Datascript.Temp_id (Printf.sprintf "performance-journal-%d" index) in
      let uuid = Printf.sprintf "10000000-0000-4000-8001-%012d" index in
      let title = Printf.sprintf "Journal %d" index in
      [ Datascript.Add (entity, "block/uuid", Uuid uuid)
      ; Add (entity, "block/name", String (String.lowercase_ascii title))
      ; Add (entity, "block/title", String title)
      ; Add (entity, "block/journal-day", Int64 (Int64.of_int (2_026_01_01 + index)))
      ])
    |> List.concat
  in
  let block_ops first count =
    List.init count (fun offset ->
      let index = first + offset in
      let page_uuid =
        if index < 256
        then "10000000-0000-4000-8000-000000000001"
        else "10000000-0000-4000-8000-000000000002"
      in
      let page = Datascript.Lookup_ref ("block/uuid", Uuid page_uuid) in
      let entity = Datascript.Temp_id (Printf.sprintf "performance-block-%d" index) in
      [ Datascript.Add
          (entity, "block/uuid", Uuid (Graph.Uuid.to_string (block_uuid index)))
      ; Add (entity, "block/title", String (Printf.sprintf "Block %d" index))
      ; Add (entity, "block/order", String (Printf.sprintf "a%08d" index))
      ; Add (entity, "block/parent", Ref_to page)
      ; Add (entity, "block/page", Ref_to page)
      ])
    |> List.concat
  in
  let identity_staged =
    Session.stage_transact
      session
      ~authoritative_before:database
      ((remote "performance-remote" "logseq.kv/graph-remote?" (Bool true)
        :: remote
             "performance-graph"
             "logseq.kv/graph-uuid"
             (Uuid (Graph.Uuid.to_string graph_id))
        :: page_ops)
       @ journal_ops)
    |> Result.get_ok
  in
  let database = Session.staged_db_after identity_staged in
  Session.commit_staged session identity_staged |> Result.get_ok;
  let rec seed_blocks database first =
    if first >= block_count
    then ()
    else (
      let count = Int.min 1_000 (block_count - first) in
      let staged =
        Session.stage_transact
          session
          ~authoritative_before:database
          (block_ops first count)
        |> Result.get_ok
      in
      let database = Session.staged_db_after staged in
      Session.commit_staged session staged |> Result.get_ok;
      seed_blocks database (first + count))
  in
  seed_blocks database 0;
  Session.close session |> Result.get_ok;
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
  let checkpoint =
    Logseq_db_types.Sync_checkpoint.create
      ~graph_id
      ~schema:Graph.{ major = 65; minor = 33 }
      ~applied_server_t:(server_cursor_of_int 0)
      ~checksum:"0000000000000000"
    |> Result.get_ok
  in
  Logseq_db_storage.Sync_checkpoint_store.initialize_database sqlite checkpoint
  |> Result.get_ok;
  Logseq_db_storage.Sync_outbox_store.initialize_database sqlite |> Result.get_ok;
  Logseq_db_storage.Mutation_receipt_store.initialize_database sqlite |> Result.get_ok;
  if not (Sqlite3.db_close sqlite) then failwith "unable to close performance fixture";
  graph_id, database_path
;;

let outbox_generation = ref 0

let seed_outbox ~database_path ~block_count ~count =
  if count < 0 || count > 4_096 then invalid_arg "invalid performance outbox size";
  if count > 0 && block_count <= 0 then invalid_arg "outbox needs existing blocks";
  let module Store = Logseq_db_storage.Sync_outbox_store in
  let module Database = Logseq_overlay_db.Database in
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Sqlite3.Rc.check (Sqlite3.exec sqlite "BEGIN IMMEDIATE");
       (match Store.read_revision sqlite |> Result.get_ok with
        | None -> Store.replace_database sqlite [] |> Result.get_ok
        | Some expected_revision ->
          let deletes = ref [] in
          Sqlite3.Rc.check
            (Sqlite3.exec sqlite "SELECT mutation_id FROM sync_outbox" ~cb:(fun row _ ->
               deletes := Option.get row.(0) :: !deletes));
          Store.apply_delta
            sqlite
            { expected_revision
            ; revision = expected_revision + 1
            ; upserts = []
            ; deletes = !deletes
            }
          |> Result.get_ok);
       Sqlite3.Rc.check (Sqlite3.exec sqlite "COMMIT"));
  incr outbox_generation;
  let generation = !outbox_generation in
  let graph_id = uuid (Filename.basename (Filename.dirname database_path)) in
  let support =
    database_path
    |> Filename.dirname
    |> Filename.dirname
    |> Filename.dirname
    |> Filename.dirname
  in
  let inspection =
    Database.inspect_mirror ~application_support_directory:support ~graph_id
    |> Result.get_ok
  in
  let clock = ref 1_704_067_200_000L in
  let dependencies =
    Database.dependencies
      ~epoch_ms:(fun () ->
        clock := Int64.succ !clock;
        !clock)
      ~monotonic_ns:(fun () -> Int64.mul !clock 1_000_000L)
      ~limits:
        Types.
          { response_budget_bytes = 8 * 1_024 * 1_024
          ; outbox_max_records = 4_096
          ; outbox_max_bytes = 8 * 1_024 * 1_024
          ; change_max_items = 4_096
          ; change_max_bytes = 8 * 1_024 * 1_024
          ; dispatcher_capacity = 128
          ; wire_batch_max_bytes = 8 * 1_024 * 1_024
          }
    |> Result.get_ok
  in
  Eio.Switch.run (fun sw ->
    let database =
      Database.open_ ~sw dependencies inspection ~graph_name:"performance-fixture"
      |> Result.get_ok
    in
    Fun.protect
      ~finally:(fun () -> Database.close database |> Result.get_ok)
      (fun () ->
         for ordinal = 0 to count - 1 do
           let block = block_uuid (ordinal mod block_count) in
           let snapshot = Database.current_snapshot database |> Result.get_ok in
           let revision =
             Fun.protect
               ~finally:(fun () -> Database.release_snapshot snapshot)
               (fun () ->
                  match Database.get_blocks snapshot [ block ] |> Result.get_ok with
                  | [ Types.Present_block { revision; _ } ] -> revision
                  | _ -> failwith "performance outbox block is missing")
           in
           let expected =
             Database.write_precondition ~blocks:[ block, revision ] ~pages:[] ~scopes:[]
             |> Result.get_ok
           in
           Database.commit_local
             database
             ~expected
             (Types.Save_block
                { mutation_id = mutation_uuid ((generation * 1_000_000) + ordinal)
                ; block
                ; title = Printf.sprintf "Pending title %d" ordinal
                })
           |> Result.get_ok
           |> ignore
         done))
;;

let outbox_bytes ~database_path =
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       let statement =
         Sqlite3.prepare sqlite "SELECT COALESCE(SUM(LENGTH(record)), 0) FROM sync_outbox"
       in
       Fun.protect
         ~finally:(fun () -> ignore (Sqlite3.finalize statement))
         (fun () ->
            match Sqlite3.step statement with
            | Sqlite3.Rc.ROW -> Sqlite3.column_int statement 0
            | rc ->
              failwith
                (Printf.sprintf
                   "unable to measure outbox bytes: %s"
                   (Sqlite3.Rc.to_string rc))))
;;

let fixture_checksum ~block_count =
  Digestif.SHA256.digest_string
    (Printf.sprintf "logseq-overlay-db-performance-v1:%d" block_count)
  |> Digestif.SHA256.to_hex
;;
