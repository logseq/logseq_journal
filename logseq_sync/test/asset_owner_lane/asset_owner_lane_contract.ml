module A = Logseq_db_types.Asset_descriptor
module S = Logseq_sync_assets.Selection

let get = Result.get_ok
let ( let* ) = Result.bind

let uuid =
  get (Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111")
;;

let version checksum =
  get (A.version ~checksum:(String.make 64 checksum) ~file_type:"png")
;;

let descriptor source current_checksum =
  get (A.create ~uuid ~source ~current_checksum ~size:None ~dimensions:None)
;;

let checksums versions = List.map (fun (v : A.version) -> v.checksum) versions

let lookup_order () =
  let remote = version 'b' in
  let asset = descriptor (A.Managed (Some remote)) (Some (version 'a').checksum) in
  Alcotest.(check (list string))
    "original before remote"
    [ (version 'a').checksum; remote.checksum ]
    (checksums (S.lookup_versions asset));
  Alcotest.(check (list string))
    "deduplicated"
    [ remote.checksum ]
    (checksums
       (S.lookup_versions (descriptor (A.Managed (Some remote)) (Some remote.checksum))))
;;

let no_remote () =
  let asset = descriptor (A.Managed None) (Some (version 'a').checksum) in
  Alcotest.(check bool)
    "missing type cannot invent local version"
    true
    (S.lookup_versions asset = []);
  Alcotest.(check bool) "never GET original" true (S.download_version asset = None);
  let external_asset = descriptor (A.External "https://example.invalid/a.png") None in
  Alcotest.(check bool)
    "external_asset is not managed"
    true
    (S.download_version external_asset = None && S.lookup_versions external_asset = [])
;;

module D = Sync_dsl.Core
module Owner = Logseq_sync_assets.Core

let ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.error_message error)
;;

let identity =
  ok
    (D.identity
       ~origin:"https://example.com"
       ~account:"owner"
       ~graph:"11111111-1111-4111-8111-111111111111"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let limits =
  ok
    (D.limits
       ~maximum_items:8
       ~maximum_bytes:1024
       ~maximum_pending:8
       ~maximum_resources:1
       ~steps_per_turn:8
       ~maximum_tasks:8
       ~maximum_messages:8
       ~maximum_message_bytes:1024
       ~maximum_demands:8
       ~maximum_active_assets:2
       ~foreground_reserve:1
       ~foreground_demand_reserve:1
       ~foreground_descriptor_reserve_bytes:128
       ~asset_cache_budget_bytes:4096L
       ~asset_maximum_file_bytes:1024
       ~asset_pending_budget_bytes:4096L
       ~snapshot_maximum_artifact_bytes:4096L
       ~snapshot_staging_budget_bytes:4096L
       ~snapshot_scratch_budget_bytes:4096L)
;;

let current () = Ok ()
let original _ = Ok None
let upload _ = Error (D.Invalid_input "No import")

let run owner operation =
  Owner.run
    owner
    ~check_current:current
    ~admit_network:current
    ~original
    ~upload
    ~identity
    operation
;;

let rejected = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Expected rejection"
;;

let with_assets_env get callback =
  Eio_main.run (fun env ->
    let root = Filename.temp_file "asset-owner-contract" "" in
    Sys.remove root;
    Unix.mkdir root 0o700;
    let crypto =
      Logseq_sync_crypto.Core.create
        ~identity
        ~limits
        ~encrypted:false
        ~backend:Logseq_sync_crypto.Core.apple_backend
    in
    let network : Owner.network =
      { get; put = (fun ~identity:_ ~asset:_ ~version:_ ~wire:_ -> Ok ()) }
    in
    let owner =
      ok
        (Owner.create
           ~root
           ~identity
           ~limits
           ~crypto
           ~key:(fun ~check_current ->
             let open Result in
             bind (check_current ()) (fun () -> Ok None))
           ~network)
    in
    let rec remove path =
      if Sys.is_directory path
      then (
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Sys.remove path
    in
    Fun.protect
      ~finally:(fun () ->
        ignore (Owner.close owner);
        remove root)
      (fun () -> callback owner env root))
;;

let with_assets get callback = with_assets_env get (fun owner _ _ -> callback owner)
let wire = "owner bytes"

let wire_version =
  get
    (A.version
       ~checksum:(Logseq_sync_native_crypto.Asset_codec.checksum wire)
       ~file_type:"png")
;;

let remote_asset = descriptor (A.Managed (Some wire_version)) (Some wire_version.checksum)

let available = function
  | D.Available file -> file
  | _ -> Alcotest.fail "Expected file"
;;

let ownership () =
  with_assets
    (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ -> Ok (Some wire))
    (fun owner ->
       let file = available (ok (run owner (D.Download remote_asset))) in
       let forged_asset = descriptor (A.Managed None) None in
       let forged = ok (D.asset_file file.file forged_asset) in
       rejected (Owner.file_path owner forged);
       rejected (Owner.release_file owner ~identity forged);
       ignore (ok (Owner.file_path owner file));
       ok (Owner.release_file owner ~identity file);
       ok (Owner.release_file owner ~identity file);
       rejected (Owner.file_path owner file))
;;

let reserve_before_io () =
  let requests = ref 0 in
  let owner_ref = ref None in
  with_assets
    (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ ->
       incr requests;
       if !requests = 1
       then rejected (run (Option.get !owner_ref) (D.Download remote_asset));
       Ok (Some wire))
    (fun owner ->
       owner_ref := Some owner;
       let file = available (ok (run owner (D.Download remote_asset))) in
       Alcotest.(check int) "second request never started" 1 !requests;
       ok (Owner.release_file owner ~identity file))
;;

let failed_transfer_releases_budget () =
  let requests = ref 0 in
  with_assets
    (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ ->
       incr requests;
       if !requests = 1 then Error D.Cancelled else Ok (Some wire))
    (fun owner ->
       rejected (run owner (D.Download remote_asset));
       let file = available (ok (run owner (D.Download remote_asset))) in
       ok (Owner.release_file owner ~identity file);
       let file = available (ok (run owner (D.Download remote_asset))) in
       ok (Owner.release_file owner ~identity file))
;;

module Intent = Logseq_db_types.Asset_upload_intent
module Store = Logseq_db_storage.Asset_upload_store

let sql_ok = function
  | Ok value -> value
  | Error message -> Alcotest.fail message
;;

let id ordinal =
  get
    (Logseq_db_types.Graph_types.Uuid.of_string
       (Printf.sprintf "22222222-2222-4222-8222-%012d" ordinal))
;;

let checkpoint ordinal =
  sql_ok
    (Intent.prepare
       ~operation_id:(id ordinal)
       ~origin:identity.origin
       ~account:identity.account
       ~graph:uuid
       ~asset:uuid
       ~version:wire_version
       ~title:"Import"
       ~size:(Int64.of_int (String.length wire))
       ~staged_file:"original.png"
       ~replace_reference:None
       ~target:(id 100)
       ~local_mutation:(id (ordinal + 200))
       ~metadata_mutation:(id (ordinal + 400)))
;;

let original_lookup () =
  let db = Sqlite3.db_open ":memory:" in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
       sql_ok (Store.initialize_database db);
       let first = checkpoint 1 in
       sql_ok (Store.save db ~expected:None first);
       let cancelled = sql_ok (Intent.advance first Cancelled) in
       sql_ok (Store.save db ~expected:(Some 0) cancelled);
       let second = checkpoint 2 in
       sql_ok (Store.save db ~expected:None second);
       Alcotest.(check bool)
         "skips cancelled exact original"
         true
         (sql_ok
            (Store.find_original
               db
               ~origin:identity.origin
               ~account:identity.account
               ~graph:uuid
               ~asset:uuid
               ~checksum:wire_version.checksum)
          = Some second);
       Alcotest.(check bool)
         "foreign owner has no original"
         true
         (sql_ok
            (Store.find_original
               db
               ~origin:identity.origin
               ~account:"foreign"
               ~graph:uuid
               ~asset:uuid
               ~checksum:wire_version.checksum)
          = None))
;;

let original_index_upgrade () =
  let db = Sqlite3.db_open ":memory:" in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
       sql_ok (Store.initialize_database db);
       sql_ok (Store.save db ~expected:None (checkpoint 1));
       Sqlite3.Rc.check
         (Sqlite3.exec
            db
            "DROP INDEX IF EXISTS asset_upload_original; CREATE INDEX \
             asset_upload_original ON \
             asset_upload_intents(origin,account,graph,json_extract(payload,'$.asset'),json_extract(payload,'$.version.checksum'),operation) \
             WHERE json_extract(payload,'$.phase[0]') <> 'Cancelled'");
       sql_ok (Store.initialize_database db);
       Sqlite3.Rc.check
         (Sqlite3.exec db "UPDATE asset_upload_intents SET payload='invalid checkpoint'");
       rejected (Store.read db ~operation:(id 1));
       sql_ok (Store.save db ~expected:None (checkpoint 2));
       Alcotest.(check bool)
         "guarded index preserves bounded exact lookup"
         true
         (sql_ok
            (Store.find_original
               db
               ~origin:identity.origin
               ~account:identity.account
               ~graph:uuid
               ~asset:uuid
               ~checksum:wire_version.checksum)
          = Some (checkpoint 2)))
