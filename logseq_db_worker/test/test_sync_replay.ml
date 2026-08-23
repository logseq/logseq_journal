module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module Replay = Logseq_db_worker.Sync_replay
module Checksum = Logseq_db_worker.Sync_checksum
module Protocol = Logseq_db_worker.Sync_protocol
module Meta = Logseq_db_worker__Sync_meta
module Storage = Logseq_db_worker__Logseq_sqlite_storage
module Session = Logseq_db_worker__Storage_session
module Codec = Logseq_db_worker__Logseq_sqlite_codec
module Structural = Logseq_db_worker_test_support.Structural_fixture

let graph_id_text = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
let page_uuid = "11111111-1111-4111-8111-111111111111"

let graph_id =
  match Logseq_db_worker.Graph_types.Uuid.of_string graph_id_text with
  | Ok value -> value
  | Error message -> T.fail "%s" message
;;

let fixture () = T.read_json (T.fixture "sync/upstream-fab2774-replay.json")

let fixture_string name =
  fixture () |> Yojson.Safe.Util.member name |> Yojson.Safe.Util.to_string
;;

let expect_ok label = function
  | Ok value -> value
  | Error message -> T.fail "%s: %s" label (Replay.error_message message)
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> T.fail "%s unexpectedly succeeded" label
;;

let baseline_db () =
  let page = Datascript.Temp_id "page" in
  let block = Datascript.Temp_id "block" in
  let entity id ident value =
    Datascript.Entity
      { db_id = Some (Temp_id id)
      ; attrs = [ "db/ident", One_value (Keyword ident); "kv/value", One_value value ]
      }
  in
  Datascript.empty_db ~schema:Structural.schema ()
  |> Datascript.db_with
       [ Datascript.Add (page, "block/uuid", Uuid page_uuid)
       ; Add (page, "block/name", String "inbox")
       ; Add (page, "block/title", String "Inbox")
       ; Add (block, "block/uuid", Uuid "22222222-2222-4222-8222-222222222222")
       ; Add (block, "block/parent", Ref_to page)
       ; Add (block, "block/page", Ref_to page)
       ; Add (block, "block/order", String "a0")
       ; Add (block, "block/title", String "First")
       ; entity "remote-flag" "logseq.kv/graph-remote?" (Bool true)
       ; entity "remote-uuid" "logseq.kv/graph-uuid" (Uuid graph_id_text)
       ]
;;

let create_graph_database path =
  let memory = Datascript.memory_storage () in
  Datascript.store ~storage:memory (baseline_db ());
  let entries =
    memory.storage_list_addresses ()
    |> List.map (fun address ->
      match memory.storage_restore address with
      | Some payload -> address, payload
      | None -> T.fail "memory storage lost address %s" address)
  in
  let encoded =
    match Codec.encode_physical_batch ~restore:memory.storage_restore entries with
    | Ok value -> value
    | Error _ -> T.fail "unable to encode replay fixture storage"
  in
  let sqlite = Sqlite3.db_open path in
  Sqlite3.Rc.check
    (Sqlite3.exec
       sqlite
       "CREATE TABLE kvs(addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)");
  let statement =
    Sqlite3.prepare sqlite "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
  in
  List.iter
    (fun entry ->
       Sqlite3.Rc.check (Sqlite3.reset statement);
       Sqlite3.Rc.check (Sqlite3.bind_int statement 1 (int_of_string entry.Codec.address));
       Sqlite3.Rc.check (Sqlite3.bind_text statement 2 entry.content);
       Sqlite3.Rc.check
         (Sqlite3.bind_text
            statement
            3
            (Yojson.Safe.to_string
               (`List (List.map (fun value -> `Int (int_of_string value)) entry.addresses))));
       Sqlite3.Rc.check (Sqlite3.step statement))
    encoded;
  ignore (Sqlite3.finalize statement);
  T.require (Sqlite3.db_close sqlite) "unable to close replay fixture database"
