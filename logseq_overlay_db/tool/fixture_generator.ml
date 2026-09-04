module Graph = Logseq_db_types.Graph_types
module Types = Logseq_overlay_db.Types

let uuid text =
  match Graph.Uuid.of_string text with
  | Ok uuid -> uuid
  | Error message -> invalid_arg message
;;

let block_uuid ordinal = uuid (Printf.sprintf "20000000-0000-4000-8000-%012d" ordinal)
let mutation_uuid ordinal = uuid (Printf.sprintf "90000000-0000-4000-8000-%012d" ordinal)

let schema_attr ?unique ?(indexed = false) ?value_type () =
  Datascript.
    { cardinality = One
    ; unique
    ; indexed
    ; is_component = false
    ; no_history = false
    ; doc = None
    ; value_type
    ; tuple_attrs = None
    ; tuple_types = None
    }
;;

let schema =
  [ ( "db/ident"
    , schema_attr ~unique:Datascript.Identity ~value_type:Datascript.KeywordType () )
  ; "kv/value", schema_attr ()
  ; ( "block/uuid"
    , schema_attr
        ~unique:Datascript.Identity
        ~indexed:true
        ~value_type:Datascript.UuidType
        () )
  ; "block/title", schema_attr ~value_type:Datascript.StringType ()
  ; "block/order", schema_attr ~value_type:Datascript.StringType ()
  ; "block/parent", schema_attr ~indexed:true ~value_type:Datascript.RefType ()
  ; "block/page", schema_attr ~indexed:true ~value_type:Datascript.RefType ()
  ; "block/name", schema_attr ~value_type:Datascript.StringType ()
  ]
;;

let authoritative_db ~block_count =
  if block_count < 0 then invalid_arg "block_count must be non-negative";
  let page = Datascript.Temp_id "page" in
  let overflow_page = Datascript.Temp_id "overflow-page" in
  let page_uuid = uuid "10000000-0000-4000-8000-000000000001" in
  let page_ops =
    [ Datascript.Add (page, "block/uuid", Uuid (Graph.Uuid.to_string page_uuid))
    ; Add (page, "block/name", String "performance fixture")
    ; Add (page, "block/title", String "Performance fixture")
    ; Add (overflow_page, "block/uuid", Uuid "10000000-0000-4000-8000-000000000002")
    ; Add (overflow_page, "block/name", String "performance overflow fixture")
    ; Add (overflow_page, "block/title", String "Performance overflow fixture")
    ]
  in
  let kv id ident value =
    let entity = Datascript.Temp_id id in
    [ Datascript.Add (entity, "db/ident", Keyword ident)
    ; Add (entity, "kv/value", value)
    ]
  in
  let identity_ops =
    kv
      "schema-version"
      "logseq.kv/schema-version"
      (Map [ Keyword "major", Int 65; Keyword "minor", Int 33 ])
    @ kv "db-type" "logseq.kv/db-type" (String "db")
    @ kv
        "local-graph-uuid"
        "logseq.kv/local-graph-uuid"
        (Uuid "70000000-0000-4000-8000-000000000001")
    @ kv "graph-remote" "logseq.kv/graph-remote?" (Bool true)
    @ kv "graph-uuid" "logseq.kv/graph-uuid" (Uuid "60000000-0000-4000-8000-000000000001")
  in
  let block_ops =
    List.init block_count (fun index ->
      let entity = Datascript.Temp_id (Printf.sprintf "block-%d" index) in
      let block = block_uuid index in
      let parent = if index < 256 then page else overflow_page in
      [ Datascript.Add (entity, "block/uuid", Uuid (Graph.Uuid.to_string block))
      ; Add (entity, "block/title", String (Printf.sprintf "Block %d" index))
      ; Add (entity, "block/order", String (Printf.sprintf "a%08d" index))
      ; Add (entity, "block/parent", Ref_to parent)
      ; Add (entity, "block/page", Ref_to parent)
      ])
    |> List.concat
  in
  Datascript.empty_db ~schema ()
  |> Datascript.db_with (identity_ops @ page_ops @ block_ops)