;;

module Worker = Logseq_sync_worker_owner.Core
module X = Execute.Core

let seed_database root =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Checkpoint = Logseq_db_types.Sync_checkpoint in
  let module Graph = Logseq_db_types.Graph_types in
  let attribute : Datascript.schema_attr =
    { cardinality = One
    ; unique = None
    ; indexed = true
    ; is_component = false
    ; no_history = false
    ; doc = None
    ; value_type = None
    ; tuple_attrs = None
    ; tuple_types = None
    }
  in
  let schema =
    List.map
      (fun name ->
         ( name
         , if name = "block/uuid" || name = "db/ident"
           then { attribute with unique = Some Identity }
           else if name = "block/parent" || name = "block/page"
           then { attribute with value_type = Some RefType }
           else if name = "block/tags"
           then { attribute with cardinality = Many; value_type = Some RefType }
           else attribute ))
      [ "db/ident"
      ; "block/uuid"
      ; "block/title"
      ; "block/name"
      ; "block/journal-day"
      ; "block/link"
      ; "block/refs"
      ; "block/parent"
      ; "block/page"
      ; "block/order"
      ; "block/tags"
      ; "kv/value"
      ; "logseq.property.asset/type"
      ; "logseq.property.asset/checksum"
      ; "logseq.property.asset/size"
      ]
  in
  let fact e a v : Datascript.datom = { e; a; v; tx = 536870913; added = true } in
  let kv e name value = [ fact e "db/ident" (Keyword name); fact e "kv/value" value ] in
  let facts =
    List.concat
      [ kv 1 "logseq.kv/graph-remote?" (Bool true)
      ; kv 2 "logseq.kv/graph-uuid" (Uuid (Graph.Uuid.to_string uuid))
      ; kv 3 "logseq.kv/db-type" (String "db")
      ; kv
          4
          "logseq.kv/schema-version"
          (Map [ Keyword "major", Int64 65L; Keyword "minor", Int64 33L ])
      ; [ fact 5 "block/uuid" (Uuid (Graph.Uuid.to_string (id 100)))
        ; fact 5 "block/name" (String "Imports")
        ; fact 5 "block/title" (String "Imports")
        ]
      ; [ fact 6 "db/ident" (Keyword "logseq.class/Asset") ]
      ]
  in
  let rec mkdir directory =
    if not (Sys.file_exists directory)
    then (
      mkdir (Filename.dirname directory);
      Unix.mkdir directory 0o700)
  in
  let directory =
    Filename.concat root ("logseq-db-worker/synced-graphs/" ^ Graph.Uuid.to_string uuid)
  in
  mkdir directory;
  let path = Filename.concat directory "db.sqlite" in
  let sqlite = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Sqlite3.Rc.check
         (Sqlite3.exec
            sqlite
            "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)");
       sql_ok
         (Logseq_db_storage.Sync_checkpoint_store.initialize_database
            sqlite
            (sql_ok
               (Checkpoint.create
                  ~graph_id:uuid
                  ~schema:Graph.{ major = 65; minor = 33 }
                  ~applied_server_t:(get (Logseq_db_types.Server_cursor.of_int64 0L))
                  ~checksum:"0000000000000000")));
       sql_ok (Logseq_db_storage.Sync_outbox_store.initialize_database sqlite));
  let connection = get (Storage.open_database path) in
  let callbacks = Storage.connection_callbacks connection in
  Fun.protect
    ~finally:(fun () -> ignore (Storage.close callbacks))
    (fun () ->
       sql_ok (callbacks.begin_staging ());
       let stored =
         Datascript.store ~storage:callbacks.storage (Datascript.init_db ~schema facts)
       in
       ignore stored;
       let batch = sql_ok (callbacks.finish_staging None []) in
       get (Storage.commit_batch callbacks batch))
