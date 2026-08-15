module T = Logseq_db_worker_test_support.Test_support
module Storage = Logseq_db_worker__Logseq_sqlite_storage
module Session = Logseq_db_worker__Storage_session

type callback_state =
  { mutable events : string list
  ; mutable fail_address : string option
  ; mutable fail_commit : bool
  ; mutable fail_checkpoint : bool
  ; mutable fail_close : bool
  }

let callbacks ?(storage = Datascript.memory_storage ()) state =
  let staged = ref None in
  let finish_staging _metadata extras =
    match !staged with
    | None -> Error "storage staging has not begun"
    | Some captured ->
      staged := None;
      let rec encode acc = function
        | [] -> Ok Storage.{ writes = List.rev acc }
        | (address, payload) :: rest ->
          (match
             Logseq_db_worker__Logseq_sqlite_codec.encode_physical_payload payload
           with
           | Error _ -> Error "unable to encode staged batch"
           | Ok (payload, addresses) ->
             encode (Storage.{ address; payload; addresses } :: acc) rest)
      in
      encode [] (captured @ extras)
  in
  Storage.
    { storage
    ; initial_root_metadata = None
    ; begin_staging =
        (fun () ->
          staged := Some [];
          Ok ())
    ; finish_staging
    ; abort_staging = (fun () -> staged := None)
    ; begin_immediate =
        (fun () ->
          state.events <- state.events @ [ "begin" ];
          Ok ())
    ; upsert =
        (fun write ->
          state.events <- state.events @ [ "write:" ^ write.address ];
          if Option.equal String.equal state.fail_address (Some write.address)
          then Error "injected write failure"
          else Ok ())
    ; commit =
        (fun () ->
          state.events <- state.events @ [ "commit" ];
          if state.fail_commit then Error "injected commit failure" else Ok ())
    ; rollback = (fun () -> state.events <- state.events @ [ "rollback" ])
    ; unreachable_address_count = (fun () -> 0)
    ; database_size_bytes = (fun () -> 0L)
    ; checkpoint =
        (fun () ->
          if state.fail_checkpoint then Error "injected checkpoint failure" else Ok ())
    ; close =
        (fun () -> if state.fail_close then Error "injected close failure" else Ok ())
    }
;;

let state () =
  { events = []
  ; fail_address = None
  ; fail_commit = false
  ; fail_checkpoint = false
  ; fail_close = false
  }
;;

let storage_address_count storage =
  storage.Datascript.storage_list_addresses () |> List.length
;;

let sample_batch =
  Storage.
    { writes =
        [ { address = "10"; payload = "node"; addresses = [ "11" ] }
        ; { address = "0"; payload = "root"; addresses = [] }
        ; { address = "1"; payload = "tail"; addresses = [] }
        ]
    }
;;

let with_sqlite f =
  let path = Filename.temp_file "logseq-db-worker-pragma-" ".sqlite" in
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () ->
      ignore (Sqlite3.db_close db);
      Sys.remove path)
    (fun () -> f db)
;;

let exec db sql = Sqlite3.Rc.check (Sqlite3.exec db sql)

let contains_substring haystack needle =
  let needle_length = String.length needle in
  let rec search offset =
    offset + needle_length <= String.length haystack
    && (String.sub haystack offset needle_length = needle || search (offset + 1))
  in
  search 0
;;

let replace_first haystack ~needle ~replacement =
  let needle_length = String.length needle in
  let rec search offset =
    if offset + needle_length > String.length haystack
    then None
    else if String.sub haystack offset needle_length = needle
    then Some offset
    else search (offset + 1)
  in
  match search 0 with
  | None -> T.fail "fixture does not contain %s" needle
  | Some offset ->
    String.sub haystack 0 offset
    ^ replacement
    ^ String.sub
        haystack
        (offset + needle_length)
        (String.length haystack - offset - needle_length)
;;

let remove_if_exists path = if Sys.file_exists path then Sys.remove path

let with_kvs_database f =
  let path = Filename.temp_file "logseq-db-worker-kvs-" ".sqlite" in
  let db = Sqlite3.db_open path in
  exec db "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)";
  T.require (Sqlite3.db_close db) "unable to close fixture database";
  Fun.protect
    ~finally:(fun () ->
      remove_if_exists path;
      remove_if_exists (path ^ "-wal");
      remove_if_exists (path ^ "-shm"))
    (fun () -> f path)
