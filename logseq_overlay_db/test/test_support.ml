module Database = Logseq_overlay_db.Database
module Graph = Logseq_db_types.Graph_types
module Types = Logseq_overlay_db.Types
open Types

let fail format = Printf.ksprintf (fun message -> Alcotest.failf "%s" message) format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then Alcotest.fail message) format
;;

let require_ok ~behavior = function
  | Ok value -> value
  | Error _ -> Alcotest.failf "missing overlay behavior: %s" behavior
;;

let uuid value =
  Graph.Uuid.of_string value
  |> require_ok ~behavior:(Printf.sprintf "parse fixture UUID %s" value)
;;

let graph_uuid = uuid "60000000-0000-4000-8000-000000000001"
let page_uuid = uuid "11111111-1111-4111-8111-111111111111"
let missing_page_uuid = uuid "11111111-1111-4111-8111-111111111112"
let block_uuid = uuid "22222222-2222-4222-8222-222222222221"
let child_uuid = uuid "22222222-2222-4222-8222-222222222222"
let missing_block_uuid = uuid "22222222-2222-4222-8222-222222222223"
let authoritative_block_uuid = uuid "22222222-2222-4222-8222-222222222224"
let reference_source_uuid = uuid "22222222-2222-4222-8222-222222222225"
let default_value_uuid = uuid "22222222-2222-4222-8222-222222222226"
let property_holder_uuid = uuid "22222222-2222-4222-8222-222222222227"
let malformed_default_value_uuid = uuid "22222222-2222-4222-8222-222222222228"
let mutation_uuid ordinal = uuid (Printf.sprintf "90000000-0000-4000-8000-%012d" ordinal)

let rec repository_root directory =
  if Sys.file_exists (Filename.concat directory "dune-project")
  then directory
  else (
    let parent = Filename.dirname directory in
    if String.equal parent directory
    then Alcotest.fail "unable to locate repository root"
    else repository_root parent)
;;

let root = repository_root (Sys.getcwd ())

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

let copy_storage_fixture database_path =
  let open Yojson.Safe.Util in
  let fixture_path =
    Filename.concat
      root
      "logseq_db_worker/test/fixtures/storage/logseq-65.33-create-page.json"
  in
  let fixture = Yojson.Safe.from_file fixture_path in
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
          | _ -> Alcotest.fail "storage fixture has malformed addresses"));
    Sqlite3.Rc.check (Sqlite3.step statement));
  ignore (Sqlite3.finalize statement);
  require (Sqlite3.db_close db) "unable to close storage fixture"
;;