;;

let with_worker
      ?(live_database = false)
      ?(notify = fun ~owner:_ ~identity:_ -> Ok ())
      ?(on_store = fun _ -> ())
      ?(wire_batch_max_bytes = 1024)
      callback
  =
  with_assets_env
    (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ -> Ok None)
    (fun assets env root ->
       Eio.Switch.run (fun sw ->
         let module O = D.Overlay in
         let deps =
           get
             (O.Database.dependencies
                ~epoch_ms:(fun () -> 0L)
                ~monotonic_ns:(fun () -> 0L)
                ~limits:
                  { O.Types.response_budget_bytes = 1024
                  ; outbox_max_records = 8
                  ; outbox_max_bytes = max 4096 wire_batch_max_bytes
                  ; change_max_items = 8
                  ; change_max_bytes = 1024
                  ; dispatcher_capacity = 8
                  ; wire_batch_max_bytes
                  })
         in
         if live_database then seed_database root;
         let inspection =
           get
             (O.Database.inspect_mirror
                ~application_support_directory:root
                ~graph_id:uuid)
         in
         let database_owner =
           if live_database
           then
             X.database_owner
               (get (O.Database.open_ ~sw deps inspection ~graph_name:"Owner fixture"))
           else
             ok
               (X.activation_owner
                  ~sw
                  ~dependencies:deps
                  ~inspection
                  ~graph_name:"Owner fixture"
                  ~snapshot_source:(fun _ -> Error (D.Invalid_input "No snapshot")))
         in
         let db = Sqlite3.db_open ":memory:" in
         Fun.protect
           ~finally:(fun () -> ignore (Sqlite3.db_close db))
           (fun () ->
              sql_ok (Store.initialize_database db);
              on_store db;
              let worker =
                Worker.create
                  ~clock:(Eio.Stdenv.mono_clock env)
                  ~namespace:(String.make 64 'a')
                  ~assets
                  ~store:(Worker.store db)
                  ~notify_outbox_changed:notify
              in
              let module W = (val Worker.worker_owner worker : X.WORKER_OWNER) in
              ok
                (W.bind_runtime
                   ~identity
                   ~database_owner
                   ~limits
                   ~cleanup_seconds:0.01
                   ~network:{ with_admission = (fun callback -> callback ()) });
              callback worker (module W : X.WORKER_OWNER) database_owner root)))
;;

let import_request_guard () =
  List.iter (fun retire_after ->
  with_worker (fun _ packed _ root ->
    let module W = (val packed : X.WORKER_OWNER) in
    let source_file = Filename.concat root "guard.png" in
    let channel = open_out_bin source_file in
    output_string channel wire;
    close_out channel;
    let request : Logseq_db_types.Asset_import.t =
      { operation = id 2; asset = uuid; replace_reference = None; target = id 100
      ; local_mutation = id 202; metadata_mutation = id 402; source_file
      ; title = "Guarded"; file_type = "png" }
    in
    ok (W.with_scope ~identity ~operation:request.operation (fun scope ->
      let checks = ref 0 in
      let current () = incr checks; !checks < retire_after in
      rejected (W.prepare_import scope request ~current);
      let input = get (Logseq_db_types.Asset_import.Pure_intent.create
        ~namespace:(String.make 64 'a') request)
        |> Logseq_db_types.Asset_import.Pure_intent.encode in
      Alcotest.(check bool) "stale input never becomes Prepared" true
        (match ok (W.confirm_import_input scope input) with
         | None -> true | Some item -> item.prepared = None);
      Ok ())))) [1; 2; 3; 4; 5; 6; 7; 8]
;;

let staging_reconciliation_serializes_preparation () =
  with_worker (fun worker packed _ root ->
    let module W = (val packed : X.WORKER_OWNER) in
    Eio.Switch.run (fun sw ->
      let source_file = Filename.concat root "serialized.png" in
      let channel = open_out_bin source_file in
      output_string channel wire;
      close_out channel;
      let request : Logseq_db_types.Asset_import.t =
        { operation = id 3; asset = uuid; replace_reference = None; target = id 100
        ; local_mutation = id 203; metadata_mutation = id 403; source_file
        ; title = "Serialized"; file_type = "png" } in
      let finished, resolve = Eio.Promise.create () in
      let started = ref false in
      let current () =
        if not !started then (
          started := true;
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve resolve
              (Worker.run_assets worker ~identity ~operation:(id 903) D.Reconcile_staging)));
        for _ = 1 to 4 do Eio.Fiber.yield () done;
        Alcotest.(check bool) "reconciliation waits throughout stage and durable Prepared" false
          (Eio.Promise.is_resolved finished);
        true in
      let intent = ok (W.with_scope ~identity ~operation:request.operation (fun scope ->
        W.prepare_import scope request ~current)) in
      Alcotest.(check int) "serialized reconciliation keeps the committed source" 0
        (ok (Eio.Promise.await finished));
      Sys.remove source_file;
      ok (W.with_scope ~identity ~operation:request.operation (fun scope ->
        let file = ok (W.retain_imported_file scope intent) |> Option.get in
        Alcotest.(check bool) "original source remains readable without picker" true
          (Sys.file_exists (W.imported_file_path file));
        W.release_imported_file file));
      let other = ok (D.identity ~origin:identity.origin ~account:"other" ~graph:identity.graph
        ~account_generation:0L ~graph_generation:0L) in
      rejected (Worker.run_assets worker ~identity:other ~operation:(id 904) D.Reconcile_staging);
      ok (Worker.fence worker ~identity);
      rejected (Worker.run_assets worker ~identity ~operation:(id 905) D.Reconcile_staging);
      ok (Worker.await_quiescent worker ~identity)))