;;

let with_database_schema schema f =
  let path = Filename.temp_file "logseq-db-worker-schema-" ".sqlite" in
  let db = Sqlite3.db_open path in
  exec db schema;
  T.require (Sqlite3.db_close db) "unable to close schema fixture database";
  Fun.protect
    ~finally:(fun () ->
      remove_if_exists path;
      remove_if_exists (path ^ "-wal");
      remove_if_exists (path ^ "-shm"))
    (fun () -> f path)
;;

let with_oracle_kvs_database f =
  let fixture = T.read_json (T.fixture "storage/logseq-65.33-create-page.json") in
  let open Yojson.Safe.Util in
  T.require
    (fixture
     |> member "source"
     |> member "logseqCommit"
     |> to_string
     = "4f21d068aed43bb2ea5823247cae73ecdd8d60f8")
    "storage fixture has the wrong Logseq commit";
  T.require
    (fixture |> member "source" |> member "schema" |> to_string = "65.33")
    "storage fixture has the wrong schema";
  let path = Filename.temp_file "logseq-db-worker-oracle-" ".sqlite" in
  let db = Sqlite3.db_open path in
  exec db (fixture |> member "tableSql" |> to_string);
  let statement =
    Sqlite3.prepare db "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize statement))
    (fun () ->
       fixture
       |> member "rows"
       |> to_list
       |> List.iter (fun row ->
         Sqlite3.Rc.check (Sqlite3.reset statement);
         Sqlite3.Rc.check
           (Sqlite3.bind_int64
              statement
              1
              (row |> member "addr" |> to_int |> Int64.of_int));
         Sqlite3.Rc.check
           (Sqlite3.bind_text statement 2 (row |> member "content" |> to_string));
         let addresses =
           match row |> member "addresses" with
           | `Null -> Sqlite3.Data.NULL
           | `String value -> Sqlite3.Data.TEXT value
           | _ -> T.fail "oracle fixture has malformed addresses"
         in
         Sqlite3.Rc.check (Sqlite3.bind statement 3 addresses);
         Sqlite3.Rc.check (Sqlite3.step statement)));
  T.require (Sqlite3.db_close db) "unable to close oracle fixture database";
  Fun.protect
    ~finally:(fun () ->
      remove_if_exists path;
      remove_if_exists (path ^ "-wal");
      remove_if_exists (path ^ "-shm"))
    (fun () -> f path)
;;

let storage_batch_of_db db =
  let entries = ref [] in
  let capture =
    Datascript.
      { storage_store = (fun writes -> entries := !entries @ writes)
      ; storage_restore = (fun _ -> None)
      ; storage_list_addresses = (fun () -> [])
      ; storage_delete = (fun _ -> ())
      }
  in
  Datascript.store ~storage:capture db;
  let writes =
    match Logseq_db_worker__Logseq_sqlite_codec.encode_physical_batch !entries with
    | Error _ -> T.fail "unable to encode physical storage batch"
    | Ok entries ->
      List.map
        (fun entry ->
           Storage.
             { address = entry.Logseq_db_worker__Logseq_sqlite_codec.address
             ; payload = entry.content
             ; addresses = entry.addresses
             })
        entries
  in
  let find address =
    match
      List.find_opt (fun write -> String.equal write.Storage.address address) writes
    with
    | Some write -> write
    | None -> T.fail "missing storage address %s" address
  in
  ignore (find Datascript.Storage.root_address);
  ignore (find Datascript.Storage.tail_address);
  Storage.{ writes }
;;

let batch_write batch address =
  match
    List.find_opt
      (fun write -> String.equal write.Storage.address address)
      batch.Storage.writes
  with
  | Some write -> write
  | None -> T.fail "batch has no address %s" address
;;

let compile_detached_staging_spike () =
  let db_before = Datascript.empty_db () in
  let report =
    Datascript.with_tx
      db_before
      [ Datascript.Add (Temp_id "spike", ":block/title", String "staged") ]
  in
  T.require
    (Datascript.db_hash db_before <> Datascript.db_hash report.db_after)
    "db_after unchanged";
  T.require (report.tx_data <> []) "staging returned no tx_data"
;;