let install_remote_identity database_path =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Session = Logseq_db_storage.Storage_session in
  let connection =
    Storage.open_database database_path
    |> require_ok ~behavior:"open lower storage fixture"
  in
  let storage = Storage.datascript_storage connection in
  let database =
    Storage.restore_database connection
    |> require_ok ~behavior:"restore lower storage fixture"
  in
  let session =
    Session.create
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
    let block = Datascript.Temp_id "authoritative-block" in
    let reference_source = Datascript.Temp_id "reference-source" in
    let default_value = Datascript.Temp_id "default-property-value" in
    let property_holder = Datascript.Temp_id "default-property-holder" in
    let property = Datascript.Temp_id "default-property-definition" in
    let malformed_default_value = Datascript.Temp_id "malformed-default-property-value" in
    let malformed_property = Datascript.Temp_id "malformed-default-property-definition" in
    let page =
      Datascript.Lookup_ref
        ("block/uuid", Datascript.Uuid (Graph.Uuid.to_string page_uuid))
    in
    Session.stage_transact
      session
      ~authoritative_before:database
      [ entity "remote-flag" "logseq.kv/graph-remote?" (Bool true)
      ; entity
          "remote-uuid"
          "logseq.kv/graph-uuid"
          (Uuid (Graph.Uuid.to_string graph_uuid))
      ; Datascript.Add
          (block, "block/uuid", Uuid (Graph.Uuid.to_string authoritative_block_uuid))
      ; Add (block, "block/title", String "Authoritative block")
      ; Add (block, "block/parent", Ref_to page)
      ; Add (block, "block/page", Ref_to page)
      ; Add (block, "block/order", String "a00000001")
      ; Add (block, "block/created-at", Int 1_704_067_200_000)
      ; Add (block, "block/updated-at", Int 1_704_067_200_000)
      ; Datascript.Add
          ( reference_source
          , "block/uuid"
          , Uuid (Graph.Uuid.to_string reference_source_uuid) )
      ; Add
          ( reference_source
          , "block/title"
          , String ("Reference ((" ^ Graph.Uuid.to_string authoritative_block_uuid ^ "))")
          )
      ; Add (reference_source, "block/parent", Ref_to page)
      ; Add (reference_source, "block/page", Ref_to page)
      ; Add (reference_source, "block/order", String "a00000002")
      ; Add (reference_source, "block/created-at", Int 1_704_067_200_000)
      ; Add (reference_source, "block/updated-at", Int 1_704_067_200_000)
      ; Add (reference_source, "block/refs", Ref_to block)
      ; Add (default_value, "block/uuid", Uuid (Graph.Uuid.to_string default_value_uuid))
      ; Add (default_value, "block/title", String "Default property value")
      ; Add (default_value, "block/parent", Ref_to page)
      ; Add (default_value, "block/page", Ref_to page)
      ; Add (default_value, "block/order", String "a00000003")
      ; Add (default_value, "block/created-at", Int 1_704_067_200_000)
      ; Add (default_value, "block/updated-at", Int 1_704_067_200_000)
      ; Add (default_value, "logseq.property/created-from-property", Ref_to property)
      ; Add
          (property_holder, "block/uuid", Uuid (Graph.Uuid.to_string property_holder_uuid))
      ; Add (property_holder, "block/title", String "Default property holder")
      ; Add (property_holder, "block/parent", Ref_to page)
      ; Add (property_holder, "block/page", Ref_to page)
      ; Add (property_holder, "block/order", String "a00000004")
      ; Add (property_holder, "block/created-at", Int 1_704_067_200_000)
      ; Add (property_holder, "block/updated-at", Int 1_704_067_200_000)
      ; Add (property_holder, "test.property/default", Ref_to default_value)
      ; Add (property, "db/ident", Keyword "test.property/default")
      ; Add (property, "block/uuid", Uuid "33333333-3333-4333-8333-333333333331")
      ; Add (property, "block/title", String "Test default property")
      ; Add (property, "block/tags", Ref_to (Ident "logseq.class/Property"))
      ; Add (property, "logseq.property/type", Keyword "default")
      ; Add (property, "db/valueType", Keyword "db.type/ref")
      ; Add (property, "db/cardinality", Keyword "db.cardinality/one")
      ; Add (property, "db/index", Bool true)
      ; Add
          ( property
          , "logseq.property/default-value"
          , Ref_to (Ident "logseq.property/empty-placeholder") )
      ; Add
          ( malformed_default_value
          , "block/uuid"
          , Uuid (Graph.Uuid.to_string malformed_default_value_uuid) )
      ; Add (malformed_default_value, "block/title", String "Malformed default value")
      ; Add (malformed_default_value, "block/parent", Ref_to page)
      ; Add (malformed_default_value, "block/page", Ref_to page)
      ; Add (malformed_default_value, "block/order", String "a00000005")
      ; Add (malformed_default_value, "block/created-at", Int 1_704_067_200_000)
      ; Add (malformed_default_value, "block/updated-at", Int 1_704_067_200_000)
      ; Add
          ( malformed_default_value
          , "logseq.property/created-from-property"
          , Ref_to malformed_property )
      ; Add
          ( malformed_property
          , "logseq.property/default-value"
          , Ref_to (Ident "logseq.property/empty-placeholder") )
      ]
    |> require_ok ~behavior:"stage fixture remote identity"
  in
  Session.commit_staged session staged
  |> require_ok ~behavior:"commit fixture remote identity";
  Session.close session |> require_ok ~behavior:"close lower storage fixture"