;;

let import_ownership () =
  with_worker (fun worker packed database_owner root ->
    let module W = (val packed : X.WORKER_OWNER) in
    let source_file = Filename.concat root "picker.png" in
    let channel = open_out_bin source_file in
    output_string channel wire;
    close_out channel;
    let request : Logseq_db_types.Asset_import.t =
      { operation = id 1
      ; asset = uuid
      ; replace_reference = None
      ; target = id 100
      ; local_mutation = id 201
      ; metadata_mutation = id 401
      ; source_file
      ; title = "Import"
      ; file_type = "png"
      }
    in
    let held = ref None in
    let cancelled =
      ok
        (W.with_scope ~identity ~operation:request.operation (fun scope ->
           let intent = ok (W.prepare_import scope request ~current:(fun () -> true)) in
           let input =
             get
               (Logseq_db_types.Asset_import.Pure_intent.create
                  ~namespace:(String.make 64 'a')
                  request)
             |> Logseq_db_types.Asset_import.Pure_intent.encode
           in
           let confirmed = Option.get (ok (W.confirm_import_input scope input)) in
           Alcotest.(check bool)
             "recovery retains exact original input"
             true
             (confirmed.input = input && confirmed.prepared <> None);
           rejected
             (W.recover_import_inputs
                scope
                ~after:None
                ~maximum_items:9
                ~maximum_bytes:1024);
           ok
             (W.acknowledge_import_input
                scope
                ~input
                ~prepared:(Option.get confirmed.prepared));
           Alcotest.(check bool)
             "exact recovery acknowledgement is durable"
             true
             (Option.get (ok (W.confirm_import_input scope input))).acknowledged;
           Sys.remove source_file;
           Alcotest.(check bool)
             "retry uses original staging without picker"
             true
             (ok (W.prepare_import scope request ~current:(fun () -> true)) = intent);
           rejected (W.prepare_import scope { request with title = "Changed" } ~current:(fun () -> true));
           rejected (W.publish_import_preview scope (checkpoint 1));
           rejected (W.release_import_staging scope intent);
           held := ok (W.retain_imported_file scope intent);
           Alcotest.(check bool)
             "lease pins existing path"
             true
             (Sys.file_exists (W.imported_file_path (Option.get !held)));
           ok (W.cancel_import scope intent);
           let cancelled = sql_ok (Intent.advance intent Cancelled) in
           ok (W.release_import_staging scope cancelled);
           Alcotest.(check bool)
             "terminal retirement preserves held preview"
             true
             (Sys.file_exists (W.imported_file_path (Option.get !held)));
           Ok cancelled))
    in
    ok (Worker.database_changed worker ~owner:database_owner ~identity);
    rejected
      (Worker.database_changed
         worker
         ~owner:database_owner
         ~identity:
           (ok
              (D.identity
                 ~origin:identity.origin
                 ~account:"other"
                 ~graph:identity.graph
                 ~account_generation:0L
                 ~graph_generation:0L)));
    let file = Option.get !held in
    ok (W.release_imported_file file);
    ok (W.release_imported_file file);
    Alcotest.(check bool)
      "last consumer release removes terminal source"
      false
      (Sys.file_exists (W.imported_file_path file));
    ok
      (W.with_scope ~identity ~operation:request.operation (fun scope ->
         W.release_import_staging scope cancelled));
    ok (Worker.fence worker ~identity);
    rejected (W.with_scope ~identity ~operation:(id 2) (fun _ -> Ok ()));
    ok (Worker.await_quiescent worker ~identity))
;;