;;

type opened =
  { path : string
  ; connection : Storage.connection
  ; session : Session.t
  ; metadata : Meta.t
  }

let open_fixture path =
  let connection =
    match Storage.open_database path with
    | Ok value -> value
    | Error _ -> T.fail "unable to reopen replay fixture"
  in
  let storage = Storage.datascript_storage connection in
  let db =
    match Storage.restore_database connection with
    | Ok value -> value
    | Error _ -> T.fail "unable to restore reopened replay fixture"
  in
  let metadata =
    match Storage.sync_metadata connection with
    | Ok value -> value
    | Error message -> T.fail "unable to read replay metadata: %s" message
  in
  { path
  ; connection
  ; session =
      Session.create
        ~db
        ~tail:(Datascript.Storage.restore_tail_groups storage)
        ~callbacks:(Storage.connection_callbacks connection)
  ; metadata
  }
;;

let close opened =
  match Session.close opened.session with
  | Ok () -> ()
  | Error Session.Closed -> ()
  | Error _ -> T.fail "unable to close replay fixture"
;;

let with_fixture f =
  F.with_temp_directory "logseq-sync-replay-" (fun root ->
    let path = Filename.concat root "db.sqlite" in
    create_graph_database path;
    let baseline_connection =
      match Storage.open_database path with
      | Ok value -> value
      | Error _ -> T.fail "unable to open replay checksum fixture"
    in
    let baseline_db =
      match Storage.restore_database baseline_connection with
      | Ok value -> value
      | Error _ -> T.fail "unable to restore replay checksum fixture"
    in
    let checksum = Checksum.recompute ~e2ee:false baseline_db in
    (match Storage.close (Storage.connection_callbacks baseline_connection) with
     | Ok () -> ()
     | Error _ -> T.fail "unable to close replay checksum fixture");
    let sqlite = Sqlite3.db_open path in
    let metadata =
      Meta.create
        ~graph_id
        ~schema:Logseq_db_worker.Graph_types.{ major = 65; minor = 33 }
        ~applied_server_t:40
        ~checksum
      |> function
      | Ok value -> value
      | Error message -> T.fail "%s" message
    in
    (match Meta.initialize_database sqlite metadata with
     | Ok () -> ()
     | Error message -> T.fail "unable to initialize replay metadata: %s" message);
    T.require (Sqlite3.db_close sqlite) "unable to close replay metadata database";
    let opened = open_fixture path in
    Fun.protect ~finally:(fun () -> close opened) (fun () -> f opened))
;;

let pull ?(checksum = fixture_string "afterTitleAndOrderChecksum") () =
  Protocol.Pull_ok
    { t = 42
    ; checksum = Some checksum
    ; txs =
        [ { t = 41; tx = fixture_string "titleTx"; outliner_op = Some "save-block" }
        ; { t = 42; tx = fixture_string "orderTx"; outliner_op = None }
        ]
    }
;;

let find_page_title db =
  let entity =
    match
      Datascript.datoms
        db
        Datascript.Avet
        ~a:"block/uuid"
        ~v:(Datascript.Uuid page_uuid)
        ()
      |> List.of_seq
    with
    | [ datom ] -> datom.Datascript.e
    | _ -> T.fail "oracle page is missing"
  in
  match
    Datascript.datoms db Datascript.Eavt ~e:entity ~a:"block/title" () |> List.of_seq
  with
  | [ { Datascript.v = String title; _ } ] -> title
  | _ -> T.fail "oracle page title is missing"
;;