;;

let seed_mirror support =
  let graph_dir =
    Filename.concat
      support
      (Filename.concat "logseq-db-worker/synced-graphs" (Graph.Uuid.to_string graph_uuid))
  in
  ensure_directory graph_dir;
  let database_path = Filename.concat graph_dir "db.sqlite" in
  copy_storage_fixture database_path;
  install_remote_identity database_path;
  let checkpoint =
    Logseq_db_types.Sync_checkpoint.create
      ~graph_id:graph_uuid
      ~schema:Graph.{ major = 65; minor = 33 }
      ~applied_server_t:0
      ~checksum:"0000000000000000"
    |> require_ok ~behavior:"construct fixture checkpoint"
  in
  let sqlite = Sqlite3.db_open database_path in
  Logseq_db_storage.Sync_checkpoint_store.initialize_database sqlite checkpoint
  |> require_ok ~behavior:"initialize fixture checkpoint";
  Logseq_db_storage.Sync_outbox_store.initialize_database sqlite
  |> require_ok ~behavior:"initialize fixture outbox";
  require (Sqlite3.db_close sqlite) "unable to close fixture metadata database";
  database_path
;;

let write_snapshot_from_database ~database_path ~snapshot_path =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
  let statement =
    Sqlite3.prepare sqlite "SELECT addr, content, addresses FROM kvs ORDER BY addr"
  in
  let rec rows reversed =
    match Sqlite3.step statement with
    | Sqlite3.Rc.ROW ->
      let addr = Sqlite3.column_int statement 0 in
      let content = Sqlite3.column_text statement 1 in
      let addresses =
        match Sqlite3.column statement 2 with
        | Sqlite3.Data.NULL -> Transit.Null
        | TEXT value -> Transit.String value
        | _ -> fail "snapshot fixture addresses column is not text or null"
      in
      rows
        (Transit.Array [ Transit.Int addr; Transit.String content; addresses ] :: reversed)
    | DONE -> List.rev reversed
    | rc -> fail "snapshot fixture query failed: %s" (Sqlite3.Rc.to_string rc)
  in
  let rows =
    Fun.protect
      ~finally:(fun () ->
        ignore (Sqlite3.finalize statement);
        require (Sqlite3.db_close sqlite) "unable to close snapshot source")
      (fun () -> rows [])
  in
  let payload = Codec.to_string ~mode:Codec.Verbose (Transit.Array rows) in
  let length = String.length payload in
  let prefix = Bytes.create 4 in
  Bytes.set prefix 0 (Char.chr ((length lsr 24) land 0xff));
  Bytes.set prefix 1 (Char.chr ((length lsr 16) land 0xff));
  Bytes.set prefix 2 (Char.chr ((length lsr 8) land 0xff));
  Bytes.set prefix 3 (Char.chr (length land 0xff));
  let channel = open_out_bin snapshot_path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       output_bytes channel prefix;
       output_string channel payload;
       flush channel);
  List.length rows
;;

let mark_snapshot_e2ee database_path =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Session = Logseq_db_storage.Storage_session in
  let connection =
    Storage.open_database database_path |> require_ok ~behavior:"open E2EE fixture"
  in
  let storage = Storage.datascript_storage connection in
  let database =
    Storage.restore_database connection |> require_ok ~behavior:"restore E2EE fixture"
  in
  let session =
    Session.create
      ~tail:(Datascript.Storage.restore_tail_groups storage)
      ~callbacks:(Storage.connection_callbacks connection)
  in
  let staged =
    Session.stage_transact
      session
      ~authoritative_before:database
      [ Datascript.Entity
          { db_id = Some (Temp_id "e2ee-flag")
          ; attrs =
              [ "db/ident", One_value (Keyword "logseq.kv/graph-rtc-e2ee?")
              ; "kv/value", One_value (Bool true)
              ]
          }
      ]
    |> require_ok ~behavior:"stage E2EE fixture"
  in
  Session.commit_staged session staged |> require_ok ~behavior:"commit E2EE fixture";
  Session.close session |> require_ok ~behavior:"close E2EE fixture"