let restored_session_reuses_db_without_implicit_persistence () =
  let storage = Datascript.memory_storage () in
  let source =
    Datascript.empty_db ()
    |> Datascript.db_with
         [ Datascript.Add
             (Temp_id "restored", "block/title", String "Restored immutable DB")
         ]
  in
  Datascript.store ~storage source;
  let restored =
    match Datascript.restore storage with
    | Some db -> db
    | None -> T.fail "unable to restore attached DataScript DB"
  in
  let session = Session.create ~db:restored ~tail:[] ~callbacks:(callbacks (state ())) in
  let staged =
    match
      Session.stage_transact
        session
        [ Datascript.Add
            (Temp_id "staged", "block/title", String "Staged without implicit storage")
        ]
    with
    | Ok staged -> staged
    | Error _ -> T.fail "unable to stage against restored DataScript DB"
  in
  ignore staged;
  T.require
    (Datascript.Storage.restore_tail_groups storage = [])
    "staging wrote directly through the restored DB storage attachment";
  T.require
    (Option.is_some (Datascript.storage (Session.current_db session)))
    "Storage_session rebuilt the restored DB instead of reusing it";
  ignore (Session.close session)
;;

let attached_session_defers_unreachable_address_count_until_gc_check () =
  let storage = Datascript.memory_storage () in
  let source =
    Datascript.empty_db ()
    |> Datascript.db_with
         [ Datascript.Add
             (Temp_id "lazy-gc", "block/title", String "Lazy GC baseline")
         ]
  in
  Datascript.store ~storage source;
  let restored =
    match Datascript.restore storage with
    | Some db -> db
    | None -> T.fail "unable to restore lazy GC fixture"
  in
  let count_calls = ref 0 in
  let base_callbacks = callbacks ~storage (state ()) in
  let callbacks =
    { base_callbacks with
      unreachable_address_count =
        (fun () ->
          incr count_calls;
          Session.garbage_collection_unreachable_address_threshold)
    }
  in
  let session = Session.create ~db:restored ~tail:[] ~callbacks in
  Fun.protect
    ~finally:(fun () -> ignore (Session.close session))
    (fun () ->
       T.require
         (!count_calls = 0)
         "session creation eagerly counted unreachable addresses";
       (match Session.garbage_collection_needed session with
        | Ok true -> ()
        | Ok false -> T.fail "deferred unreachable count did not trigger GC"
        | Error _ -> T.fail "deferred unreachable count failed");
       T.require (!count_calls = 1) "first GC check did not count exactly once";
       ignore (Session.garbage_collection_needed session);
       T.require (!count_calls = 1) "later GC check repeated the full count")
;;

let staged_session state =
  let session =
    Session.create ~db:(Datascript.empty_db ()) ~tail:[] ~callbacks:(callbacks state)
  in
  let staged =
    match
      Session.stage_transact
        session
        [ Datascript.Add (Temp_id "spike", ":block/title", String "staged") ]
    with
    | Ok staged -> staged
    | Error _ -> T.fail "unable to stage transaction"
  in
  session, staged
;;

let with_gc_session ?(callbacks_transform = Fun.id) f =
  with_kvs_database (fun path ->
    let connection =
      match Storage.open_database path with
      | Ok connection -> connection
      | Error _ -> T.fail "unable to open GC fixture storage"
    in
    let storage = Storage.datascript_storage connection in
    let callbacks = callbacks_transform (Storage.connection_callbacks connection) in
    let session =
      Session.create ~db:(Datascript.empty_db ~storage ()) ~tail:[] ~callbacks
    in
    let commit_round round =
      let operations =
        List.init 40 (fun index ->
          Datascript.Add
            ( Temp_id (Printf.sprintf "gc-%d-%d" round index)
            , "block/title"
            , String (Printf.sprintf "GC round %d item %d" round index) ))
      in
      let staged =
        match Session.stage_transact session operations with
        | Ok staged -> staged
        | Error _ -> T.fail "unable to stage GC fixture round %d" round
      in
      match Session.commit_staged session staged with
      | Ok () -> ()
      | Error _ -> T.fail "unable to commit GC fixture round %d" round
    in
    Fun.protect
      ~finally:(fun () -> ignore (Session.close session))
      (fun () ->
         commit_round 1;
         commit_round 2;
         f path storage session))
;;

let storage_root storage =
  match storage.Datascript.storage_restore Datascript.Storage.root_address with
  | Some (Datascript.Storage_root root) -> root
  | Some _ -> T.fail "storage root address has the wrong payload"
  | None -> T.fail "storage root address is missing"
;;