let ordered_atomic_apply_case () =
  with_fixture (fun opened ->
    let outcome =
      Replay.apply_pull ~session:opened.session ~metadata:opened.metadata (pull ())
      |> expect_ok "ordered replay"
    in
    let applied =
      match outcome with
      | Replay.Applied value -> value
      | Duplicate _ | Paused _ -> T.fail "fresh pull was not applied"
    in
    T.require (applied.metadata.applied_server_t = 42) "server t did not advance";
    T.require
      (String.equal
         applied.metadata.checksum
         (fixture_string "afterTitleAndOrderChecksum"))
      "checksum did not commit";
    T.require
      (Int64.sub applied.basis_after applied.basis_before = 2L)
      "two ordered remote transactions did not advance two local basis values";
    T.require
      (List.exists
         (fun uuid ->
            String.equal
              (Logseq_db_worker.Graph_types.Uuid.to_string uuid)
              "22222222-2222-4222-8222-222222222222")
         applied.changed_uuids)
      "replay invalidation omitted the changed block";
    let db = Session.current_db opened.session in
    let block =
      Datascript.datoms
        db
        Datascript.Avet
        ~a:"block/uuid"
        ~v:(Datascript.Uuid "22222222-2222-4222-8222-222222222222")
        ()
      |> Seq.uncons
      |> Option.get
      |> fst
      |> fun datom -> datom.Datascript.e
    in
    let values attr =
      Datascript.datoms db Datascript.Eavt ~e:block ~a:attr ()
      |> List.of_seq
      |> List.map (fun datom -> datom.Datascript.v)
    in
    T.require (values "block/title" = [ Datascript.String "First updated" ]) "title lost";
    T.require (values "block/order" = [ Datascript.String "a1" ]) "order lost";
    let duplicate =
      Replay.apply_pull ~session:opened.session ~metadata:applied.metadata (pull ())
      |> expect_ok "duplicate replay"
    in
    match duplicate with
    | Replay.Duplicate duplicate ->
      T.require
        (Int64.equal duplicate.basis applied.basis_after)
        "duplicate replay advanced the local basis"
    | Applied _ | Paused _ -> T.fail "duplicate replay was not idempotent")
;;