;;

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
  in
  let open Yojson.Safe.Util in
  let sqlite = Sqlite3.db_open database_path in
  Sqlite3.Rc.check (Sqlite3.exec sqlite (fixture |> member "tableSql" |> to_string));
  let statement =
    Sqlite3.prepare sqlite "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
  in
  fixture
  |> member "rows"
  |> to_list
  |> List.iter (fun row ->
    Sqlite3.Rc.check (Sqlite3.reset statement);
    Sqlite3.Rc.check (Sqlite3.bind_int statement 1 (row |> member "addr" |> to_int));
    Sqlite3.Rc.check
      (Sqlite3.bind_text statement 2 (row |> member "content" |> to_string));
    Sqlite3.Rc.check
      (Sqlite3.bind
         statement
         3
         (match row |> member "addresses" with
          | `Null -> Sqlite3.Data.NULL
          | `String value -> TEXT value
          | _ -> failwith "malformed storage fixture"));
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
      ; Add (entity, "block/journal-day", Int (2_026_01_01 + index))
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
      ~applied_server_t:0
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

let seed_outbox ~database_path ~block_count ~count =
  if count < 0 || count > 4_096 then invalid_arg "invalid performance outbox size";
  let records =
    List.init count (fun ordinal ->
      let mutation_id = mutation_uuid ordinal in
      let block = block_uuid (ordinal mod block_count) in
      let title = Printf.sprintf "Pending title %d" ordinal in
      let plaintext =
        Printf.sprintf
          "save:%s:%s:%S"
          (Graph.Uuid.to_string mutation_id)
          (Graph.Uuid.to_string block)
          title
      in
      let fingerprint =
        Digestif.SHA256.digest_string plaintext |> Digestif.SHA256.to_hex
      in
      let dependency_shadows = `Assoc [ "blocks", `List []; "pages", `List [] ] in
      let module Transit = Transit_core.Json in
      let module Codec = Transit_native.Transit.Json in
      let entity =
        Transit.Array
          [ Transit.Keyword "block/uuid"; Transit.Uuid (Graph.Uuid.to_string block) ]
      in
      let normalized_transaction =
        Codec.to_string
          ~mode:Codec.Verbose
          (Transit.Array
             [ Transit.Array
                 [ Keyword "db/add"; entity; Keyword "block/title"; String title ]
             ; Transit.Array
                 [ Keyword "db/add"
                 ; entity
                 ; Keyword "block/updated-at"
                 ; Int (ordinal + 1)
                 ]
             ; Transit.Array
                 [ Keyword "db/add"; entity; Keyword "block/tx-id"; Int (ordinal + 1) ]
             ; Transit.Array
                 [ Keyword "db/add"
                 ; Keyword "db/current-tx"
                 ; Keyword "db-sync/tx-id"
                 ; Uuid (Graph.Uuid.to_string mutation_id)
                 ]
             ; Transit.Array
                 [ Keyword "db/add"
                 ; Keyword "db/current-tx"
                 ; Keyword "outliner-op"
                 ; Keyword "save-block"
                 ]
             ; Transit.Array
                 [ Keyword "db/add"
                 ; Keyword "db/current-tx"
                 ; Keyword "logseq-overlay/mutation-digest"
                 ; String fingerprint
                 ]
             ])
      in
      `Assoc
        [ "acceptanceBarrier", `Null
        ; "attemptCount", `Int 0
        ; "blockedPriorState", `Null
        ; "blockedReason", `Null
        ; "fingerprint", `String fingerprint
        ; "formatVersion", `Int 14
        ; "intentTimeMs", `String (Int64.to_string (Int64.of_int (ordinal + 1)))
        ; "plannedTx", `Int (ordinal + 1)
        ; "sequence", `Int (ordinal + 1)
        ; "dependencyShadows", dependency_shadows
        ; ( "effectFootprint"
          , `Assoc
              [ "blocks", `List [ `String (Graph.Uuid.to_string block) ]
              ; "pages", `List []
              ; "structures", `List []
              ] )
        ; "deleteArtifacts", `Null
        ; ( "mutation"
          , `Assoc
              [ "block", `String (Graph.Uuid.to_string block)
              ; "mutationId", `String (Graph.Uuid.to_string mutation_id)
              ; "title", `String title
              ; "type", `String "saveBlock"
              ] )
        ; "normalizedTransaction", `String normalized_transaction
        ; "protectedTransaction", `Null
        ; "state", `Assoc [ "type", `String "queued" ]
        ; "sameIdRetryEligible", `Bool false
        ; "submissionTBefore", `Null
        ; "submissionOrdinal", `Null
        ; "submissionCount", `Null
        ; "observedOriginCursor", `Null
        ; "staleEarliestConflictCursor", `Null
        ; "staleConflicts", `List []
        ; "syncRevision", `Int count
        ]
      |> Yojson.Safe.to_string)
  in
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Logseq_db_storage.Sync_outbox_store.replace_database sqlite records
       |> Result.get_ok)
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

let mutation_history ~count =
  if count < 0 then invalid_arg "count must be non-negative";
  let parent = uuid "10000000-0000-4000-8000-000000000001" in
  List.init count (fun index ->
    Types.Insert_blocks
      { mutation_id = mutation_uuid index
      ; parent
      ; tree = { uuid = block_uuid (100_000 + index); title = "Pending"; children = [] }
      })
;;

let fixture_checksum ~block_count =
  Digestif.SHA256.digest_string
    (Printf.sprintf "logseq-overlay-db-performance-v1:%d" block_count)
  |> Digestif.SHA256.to_hex
;;