;;

let limits ~behavior =
  ignore behavior;
  { Types.response_budget_bytes = 4 * 1_024 * 1_024
  ; outbox_max_records = 4_096
  ; outbox_max_bytes = 8 * 1_024 * 1_024
  ; change_max_items = 4_096
  ; change_max_bytes = 4 * 1_024 * 1_024
  ; dispatcher_capacity = 32
  ; wire_batch_max_bytes = 4 * 1_024 * 1_024
  }
;;

let dependencies_with_limits ~behavior limits =
  Database.dependencies
    ~epoch_ms:(fun () -> 1_704_067_200_000L)
    ~monotonic_ns:(fun () -> 1_000_000L)
    ~limits
  |> require_ok ~behavior
;;

let dependencies ~behavior = dependencies_with_limits ~behavior (limits ~behavior)

let crypto_result_error_equal left right =
  match left, right with
  | Types.Crypto_result_missing_item left, Types.Crypto_result_missing_item right
  | Types.Crypto_result_extra_item left, Types.Crypto_result_extra_item right
  | Types.Crypto_result_duplicate_item left, Types.Crypto_result_duplicate_item right ->
    Types.Crypto_item_id.equal left right
  | Types.Crypto_result_reordered, Types.Crypto_result_reordered
  | Types.Crypto_result_stale, Types.Crypto_result_stale
  | Types.Crypto_result_limit_exceeded, Types.Crypto_result_limit_exceeded -> true
  | _ -> false
;;

let malformed_crypto_results ~maximum_value_bytes items =
  match items with
  | (first_id, first_value) :: (second_id, second_value) :: rest ->
    let extra_id =
      Types.Crypto_item_id.of_string "crypto-item:v1:test-extra"
      |> require_ok ~behavior:"construct extra crypto item ID"
    in
    [ ( "missing"
      , Types.Crypto_result_missing_item first_id
      , (second_id, second_value) :: rest )
    ; "extra", Types.Crypto_result_extra_item extra_id, items @ [ extra_id, "extra" ]
    ; ( "duplicate"
      , Types.Crypto_result_duplicate_item first_id
      , (first_id, first_value) :: items )
    ; ( "reordered"
      , Types.Crypto_result_reordered
      , (second_id, second_value) :: (first_id, first_value) :: rest )
    ; ( "oversized"
      , Types.Crypto_result_limit_exceeded
      , (first_id, String.make (maximum_value_bytes + 1) 'x')
        :: (second_id, second_value)
        :: rest )
    ]
  | _ -> Alcotest.fail "crypto validation fixture did not expose at least two items"
;;

let with_database_using_limits ~behavior limits f =
  with_temp_directory "logseq-overlay-db-test-" (fun support ->
    ignore (seed_mirror support);
    let dependencies = dependencies_with_limits ~behavior limits in
    let inspection =
      Database.inspect_mirror ~application_support_directory:support ~graph_id:graph_uuid
      |> require_ok ~behavior
    in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies inspection ~graph_name:"oracle-graph"
          |> require_ok ~behavior
        in
        Fun.protect
          ~finally:(fun () ->
            try ignore (Database.close database) with
            | _ -> ())
          (fun () -> f database))))
;;

let with_database ~behavior f = with_database_using_limits ~behavior (limits ~behavior) f

let with_snapshot ~behavior f =
  with_database ~behavior (fun database ->
    let snapshot = Database.current_snapshot database |> require_ok ~behavior in
    Fun.protect
      ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () -> f database snapshot))