let rec stored_index_datoms storage address =
  match storage.Datascript.storage_restore address with
  | Some (Datascript.Storage_node (Persistent_sorted_set.Leaf datoms)) -> datoms
  | Some (Storage_node (Branch (_, children))) ->
    List.concat_map (stored_index_datoms storage) children
  | Some _ -> T.fail "stored index address %s has the wrong payload" address
  | None -> T.fail "stored index address %s is missing" address
;;

let () =
  T.run
    "storage atomicity"
    [ T.case
        "detached immutable DataScript staging API compiles"
        compile_detached_staging_spike
    ; T.case
        "attached session defers unreachable address count"
        attached_session_defers_unreachable_address_count_until_gc_check
    ; T.case
        "restored session reuses DB without implicit persistence"
        restored_session_reuses_db_without_implicit_persistence
    ; T.case "open configures the required writable PRAGMAs" (fun () ->
        with_kvs_database (fun path ->
          match Storage.open_database path with
          | Error _ -> T.fail "valid kvs database did not open"
          | Ok connection ->
            let callbacks = Storage.connection_callbacks connection in
            (match Storage.verify_connection_pragmas connection with
             | Ok () -> ()
             | Error _ -> T.fail "open did not configure writable PRAGMAs");
            (match Storage.close callbacks with
             | Ok () -> ()
             | Error _ -> T.fail "opened database did not close")))
    ; T.case "reject kvs table without INTEGER PRIMARY KEY" (fun () ->
        with_database_schema
          "CREATE TABLE kvs (addr INTEGER, content TEXT, addresses JSON)"
          (fun path ->
             match Storage.open_database path with
             | Error (Pragma_mismatch _) -> ()
             | Error _ -> T.fail "wrong error for invalid kvs primary key"
             | Ok connection ->
               ignore (Storage.close (Storage.connection_callbacks connection));
               T.fail "kvs table without primary key was accepted"))
    ; T.case "reject negative physical storage address" (fun () ->
        with_kvs_database (fun path ->
          let db = Sqlite3.db_open path in
          exec db "INSERT INTO kvs(addr, content, addresses) VALUES(-1, '[]', NULL)";
          T.require (Sqlite3.db_close db) "unable to close negative-address fixture";
          match Storage.open_database path with
          | Error (Pragma_mismatch _) -> ()
          | Error _ -> T.fail "wrong error for negative storage address"
          | Ok connection ->
            ignore (Storage.close (Storage.connection_callbacks connection));
            T.fail "negative storage address was accepted"))
    ; T.case "physical SQLite storage restores the committed DataScript db" (fun () ->
        with_kvs_database (fun path ->
          let expected =
            Datascript.empty_db ()
            |> Datascript.db_with
                 [ Datascript.Add
                     ( Temp_id "physical"
                     , ":block/title"
                     , String "physical SQLite round trip" )
                 ]
          in
          match Storage.open_database path with
          | Error _ -> T.fail "valid kvs database did not open"
          | Ok connection ->
            let callbacks = Storage.connection_callbacks connection in
            (match Storage.commit_batch callbacks (storage_batch_of_db expected) with
             | Ok () -> ()
             | Error _ -> T.fail "physical storage batch did not commit");
            (match Datascript.restore (Storage.datascript_storage connection) with
             | None -> T.fail "committed database did not restore"
             | Some actual ->
               T.require
                 (Datascript.db_hash actual = Datascript.db_hash expected)
                 "restored database changed");
            (match Storage.close callbacks with
             | Ok () -> ()
             | Error _ -> T.fail "restored database did not close")))
    ; T.case "physical root includes Logseq index metadata" (fun () ->
        let batch =
          Datascript.empty_db ()
          |> Datascript.db_with
               [ Datascript.Add (Temp_id "metadata", "block/title", String "root metadata")
               ]
          |> storage_batch_of_db
        in
        List.iter
          (fun key ->
             T.require
               (contains_substring
                  (batch_write batch Datascript.Storage.root_address).payload
                  key)
               "physical root is missing %s"
               key)
          [ "eavt-metadata"; "aevt-metadata"; "avet-metadata"; "count"; "shift" ])
    ; T.case "storage session persists Logseq root metadata" (fun () ->
        with_kvs_database (fun path ->
          let connection =
            match Storage.open_database path with
            | Ok connection -> connection
            | Error _ -> T.fail "valid kvs database did not open"
          in
          let session =
            Session.create
              ~db:(Datascript.empty_db ())
              ~tail:[]
              ~callbacks:(Storage.connection_callbacks connection)
          in
          let staged =
            match
              Session.stage_transact
                session
                (List.init 40 (fun index ->
                   Datascript.Add
                     ( Temp_id ("session-metadata-" ^ string_of_int index)
                     , "block/title"
                     , String ("session metadata " ^ string_of_int index) )))
            with
            | Ok staged -> staged
            | Error _ -> T.fail "session did not stage"
          in
          (match Session.commit_staged session staged with
           | Ok () -> ()
           | Error _ -> T.fail "session did not commit");
          (match Session.close session with
           | Ok () -> ()
           | Error _ -> T.fail "session did not close");
          let db = Sqlite3.db_open ~mode:`NO_CREATE path in
          let root = ref None in
          Sqlite3.Rc.check
            (Sqlite3.exec db "SELECT content FROM kvs WHERE addr = 0" ~cb:(fun row _ ->
               root := row.(0)));
          T.require (Sqlite3.db_close db) "unable to close root inspection database";
          match !root with
          | Some content ->
            T.require
              (contains_substring content "eavt-metadata")
              "storage session dropped root metadata"
          | None -> T.fail "storage session did not persist root"))
    ; T.case "official EAVT leaf decodes the schema-version ident" (fun () ->
        with_oracle_kvs_database (fun path ->
          let connection =
            match Storage.open_database path with
            | Error _ -> T.fail "official Logseq storage did not open"
            | Ok connection -> connection
          in
          let storage = Storage.datascript_storage connection in
          let datoms =
            match storage.Datascript.storage_restore "1000005" with
            | Some (Datascript.Storage_node (Persistent_sorted_set.Leaf datoms)) -> datoms
            | Some _ -> T.fail "official EAVT address 1000005 is not a leaf"
            | None -> T.fail "official EAVT address 1000005 is missing"
          in
          let entity_seven =
            datoms
            |> List.filter (fun datom -> datom.Datascript.e = 7)
            |> List.map (fun datom ->
              let value =
                match datom.Datascript.v with
                | Datascript.Keyword value -> "keyword:" ^ value
                | Datascript.String value -> "string:" ^ value
                | Datascript.Map _ -> "map"
                | _ -> "other"
              in
              datom.Datascript.a ^ "=" ^ value)
            |> String.concat ","
          in
          T.require
            (List.exists
               (fun datom ->
                  datom.Datascript.e = 7
                  && String.equal datom.a "db/ident"
                  && Datascript.Util.value_equal
                       datom.v
                       (Datascript.Keyword "logseq.kv/schema-version"))
               datoms)
            "official EAVT leaf lost the schema-version ident during Transit decoding: %s"
            entity_seven;
          match Storage.close (Storage.connection_callbacks connection) with
          | Ok () -> ()
          | Error _ -> T.fail "official Logseq storage did not close"))
    ; T.case "restore official Logseq 65.33 physical storage" (fun () ->
        with_oracle_kvs_database (fun path ->
          let connection =
            match Storage.open_database path with
            | Error _ -> T.fail "official Logseq storage did not open"
            | Ok connection -> connection
          in
          let storage = Storage.datascript_storage connection in
          (match Storage.validate_storage_header connection with
           | Ok () -> ()
           | Error (Corrupt_storage message | Pragma_mismatch message) ->
             T.fail "official reachable storage was rejected: %s" message
           | Error _ -> T.fail "official reachable storage was rejected");
          let db =
            match Storage.restore_database connection with
            | Ok db -> db
            | Error _ -> T.fail "official Logseq storage did not restore"
          in
          let find_title db title =
            Datascript.datoms
              db
              Datascript.Eavt
              ~a:"block/title"
              ~v:(Datascript.String title)
              ()
            |> Seq.uncons
            |> Option.is_some
          in
          T.require (find_title db "Oracle Page") "official page is missing after restore";
          let schema_version =
            Datascript.q_return_string
              db
              "[:find ?value . :where [?entity :db/ident :logseq.kv/schema-version] \
               [?entity :kv/value ?value]]"
          in
          T.require
            (match schema_version with
             | Datascript.Query_scalar (Some (Result_value (Map _))) -> true
             | _ -> false)
            "complete restore lost the schema-version KV";
          let session =
            Session.create
              ~db
              ~tail:(Datascript.Storage.restore_tail_groups storage)
              ~callbacks:(Storage.connection_callbacks connection)
          in
          let staged =
            match
              Session.stage_transact
                session
                [ Datascript.Add
                    (Temp_id "official-tail", "block/title", String "OCaml Tail Mutation")
                ]
            with
            | Ok staged -> staged
            | Error (Session.Stage_failed message) ->
              T.fail "official graph mutation did not stage: %s" message
            | Error _ -> T.fail "official graph mutation did not stage"
          in
          (match Session.commit_staged session staged with
           | Ok () -> ()
           | Error _ -> T.fail "official graph mutation did not commit");
          (match Session.close session with
           | Ok () -> ()
           | Error _ -> T.fail "official graph session did not close");
          let reopened =
            match Storage.open_database path with
            | Error _ -> T.fail "mutated official storage did not reopen"
            | Ok connection -> connection
          in
          (match Storage.restore_database reopened with
           | Ok db ->
             T.require
               (find_title db "OCaml Tail Mutation")
               "tail mutation is missing after reopen"
           | Error _ -> T.fail "mutated official storage did not restore");
          match Storage.close (Storage.connection_callbacks reopened) with
          | Ok () -> ()
          | Error _ -> T.fail "reopened official storage did not close"))
    ; T.case "full compaction preserves Logseq keyword order in EAVT" (fun () ->
        with_oracle_kvs_database (fun path ->
          let connection =
            match Storage.open_database path with
            | Error _ -> T.fail "official Logseq storage did not open"
            | Ok connection -> connection
          in
          let storage = Storage.datascript_storage connection in
          let db =
            match Storage.restore_database connection with
            | Ok db -> db
            | Error _ -> T.fail "official Logseq storage did not restore"
          in
          let page =
            match
              Datascript.find_datom
                db
                Datascript.Eavt
                ~a:"block/title"
                ~v:(Datascript.String "Oracle Page")
                ()
            with
            | Some datom -> datom.Datascript.e
            | None -> T.fail "official page is missing"
          in
          let filler =
            List.init 40 (fun index ->
              Datascript.Add
                ( Temp_id ("keyword-order-" ^ string_of_int index)
                , "block/title"
                , String ("keyword order " ^ string_of_int index) ))
          in
          let session =
            Session.create
              ~db
              ~tail:(Datascript.Storage.restore_tail_groups storage)
              ~callbacks:(Storage.connection_callbacks connection)
          in
          let staged =
            match
              Session.stage_transact
                session
                (Datascript.Add
                   (Entity_id page, "logseq.property/deleted-at", Int 1_704_067_200_000)
                 :: Add (Entity_id page, "logseq.property.recycle/original-page", Ref page)
                 :: filler)
            with
            | Ok staged -> staged
            | Error (Session.Stage_failed message) ->
              T.fail "keyword-order transaction did not stage: %s" message
            | Error _ -> T.fail "keyword-order transaction did not stage"
          in
          (match Session.commit_staged session staged with
           | Ok () -> ()
           | Error _ -> T.fail "keyword-order transaction did not commit");
          (match Session.close session with
           | Ok () -> ()
           | Error _ -> T.fail "keyword-order session did not close");
          let reopened =
            match Storage.open_database path with
            | Error _ -> T.fail "compacted Logseq storage did not reopen"
            | Ok connection -> connection
          in
          let reopened_storage = Storage.datascript_storage reopened in
          let root = storage_root reopened_storage in
          let page_attrs =
            stored_index_datoms reopened_storage root.Datascript.storage_eavt
            |> List.filter_map (fun datom ->
              if
                datom.Datascript.e = page
                && List.mem
                     datom.a
                     [ "logseq.property/deleted-at"
                     ; "logseq.property.recycle/original-page"
                     ]
              then Some datom.a
              else None)
          in
          T.require
            (page_attrs
             = [ "logseq.property/deleted-at"; "logseq.property.recycle/original-page" ])
            "compacted EAVT uses non-Logseq attribute order: %s"
            (String.concat "," page_attrs);
          match Storage.close (Storage.connection_callbacks reopened) with
          | Ok () -> ()
          | Error _ -> T.fail "compacted Logseq storage did not close"))
    ; T.case "lightweight validation accepts uncounted descendant metadata" (fun () ->
        with_oracle_kvs_database (fun path ->
          let db = Sqlite3.db_open path in
          let root = ref None in
          Sqlite3.Rc.check
            (Sqlite3.exec db "SELECT content FROM kvs WHERE addr = 0" ~cb:(fun row _ ->
               root := row.(0)));
          let content =
            match !root with
            | Some content ->
              replace_first
                content
                ~needle:"\"~:count\",2384"
                ~replacement:"\"~:count\",2383"
            | None -> T.fail "oracle fixture has no root"
          in
          let statement =
            Sqlite3.prepare db "UPDATE kvs SET content = ? WHERE addr = 0"
          in
          Sqlite3.Rc.check (Sqlite3.bind_text statement 1 content);
          Sqlite3.Rc.check (Sqlite3.step statement);
          ignore (Sqlite3.finalize statement);
          T.require (Sqlite3.db_close db) "unable to close corrupt root fixture";
          let connection =
            match Storage.open_database path with
            | Ok connection -> connection
            | Error _ -> T.fail "metadata fixture did not reach validation"
          in
          (match Storage.validate_storage_header connection with
           | Ok () -> ()
           | Error _ -> T.fail "lightweight validation traversed descendant counts");
          (match Storage.restore_database connection with
           | Ok _ -> ()
           | Error _ -> T.fail "restore repeated the removed descendant validation");
          ignore (Storage.close (Storage.connection_callbacks connection))))
    ; T.case "verify writable pragmas" (fun () ->
        with_sqlite (fun db ->
          exec db "PRAGMA journal_mode=WAL";
          exec db "PRAGMA synchronous=FULL";
          exec db "PRAGMA busy_timeout=5000";
          exec db "PRAGMA locking_mode=NORMAL";
          match Storage.verify_writable_pragmas db with
          | Ok () -> ()
          | Error _ -> T.fail "valid writable PRAGMAs rejected"))
    ; T.case "PRAGMA mismatch is rejected" (fun () ->
        with_sqlite (fun db ->
          exec db "PRAGMA journal_mode=DELETE";
          match Storage.verify_writable_pragmas db with
          | Error (Pragma_mismatch _) -> ()
          | _ -> T.fail "invalid PRAGMAs accepted"))
    ; T.case "prepared address UPSERT failure rolls back" (fun () ->
        let state = state () in
        state.fail_address <- Some "10";
        (match Storage.commit_batch (callbacks state) sample_batch with
         | Error (Write_failed { address = "10"; _ }) -> ()
         | _ -> T.fail "write failure not returned");
        T.require (List.mem "rollback" state.events) "rollback not called";
        T.require
          (not (List.mem "commit" state.events))
          "commit called after write failure")
    ; T.case "root write failure rolls back" (fun () ->
        let state = state () in
        state.fail_address <- Some "0";
        (match Storage.commit_batch (callbacks state) sample_batch with
         | Error (Write_failed { address = "0"; _ }) -> ()
         | _ -> T.fail "root write failure not returned");
        T.require (List.mem "rollback" state.events) "rollback not called")
    ; T.case "tail write failure rolls back" (fun () ->
        let state = state () in
        state.fail_address <- Some "1";
        (match Storage.commit_batch (callbacks state) sample_batch with
         | Error (Write_failed { address = "1"; _ }) -> ()
         | _ -> T.fail "tail write failure not returned");
        T.require (List.mem "rollback" state.events) "rollback not called")
    ; T.case "commit failure rolls back" (fun () ->
        let state = state () in
        state.fail_commit <- true;
        (match Storage.commit_batch (callbacks state) sample_batch with
         | Error (Commit_failed _) -> ()
         | _ -> T.fail "commit failure not returned");
        T.require (List.mem "rollback" state.events) "rollback not called")
    ; T.case "stage does not install db_after early" (fun () ->
        let state = state () in
        let session, staged = staged_session state in
        T.require
          (Datascript.db_hash (Session.current_db session)
           <> Datascript.db_hash (Session.staged_db_after staged))
          "staged db installed early")
    ; T.case "successful commit installs db once" (fun () ->
        let state = state () in
        let session, staged = staged_session state in
        let staged_hash = Datascript.db_hash (Session.staged_db_after staged) in
        (match Session.commit_staged session staged with
         | Ok () -> ()
         | Error _ -> T.fail "commit failed");
        T.require
          (Datascript.db_hash (Session.current_db session) = staged_hash)
          "db not installed";
        match Session.commit_staged session staged with
        | Error Session.Already_consumed -> ()
        | _ -> T.fail "staged value was reusable")
    ; T.case "mutation persistence failure terminalizes session" (fun () ->
        let state = state () in
        state.fail_commit <- true;
        let session, staged = staged_session state in
        (match Session.commit_staged session staged with
         | Error (Session.Persistence_failed _) -> ()
         | _ -> T.fail "persistence failure not returned");
        T.require (Session.is_fatal session) "session did not terminalize";
        match Session.stage_transact session [] with
        | Error (Session.Fatal _) -> ()
        | _ -> T.fail "fatal session accepted a later request")
    ; T.case "reachability GC deletes only unreachable physical addresses" (fun () ->
        with_gc_session (fun _path storage session ->
          let db_hash = Datascript.db_hash (Session.current_db session) in
          let before = storage_address_count storage in
          T.require (before > 2) "GC fixture contains no physical index nodes";
          (match Session.collect_garbage session with
           | Ok () -> ()
           | Error _ -> T.fail "reachability GC did not run");
          let after = storage_address_count storage in
          T.require (after < before) "reachability GC removed no unreachable addresses";
          T.require
            (Option.is_some (storage.storage_restore Datascript.Storage.root_address))
            "reachability GC removed the root";
          T.require
            (Option.is_some (storage.storage_restore Datascript.Storage.tail_address))
            "reachability GC removed the tail";
          T.require
            (Datascript.db_hash (Session.current_db session) = db_hash)
            "reachability GC changed semantic graph state";
          (match Session.collect_garbage session with
           | Ok () -> ()
           | Error _ -> T.fail "no-op reachability GC failed");
          T.require
            (storage_address_count storage = after)
            "no-op reachability GC changed storage"))
    ; T.case "reachability GC delete failure terminalizes and rolls back" (fun () ->
        with_gc_session (fun path storage session ->
          let before = storage_address_count storage in
          let db = Sqlite3.db_open ~mode:`NO_CREATE path in
          Sqlite3.Rc.check
            (Sqlite3.exec
               db
               "CREATE TRIGGER fail_gc_delete BEFORE DELETE ON kvs BEGIN SELECT \
                RAISE(ABORT, 'injected GC delete failure'); END");
          T.require (Sqlite3.db_close db) "unable to close GC failure injector";
          (match Session.collect_garbage session with
           | Error (Session.Persistence_failed _) -> ()
           | _ -> T.fail "GC delete failure was not fatal");
          T.require (Session.is_fatal session) "GC delete failure did not terminalize";
          T.require
            (storage_address_count storage = before)
            "failed GC exposed a partial deletion"))
    ; T.case "reachability GC commit failure terminalizes and rolls back" (fun () ->
        let fail_commit = ref false in
        let transform (callbacks : Storage.callbacks) =
          { callbacks with
            commit =
              (fun () ->
                if !fail_commit
                then Error "injected GC commit failure"
                else callbacks.commit ())
          }
        in
        with_gc_session ~callbacks_transform:transform (fun _path storage session ->
          let before = storage_address_count storage in
          fail_commit := true;
          (match Session.collect_garbage session with
           | Error (Session.Persistence_failed _) -> ()
           | _ -> T.fail "GC commit failure was not fatal");
          T.require (Session.is_fatal session) "GC commit failure did not terminalize";
          T.require
            (storage_address_count storage = before)
            "failed GC commit exposed a partial deletion"))
    ; T.case "checkpoint failure has shutdown diagnostic" (fun () ->
        let state = state () in
        state.fail_checkpoint <- true;
        match
          Session.close
            (Session.create
               ~db:(Datascript.empty_db ())
               ~tail:[]
               ~callbacks:(callbacks state))
        with
        | Error (Session.Persistence_failed message) ->
          T.require (String.length message > 0) "empty diagnostic"
        | _ -> T.fail "checkpoint failure hidden")
    ; T.case "close failure has shutdown diagnostic" (fun () ->
        let state = state () in
        state.fail_close <- true;
        match
          Session.close
            (Session.create
               ~db:(Datascript.empty_db ())
               ~tail:[]
               ~callbacks:(callbacks state))
        with
        | Error (Session.Persistence_failed message) ->
          T.require (String.length message > 0) "empty diagnostic"
        | _ -> T.fail "close failure hidden")
    ]
;;