let committed_import_hooks () =
  let notifications = ref 0 in
  let notified_owner = ref None in
  let fail_notification = ref true in
  let notify ~owner ~identity:requested =
    incr notifications;
    notified_owner := Some owner;
    Alcotest.(check bool) "exact notification identity" true (requested = identity);
    if !fail_notification
    then Error (D.Storage_failure "Synthetic postcommit notification failure")
    else Ok ()
  in
  let upload_store = ref None in
  with_worker
    ~live_database:true
    ~notify
    ~wire_batch_max_bytes:65536
    ~on_store:(fun db -> upload_store := Some db)
    (fun worker packed database_owner root ->
       let module W = (val packed : X.WORKER_OWNER) in
       let held = ref None in
       let source_file = Filename.concat root "picker.png" in
       let channel = open_out_bin source_file in
       output_string channel wire;
       close_out channel;
       let request : Logseq_db_types.Asset_import.t =
         { operation = id 1
         ; asset = uuid
         ; replace_reference = None
         ; target = id 100
         ; local_mutation = id 201
         ; metadata_mutation = id 401
         ; source_file
         ; title = "Import"
         ; file_type = "png"
         }
       in
       ok
         (W.with_scope ~identity ~operation:request.operation (fun scope ->
            let intent = ok (W.prepare_import scope request ~current:(fun () -> true)) in
            ok (W.publish_import_preview scope intent);
            rejected (W.apply_local_import scope intent);
            Alcotest.(check bool)
              "notification failure preserves local commit"
              true
              (ok (W.inspect_import scope intent) = `Local_present);
            fail_notification := false;
            ok (W.apply_local_import scope intent);
            ok (W.put_import scope intent);
            ok (W.apply_import_metadata scope intent);
            Alcotest.(check bool)
              "PUT and metadata are not publication ACK"
              true
              (ok (W.inspect_import scope intent) = `Metadata_present);
            ok (W.apply_import_metadata scope intent);
            let database = ok (X.database database_owner) in
            let sync = get (D.Overlay.Database.inspect_sync database) in
            Alcotest.(check int)
              "exact original mutations, no replay"
              2
              (List.length (D.Overlay.Types.sync_view_submissions sync));
            Alcotest.(check bool)
              "exact notification binding"
              true
              (Option.get !notified_owner == database_owner);
            Alcotest.(check int)
              "every successful or recovered commit notifies"
              4
              !notifications;
            Sys.remove source_file;
            Alcotest.(check int) "owner reconciliation retains Metadata_pending source" 0
              (ok (Worker.run_assets worker ~identity ~operation:(id 902) D.Reconcile_staging));
            held := ok (W.retain_imported_file scope intent);
            Ok ()));
       let module O = D.Overlay in
       let module T = O.Types in
       let database = ok (X.database database_owner) in
       let read_intent () =
         Option.get
           (sql_ok (Store.read (Option.get !upload_store) ~operation:request.operation))
       in
       let file = Option.get !held in
       let path = W.imported_file_path file in
       let sqlite_proof ~pending =
         let graph = Logseq_db_types.Graph_types.Uuid.to_string uuid in
         let path =
           Filename.concat root ("logseq-db-worker/synced-graphs/" ^ graph ^ "/db.sqlite")
         in
         let sqlite = Sqlite3.db_open ~mode:`READONLY path in
         Fun.protect
           ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
           (fun () ->
              let count query =
                let result = ref (-1) in
                Sqlite3.Rc.check
                  (Sqlite3.exec sqlite query ~cb:(fun row _ ->
                     result := int_of_string (Option.get row.(0))));
                !result
              in
              Alcotest.(check int)
                "SQLite exact metadata terminal Applied receipt before/after ACK"
                (if pending then 0 else 1)
                (count
                   (Printf.sprintf
                      "SELECT count(*) FROM overlay_mutation_receipts WHERE \
                       json_extract(receipt,'$[1].mutation_id')='%s' AND \
                       json_extract(receipt,'$[1].status[0]')='Applied'"
                      (Logseq_db_types.Graph_types.Uuid.to_string
                         request.metadata_mutation)));
              Alcotest.(check int)
                "SQLite original outbox before/after authoritative echo"
                (if pending then 2 else 0)
                (count "SELECT count(*) FROM sync_outbox"))
       in
       Eio.Switch.run (fun sw ->
         let finished, resolver = Eio.Promise.create () in
         Eio.Fiber.fork ~sw (fun () ->
           Eio.Promise.resolve
             resolver
             (Worker.run_assets
                worker
                ~identity
                ~operation:(id 900)
                (D.Upload
                   (descriptor
                      (A.Managed (Some wire_version))
                      (Some wire_version.checksum)))));
         for _ = 1 to 16 do
           Eio.Fiber.yield ()
         done;
         if Eio.Promise.is_resolved finished then ignore (ok (Eio.Promise.await finished));
         Alcotest.(check bool)
           "upload waits for actual metadata ACK"
           true
           ((read_intent ()).phase = Intent.Metadata_pending
            && not (Eio.Promise.is_resolved finished));
         let logical_notifications = ref 0 in
         let subscription, snapshot = get (O.Database.listen database) in
         O.Database.release_snapshot snapshot;
         get
           (O.Database.activate_subscription subscription ~notify:(fun _ ->
              incr logical_notifications));
         Fun.protect
           ~finally:(fun () -> O.Database.unlisten subscription)
           (fun () ->
              let transition action =
                let view = get (O.Database.inspect_sync database) in
                let prepared, protection =
                  match
                    O.Database.begin_outbox_transition
                      database
                      ~expected:(T.sync_view_token view)
                      action
                  with
                  | Ok prepared -> prepared
                  | Error (T.Outbox_transition_invalid message) -> Alcotest.fail message
                  | Error T.Outbox_limit_exceeded ->
                    Alcotest.fail "submission exceeds fixture wire budget"
                  | Error (T.Outbox_dependency_ineligible _) ->
                    Alcotest.fail "submission dependency ineligible"
                  | Error _ -> Alcotest.fail "submission preparation rejected"
                in
                let encrypted =
                  Option.map
                    (fun request -> request, O.Database.protection_plaintexts request)
                    protection
                in
                get (O.Database.apply_outbox_transition database prepared ~encrypted)
              in
              let submitted =
                Option.get
                  (transition
                     (T.Submit_group [ request.local_mutation; request.metadata_mutation ]))
                    .submission_batch
              in
              let wires = T.submission_batch_wires submitted in
              Alcotest.(check bool)
                "submission contains exact metadata mutation"
                true
                (List.exists
                   (fun wire ->
                      T.submission_wire_mutation_id wire = request.metadata_mutation)
                   wires);
              let through =
                get (T.Server_cursor.of_int64 (Int64.of_int (List.length wires)))
              in
              ignore
                (transition
                   (T.Accept_group
                      { batch_id = T.submission_batch_id submitted
                      ; barrier =
                          { through
                          ; checksum =
                              get (T.Checksum.of_string "checksum:v1:0000000000000000")
                          }
                      }));
              Alcotest.(check bool)
                "transport acceptance alone retains metadata outbox"
                true
                (List.exists
                   (fun (item : T.submission_descriptor) ->
                      item.mutation_id = request.metadata_mutation)
                   (T.sync_view_submissions (get (O.Database.inspect_sync database))));
              let normalize transaction =
                let module Transit = Transit_core.Json in
                let module Codec = Transit_native.Transit.Json in
                let entity = function
                  | Transit.String value
                    when String.starts_with ~prefix:"overlay-insert:" value
                         || String.starts_with ~prefix:"overlay-page:" value ->
                    let start = String.index value ':' + 1 in
                    Transit.String (String.sub value start (String.length value - start))
                  | value -> value
                in
                let datom = function
                  | Transit.Array
                      [ (Transit.Keyword ("db/add" | "db/retract") as operation)
                      ; target
                      ; (Transit.Keyword attribute as encoded_attribute)
                      ; value
                      ] ->
                    let value =
                      if attribute = "block/parent" || attribute = "block/page"
                      then entity value
                      else value
                    in
                    Transit.Array
                      [ operation
                      ; entity target
                      ; encoded_attribute
                      ; value
                      ; Transit.Int 1
                      ]
                  | operation -> operation
                in
                match Codec.of_string transaction with
                | Transit.Array operations ->
                  Codec.to_string
                    ~mode:Codec.Verbose
                    (Transit.Array (List.map datom operations))
                | _ -> Alcotest.fail "submission is not a transaction"
              in
              let transactions =
                List.mapi
                  (fun ordinal wire ->
                     let cursor =
                       get (T.Server_cursor.of_int64 (Int64.of_int (ordinal + 1)))
                     in
                     let normalized =
                       normalize (T.submission_wire_protected_transaction wire)
                     in
                     let transaction =
                       get
                         (T.encoded_transaction_of_string ~maximum_bytes:65536 normalized)
                     in
                     T.authoritative_transaction ~cursor ~transaction)
                  wires
              in
              let batch =
                get
                  (T.authoritative_batch
                     ~maximum_count:8
                     ~maximum_bytes:65536
                     ~transactions
                     ~through
                     ~checksum:None)
              in
              sqlite_proof ~pending:true;
              Alcotest.(check bool)
                "original remains pinned through ACK"
                true
                (Sys.file_exists path);
              let before = get (O.Database.inspect_sync database) in
              let prepared, protection =
                get
                  (O.Database.begin_authoritative
                     database
                     ~expected:(T.sync_view_token before)
                     batch)
              in
              let decrypted =
                Option.map
                  (fun request ->
                     ( request
                     , List.map
                         (fun (item, encoded) ->
                            match Transit_native.Transit.Json.of_string encoded with
                            | Transit_core.Json.String plaintext -> item, plaintext
                            | _ ->
                              Alcotest.fail "synthetic protection did not encode a string")
                         (O.Database.unprotection_ciphertexts request) ))
                  protection
              in
              let commit =
                match O.Database.apply_authoritative database prepared ~decrypted with
                | Ok (O.Database.Authoritative_applied commit) -> commit
                | Ok (Authoritative_deferred _) -> Alcotest.fail "own echo deferred"
                | Error
                    ( T.Authoritative_decode_failed message
                    | Authoritative_integrity_failure message
                    | Authoritative_commit_persistence_failed message ) ->
                  Alcotest.fail message
                | Error _ -> Alcotest.fail "authoritative own echo rejected"
              in
              Alcotest.(check bool)
                "authoritative own echo has no logical change"
                true
                (commit.logical_change_summary = T.No_logical_change);
              Alcotest.(check bool)
                "exact metadata Applied receipt"
                true
                (List.exists
                   (fun (receipt : T.terminal_receipt) ->
                      match receipt.receipt with
                      | T.Applied_receipt { mutation_id; _ } ->
                        mutation_id = request.metadata_mutation
                      | _ -> false)
                   commit.terminal_receipts);
              Alcotest.(check int)
                "actual own echo clears outbox"
                0
                (List.length
                   (T.sync_view_submissions (get (O.Database.inspect_sync database))));
              sqlite_proof ~pending:false;
              for _ = 1 to 16 do
                Eio.Fiber.yield ()
              done;
              Alcotest.(check int)
                "ACK never notifies logical subscribers"
                0
                !logical_notifications;
              Alcotest.(check bool)
                "ACK wakes public upload fiber"
                true
                (Eio.Promise.is_resolved finished);
              ignore (ok (Eio.Promise.await finished));
              let complete = read_intent () in
              Alcotest.(check bool)
                "upload persists Complete to SQLite"
                true
                (complete.phase = Intent.Complete);
              Alcotest.(check bool)
                "Complete retirement preserves pinned original"
                true
                (Sys.file_exists path);
              ok (W.release_imported_file file);
              Alcotest.(check bool)
                "final pin release unlinks original"
                false
                (Sys.file_exists path);
              ok (W.release_imported_file file);
              ok
                (W.with_scope ~identity ~operation:request.operation (fun scope ->
                   W.release_import_staging scope complete));
              ignore
                (ok
                   (Worker.run_assets
                      worker
                      ~identity
                      ~operation:(id 901)
                      (D.Upload
                         (descriptor
                            (A.Managed (Some wire_version))
                            (Some wire_version.checksum)))));
              Alcotest.(check bool)
                "public Complete replay tolerates already absent original"
                true
                (read_intent () = complete && not (Sys.file_exists path))));
       ok (Worker.fence worker ~identity);
       ok (Worker.await_quiescent worker ~identity))
;;

let shared_crypto_key () =
  Eio_main.run (fun _ ->
    let key = String.make 32 'k' in
    let backend : Logseq_sync_crypto.Core.backend =
      { crypto = Logseq_sync_native_crypto.Platform_crypto.crypto
      ; unlock = (fun ~identity:_ ~wrapped_graph_key:_ -> Ok key)
      }
    in
    let crypto =
      Logseq_sync_crypto.Core.create ~identity ~limits ~encrypted:true ~backend
    in
    let read_key () = Owner.native_key ~identity ~crypto ~check_current:current in
    rejected (read_key ());
    ignore
      (ok
         (Logseq_sync_crypto.Core.run
            crypto
            ~check_current:current
            ~identity
            (D.Unlock (ok (D.unlock_input ~wrapped_graph_key:"synthetic-wrapped")))));
    Alcotest.(check (option string))
      "assets use the installed worker key"
      (Some key)
      (ok (read_key ()));
    Logseq_sync_crypto.Core.retire crypto;
    rejected (read_key ()))
;;

let scope_cancel () =
  with_worker (fun worker packed _ _ ->
    let module W = (val packed : X.WORKER_OWNER) in
    rejected
      (W.with_scope ~identity ~operation:(id 1) (fun scope ->
         rejected (W.with_scope ~identity ~operation:(id 1) (fun _ -> Ok ()));
         let* () = W.cancel scope in
         W.crypto scope (D.Decrypt_value "secret")));
    ok (W.with_scope ~identity ~operation:(id 1) (fun _ -> Ok ()));
    ok (Worker.fence worker ~identity);
    ok (Worker.await_quiescent worker ~identity))
;;

let absent_native_coordinator ~owned ~available () =
  with_assets_env
    (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ -> Ok None)
    (fun _ env root ->
      Eio.Switch.run (fun sw ->
        let module C = Journal_sync_lifecycle.Core in
        if available then seed_database root;
        let deps = get (D.Overlay.Database.dependencies
          ~epoch_ms:(fun () -> 0L) ~monotonic_ns:(fun () -> 0L)
          ~limits:{ D.Overlay.Types.response_budget_bytes = 1024
            ; outbox_max_records = 8; outbox_max_bytes = 4096
            ; change_max_items = 8; change_max_bytes = 1024
            ; dispatcher_capacity = 8; wire_batch_max_bytes = 1024 }) in
        let inspection = get (D.Overlay.Database.inspect_mirror
          ~application_support_directory:root ~graph_id:uuid) in
        let database_owner = ok (X.activation_owner ~sw ~dependencies:deps
          ~inspection ~graph_name:"Absent native fixture"
          ~snapshot_source:(fun _ -> Error (D.Invalid_input "No offline snapshot"))) in
        let sqlite = Sqlite3.db_open ":memory:" in
        Fun.protect ~finally:(fun () ->
          Alcotest.(check bool) "borrowed upload store closes" true (Sqlite3.db_close sqlite))
          (fun () ->
            sql_ok (Store.initialize_database sqlite);
            let retry = ok (D.retry_policy ~initial_seconds:0.01 ~maximum_seconds:0.01
              ~multiplier:1. ~maximum_attempts:0) in
            let config : Logseq_sync_sync_service.Core.config =
              { identity; limits; network = D.Closed
              ; policy = ok (D.policy_config ~sync_retry:retry ~asset_retry:retry
                  ~no_progress_seconds:0.01) } in
            let changes = ref [] and errors = ref [] and tokens = ref 0 in
            let start = if owned then
                C.start_owned_native ~dependencies:deps ~graph_name:"Owned native fixture"
              else C.start_native ~database_owner in
            let service = ok (start ~sw ~clock:(Eio.Stdenv.mono_clock env)
              ~network:(Eio.Stdenv.net env)
              ~authenticator:(X509.Authenticator.chain_of_trust
                ~time:(fun () -> Some (Ptime_clock.now ())) [])
              ~config ~deadlines:{ X.setup_seconds = 0.1; tls_handshake_seconds = 0.1
                ; http_response_seconds = 0.1; download_seconds = 0.1 }
              ~liveness:X.Peer_close_only ~cleanup_seconds:1. ~root
              ~upload_store:(Worker.store sqlite) ~namespace:(String.make 64 'a') ~encrypted:false
              ~token:(fun ~epoch:_ ~refresh:_ -> incr tokens;
                Error (D.Authentication_failure "Offline fixture"))
              ~on_change:(fun status -> changes := status :: !changes)
              ~on_error:(fun error -> errors := error :: !errors)) in
            for _ = 1 to 16 do Eio.Fiber.yield () done;
            ignore (ok (C.ingress service));
            Alcotest.(check bool) "mirror checkpoint matches presence" true
              (List.exists (fun (status : Logseq_sync_sync_service.Core.status) ->
                Option.is_some status.observation.state.checkpoint = available) !changes);
            C.close service;
            if owned && available then (
              let inspection = get (D.Overlay.Database.inspect_mirror
                ~application_support_directory:root ~graph_id:uuid) in
              let reopened = get (D.Overlay.Database.open_ ~sw deps inspection
                ~graph_name:"Reopened owned fixture") in
              get (D.Overlay.Database.close reopened));
            Alcotest.(check int) "offline absent mirror never authenticates" 0 !tokens;
            Alcotest.(check int) "no subscription error for absent mirror" 0 (List.length !errors))))
;;

let native_coordinator () =
  with_assets_env
    (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ -> Ok None)
    (fun _ env root ->
       Eio.Switch.run (fun sw ->
         seed_database root;
         let deps = get (D.Overlay.Database.dependencies
           ~epoch_ms:(fun () -> 0L) ~monotonic_ns:(fun () -> 0L)
           ~limits:{ D.Overlay.Types.response_budget_bytes = 1024
             ; outbox_max_records = 8; outbox_max_bytes = 4096
             ; change_max_items = 8; change_max_bytes = 1024
             ; dispatcher_capacity = 8; wire_batch_max_bytes = 1024 }) in
         let inspection = get (D.Overlay.Database.inspect_mirror
           ~application_support_directory:root ~graph_id:uuid) in
         let database = get (D.Overlay.Database.open_ ~sw deps inspection
           ~graph_name:"Native coordinator fixture") in
         let database_owner = X.database_owner database in
         let sqlite = Sqlite3.db_open ":memory:" in
         Fun.protect ~finally:(fun () ->
           Alcotest.(check bool) "borrowed upload store closes" true (Sqlite3.db_close sqlite))
           (fun () ->
             sql_ok (Store.initialize_database sqlite);
             let module C = Journal_sync_lifecycle.Core in
             let retry = ok (D.retry_policy ~initial_seconds:0.01 ~maximum_seconds:0.01
               ~multiplier:1. ~maximum_attempts:0) in
             let config : Logseq_sync_sync_service.Core.config =
               { identity; limits; network = D.Closed
               ; policy = ok (D.policy_config ~sync_retry:retry ~asset_retry:retry
                   ~no_progress_seconds:0.01) } in
             let calls = ref 0 and changes = ref 0 and errors = ref [] in
             let start namespace = C.start_native ~sw ~clock:(Eio.Stdenv.mono_clock env)
               ~network:(Eio.Stdenv.net env)
               ~authenticator:(X509.Authenticator.chain_of_trust
                 ~time:(fun () -> Some (Ptime_clock.now ())) [])
               ~config ~deadlines:{ X.setup_seconds = 0.1; tls_handshake_seconds = 0.1
                 ; http_response_seconds = 0.1; download_seconds = 0.1 }
               ~liveness:X.Peer_close_only ~cleanup_seconds:1. ~root ~database_owner
               ~upload_store:(Worker.store sqlite) ~namespace ~encrypted:false
               ~token:(fun ~epoch:_ ~refresh:_ -> incr calls;
                 Error (D.Authentication_failure "Closed fixture must not request a token"))
               ~on_change:(fun _ -> incr changes) ~on_error:(fun error -> errors := error :: !errors)
             in
             rejected (start "");
             let coordinator = ok (start (String.make 64 'a')) in
             (match start (String.make 64 'a') with
              | Error (D.Identity_mismatch _) -> ()
              | Error error -> Alcotest.fail (D.error_message error)
              | Ok _ -> Alcotest.fail "A second service borrowed the same database owner");
             for _ = 1 to 16 do Eio.Fiber.yield () done;
             ignore (ok (C.ingress coordinator));
             Alcotest.(check bool) "status delivered after start" true (!changes > 0);
             let worker = C.worker_owner coordinator in
             let module W = (val Worker.worker_owner worker : X.WORKER_OWNER) in
             let source_file = Filename.concat root "native-picker.png" in
             let channel = open_out_bin source_file in
             output_string channel wire;
             close_out channel;
             let request : Logseq_db_types.Asset_import.t =
               { operation = id 1; asset = uuid; replace_reference = None; target = id 100
               ; local_mutation = id 201; metadata_mutation = id 401; source_file
               ; title = "Native import"; file_type = "png" } in
             ok (W.with_scope ~identity ~operation:request.operation (fun scope ->
               let intent = ok (W.prepare_import scope request ~current:(fun () -> true)) in
               ok (W.publish_import_preview scope intent);
               ok (W.apply_local_import scope intent);
               (match W.put_import scope intent with
                | Error D.Network_closed -> ()
                | Error error -> Alcotest.fail (D.error_message error)
                | Ok () -> Alcotest.fail "Closed native owner admitted PUT");
               ok (W.cancel_import scope intent);
               let cancelled = sql_ok (Intent.advance intent Cancelled) in
               W.release_import_staging scope cancelled));
             ok (C.projection_changed coordinator);
             (try C.close coordinator with
              | Logseq_sync_sync_service.Core.Close_failed {error; cause} ->
                let rec describe = function
                  | D.Cleanup_failure {primary; failures} ->
                    String.concat "; " (Option.to_list (Option.map describe primary)
                      @ List.map describe (List.of_seq (Rrbvec.to_seq failures)))
                  | error -> D.error_message error in
                let message = Option.fold ~none:"No typed close error" ~some:describe error in
                let cause = Option.fold ~none:"" ~some:(fun (exn, _) -> Printexc.to_string exn) cause in
                Alcotest.fail (message ^ " " ^ cause));
             rejected (C.projection_changed coordinator);
             Alcotest.(check int) "offline native service never authenticates" 0 !calls;
             Alcotest.(check int) "postcommit notifications succeed" 0 (List.length !errors);
             let sync = get (D.Overlay.Database.inspect_sync database) in
             Alcotest.(check int) "borrowed database survives sync close" 1
               (List.length (D.Overlay.Types.sync_view_submissions sync));
             Alcotest.check_raises "close right is consumed"
               Logseq_sync_sync_service.Core.Close_already_called
               (fun () -> C.close coordinator))))
;;

let () =
  Alcotest.run
    "asset owner lane"
    [ ( "worker"
      , [ Alcotest.test_case "absent mirror starts offline" `Quick
            (absent_native_coordinator ~owned:false ~available:false)
        ; Alcotest.test_case "App owns absent mirror" `Quick
            (absent_native_coordinator ~owned:true ~available:false)
        ; Alcotest.test_case "App closes available mirror after Sync" `Quick
            (absent_native_coordinator ~owned:true ~available:true)
        ; Alcotest.test_case "native coordinator owns real offline imports" `Quick native_coordinator
        ; Alcotest.test_case "request guard fences Prepared" `Quick import_request_guard
        ; Alcotest.test_case "staging reconciliation serializes preparation" `Quick staging_reconciliation_serializes_preparation
        ; Alcotest.test_case "assets share worker crypto key" `Quick shared_crypto_key
        ; Alcotest.test_case
            "real commits and postcommit hooks"
            `Quick
            committed_import_hooks
        ; Alcotest.test_case
            "original proof cancellation and lease release"
            `Quick
            import_ownership
        ; Alcotest.test_case "scope cancellation physically joins" `Quick scope_cancel
        ] )
    ; ( "imports"
      , [ Alcotest.test_case
            "legacy index upgrade preserves checkpoint validation"
            `Quick
            original_index_upgrade
        ; Alcotest.test_case "bounded exact original lookup" `Quick original_lookup
        ] )
    ; ( "ownership"
      , [ Alcotest.test_case "exact file metadata" `Quick ownership
        ; Alcotest.test_case "reserve before I/O" `Quick reserve_before_io
        ; Alcotest.test_case
            "cancelled transfer returns budget"
            `Quick
            failed_transfer_releases_budget
        ] )
    ; ( "selection"
      , [ Alcotest.test_case "offline current first" `Quick lookup_order
        ; Alcotest.test_case "no implicit transfer" `Quick no_remote
        ] )
    ]
;;