;;

let empty_precondition ~behavior =
  Database.write_precondition ~blocks:[] ~pages:[] ~scopes:[] |> require_ok ~behavior
;;

let insert_precondition database ~parent ~behavior =
  let snapshot = Database.current_snapshot database |> require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let page_revision =
         match Database.get_pages snapshot [ parent ] |> require_ok ~behavior with
         | [ Present_page { revision; _ } ] -> revision
         | _ -> Alcotest.fail "fixture insert parent is missing"
       in
       let revision_scope, scope_revision =
         match
           Database.get_structure
             snapshot
             (Children { parent; limit = 200; cursor = None })
           |> require_ok ~behavior
         with
         | Children_result { revision_scope; scope_revision; _ } ->
           revision_scope, scope_revision
         | Page_tree_result _ -> Alcotest.fail "children request returned a page tree"
       in
       Database.write_precondition
         ~blocks:[]
         ~pages:[ parent, page_revision ]
         ~scopes:[ revision_scope, scope_revision ]
       |> require_ok ~behavior)
;;

let delete_precondition database ~block ~behavior =
  let snapshot = Database.current_snapshot database |> require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let value, block_revision =
         match Database.get_blocks snapshot [ block ] |> require_ok ~behavior with
         | [ Present_block { value; revision } ] -> value, revision
         | _ -> Alcotest.fail "fixture delete target is missing"
       in
       let revision_scope, scope_revision =
         match
           Database.get_structure
             snapshot
             (Page_tree
                { page = value.block.page
                ; maximum_depth = 256
                ; limit = 200
                ; cursor = None
                })
           |> require_ok ~behavior
         with
         | Page_tree_result { revision_scope; scope_revision; _ } ->
           revision_scope, scope_revision
         | Children_result _ -> Alcotest.fail "page-tree request returned children"
       in
       Database.write_precondition
         ~blocks:[ block, block_revision ]
         ~pages:[]
         ~scopes:[ revision_scope, scope_revision ]
       |> require_ok ~behavior)
;;

let commit_mutation database ~expected mutation ~behavior =
  Database.commit_local database ~expected mutation |> require_ok ~behavior
;;

let save_block ?(ordinal = 1) ?(title = "Edited") () =
  Types.Save_block { mutation_id = mutation_uuid ordinal; block = block_uuid; title }
;;

let insert_blocks ?(ordinal = 2) ?(uuid = block_uuid) () =
  Types.Insert_blocks
    { mutation_id = mutation_uuid ordinal
    ; parent = page_uuid
    ; tree = { uuid; title = "Inserted"; children = [] }
    }
;;

let delete_blocks ?(ordinal = 3) () =
  Types.Delete_blocks { mutation_id = mutation_uuid ordinal; root = block_uuid }
;;

let create_journal_page ?(ordinal = 4) () =
  Types.Create_journal_page
    { mutation_id = mutation_uuid ordinal
    ; page = missing_page_uuid
    ; title = "2026-09-02"
    ; journal_day = 20260902
    }
;;

let set_task_status ?(ordinal = 5) () =
  Types.Set_task_status
    { mutation_id = mutation_uuid ordinal; block = block_uuid; status = Todo }
;;

let clear_task_status ?(ordinal = 6) () =
  Types.Clear_task_status { mutation_id = mutation_uuid ordinal; block = block_uuid }
;;

let expect_nonempty_projection ~behavior snapshot =
  let graph_info = Database.graph_info snapshot |> require_ok ~behavior in
  require
    (Graph.Uuid.equal graph_info.Types.graph_uuid graph_uuid)
    "%s returned the wrong graph UUID"
    behavior
;;

let database_case name run =
  Alcotest.test_case name `Quick (fun () -> with_database ~behavior:name run)
;;

let snapshot_case name run =
  Alcotest.test_case name `Quick (fun () -> with_snapshot ~behavior:name run)
;;