let checksum_free_pull_computes_local_checksum_case () =
  with_fixture (fun opened ->
    let wire =
      Yojson.Safe.to_string
        (`Assoc
            [ "type", `String "pull/ok"
            ; "t", `Int 42
            ; ( "txs"
              , `List
                  [ `Assoc
                      [ "t", `Int 41
                      ; "tx", `String (fixture_string "titleTx")
                      ; "outliner-op", `String "save-block"
                      ]
                  ; `Assoc [ "t", `Int 42; "tx", `String (fixture_string "orderTx") ]
                  ] )
            ])
    in
    let message =
      match Protocol.decode_http_pull_response wire with
      | Ok message -> message
      | Error error -> T.fail "checksum-free pull did not decode: %s" error
    in
    let applied =
      match
        Replay.apply_pull ~session:opened.session ~metadata:opened.metadata message
        |> expect_ok "checksum-free replay"
      with
      | Replay.Applied value -> value
      | Duplicate _ | Paused _ -> T.fail "checksum-free advancing pull was not applied"
    in
    let expected = Checksum.recompute ~e2ee:false (Session.current_db opened.session) in
    T.require
      (String.equal applied.metadata.checksum expected)
      "checksum-free replay did not persist its computed local checksum";
    match
      Replay.apply_pull ~session:opened.session ~metadata:applied.metadata message
      |> expect_ok "checksum-free duplicate replay"
    with
    | Replay.Duplicate _ -> ()
    | Applied _ | Paused _ -> T.fail "checksum-free duplicate was not idempotent")
;;

let invalid_pull_preserves_state_case () =
  with_fixture (fun opened ->
    let basis =
      (Datascript.serializable (Session.current_db opened.session)).serializable_max_tx
      |> Int64.of_int
    in
    let gap =
      Protocol.Pull_ok
        { t = 42
        ; checksum = Some opened.metadata.checksum
        ; txs = [ { t = 42; tx = fixture_string "titleTx"; outliner_op = None } ]
        }
    in
    expect_error
      "server t gap"
      (Replay.apply_pull ~session:opened.session ~metadata:opened.metadata gap);
    let malformed =
      Protocol.Pull_ok
        { t = 41
        ; checksum = Some opened.metadata.checksum
        ; txs = [ { t = 41; tx = "not transit"; outliner_op = None } ]
        }
    in
    expect_error
      "malformed Transit"
      (Replay.apply_pull ~session:opened.session ~metadata:opened.metadata malformed);
    T.require
      ((Datascript.serializable (Session.current_db opened.session)).serializable_max_tx
       |> Int64.of_int
       |> Int64.equal basis)
      "rejected pull changed local basis";
    T.require
      ((Storage.sync_metadata opened.connection |> Result.get_ok).applied_server_t = 40)
      "rejected pull advanced durable server t")
;;

let checksum_mismatch_pauses_without_replacing_graph_case () =
  with_fixture (fun opened ->
    let title_before = find_page_title (Session.current_db opened.session) in
    let outcome =
      Replay.apply_pull
        ~session:opened.session
        ~metadata:opened.metadata
        (pull ~checksum:"0000000000000000" ())
      |> expect_ok "checksum mismatch"
    in
    let paused =
      match outcome with
      | Replay.Paused value -> value
      | Applied _ | Duplicate _ -> T.fail "checksum mismatch did not pause sync"
    in
    T.require (paused.metadata.applied_server_t = 40) "paused sync advanced server t";
    T.require
      (paused.metadata.status = Meta.Paused)
      "paused state was not written to sync_meta";
    T.require (Option.is_some paused.metadata.last_error) "paused state lost its error";
    T.require
      (String.equal title_before (find_page_title (Session.current_db opened.session)))
      "checksum mismatch replaced the usable graph";
    expect_error
      "apply while paused"
      (Replay.apply_pull ~session:opened.session ~metadata:paused.metadata (pull ()));
    let durable = Storage.sync_metadata opened.connection |> Result.get_ok in
    T.require (durable.status = Meta.Paused) "pause was not durable";
    T.require (durable.applied_server_t = 40) "durable pause advanced server t")
;;

let metadata_write_failure_rolls_back_kvs_case () =
  with_fixture (fun opened ->
    let sqlite = Sqlite3.db_open opened.path in
    Sqlite3.Rc.check
      (Sqlite3.exec
         sqlite
         "CREATE TRIGGER fail_sync_meta_update BEFORE UPDATE ON sync_meta BEGIN SELECT \
          RAISE(ABORT, 'injected sync metadata failure'); END");
    T.require (Sqlite3.db_close sqlite) "unable to install metadata failure trigger";
    expect_error
      "metadata write failure"
      (Replay.apply_pull ~session:opened.session ~metadata:opened.metadata (pull ()));
    close opened;
    let reopened = open_fixture opened.path in
    Fun.protect
      ~finally:(fun () -> close reopened)
      (fun () ->
         T.require
           (reopened.metadata.applied_server_t = 40)
           "failed atomic commit advanced server t";
         T.require
           (not
              (String.equal
                 (Checksum.recompute ~e2ee:false (Session.current_db reopened.session))
                 (fixture_string "afterTitleAndOrderChecksum")))
           "failed metadata write committed KVS state"))
;;

let cases =
  [ T.case
      "atomically apply ordered pull and ignore duplicate replay"
      ordered_atomic_apply_case
  ; T.case
      "apply checksum-free pulls using the computed local checksum"
      checksum_free_pull_computes_local_checksum_case
  ; T.case
      "reject gaps and malformed Transit without advancement"
      invalid_pull_preserves_state_case
  ; T.case
      "persist checksum pause while preserving local use"
      checksum_mismatch_pauses_without_replacing_graph_case
  ; T.case
      "roll back KVS when sync_meta update fails"
      metadata_write_failure_rolls_back_kvs_case
  ]
;;

let () = T.run "sync replay" cases
