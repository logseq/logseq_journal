module Database = Logseq_overlay_db.Database
module T = Test_support
module Types = Logseq_overlay_db.Types
open Types

let location_and_inspection support behavior =
  let dependencies = T.dependencies ~behavior in
  let inspection =
    Database.inspect_mirror ~application_support_directory:support ~graph_id:T.graph_uuid
    |> T.require_ok ~behavior
  in
  dependencies, support, inspection
;;

let inspect_mirror support behavior =
  Database.inspect_mirror ~application_support_directory:support ~graph_id:T.graph_uuid
  |> T.require_ok ~behavior
;;

let block_precondition database block behavior =
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let revision =
         match Database.get_blocks snapshot [ block ] |> T.require_ok ~behavior with
         | [ Present_block { revision; _ } ] | [ Missing_block { revision; _ } ] ->
           revision
         | _ -> Alcotest.fail "block precondition returned the wrong cardinality"
       in
       Database.write_precondition ~blocks:[ block, revision ] ~pages:[] ~scopes:[]
       |> T.require_ok ~behavior)
;;

let page_precondition database page behavior =
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let revision =
         match Database.get_pages snapshot [ page ] |> T.require_ok ~behavior with
         | [ Present_page { revision; _ } ] | [ Missing_page { revision; _ } ] -> revision
         | _ -> Alcotest.fail "page precondition returned the wrong cardinality"
       in
       Database.write_precondition ~blocks:[] ~pages:[ page, revision ] ~scopes:[]
       |> T.require_ok ~behavior)
;;

let server_cursor value =
  Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" value)
  |> T.require_ok ~behavior:"construct server cursor"
;;

let checksum value =
  Checksum.of_string ("checksum:v1:" ^ value)
  |> T.require_ok ~behavior:"construct checksum"
;;

let snapshot_fixture root =
  let source = Filename.concat root "source" in
  Unix.mkdir source 0o700;
  let database_path = T.seed_mirror source in
  T.mark_snapshot_e2ee database_path;
  let snapshot_path = Filename.concat root "snapshot.transit" in
  let expected_rows = T.write_snapshot_from_database ~database_path ~snapshot_path in
  snapshot_path, expected_rows
;;

let snapshot_input_for root =
  let snapshot_path, expected_rows = snapshot_fixture root in
  snapshot_path, server_cursor 0, None, expected_rows
;;

let absent_inspection ~behavior support =
  let dependencies, location, inspection = location_and_inspection support behavior in
  (match Database.mirror_presence inspection with
   | Absent _ -> ()
   | Available _ -> Alcotest.fail "fresh activation target already has a mirror");
  dependencies, location, inspection
;;

let dependency_construction_validates_every_limit () =
  let behavior = "dependency construction validates every capability limit" in
  let valid = T.limits ~behavior in
  let construct limits =
    Database.dependencies
      ~epoch_ms:(fun () -> 1_704_067_200_000L)
      ~monotonic_ns:(fun () -> 1_000_000L)
      ~limits
  in
  let invalid =
    [ "response_budget_bytes", { valid with response_budget_bytes = 0 }
    ; "outbox_max_records", { valid with outbox_max_records = 0 }
    ; "outbox_max_bytes", { valid with outbox_max_bytes = 0 }
    ; "change_max_items", { valid with change_max_items = 0 }
    ; "change_max_bytes", { valid with change_max_bytes = 0 }
    ; "dispatcher_capacity", { valid with dispatcher_capacity = 0 }
    ; "wire_batch_max_bytes", { valid with wire_batch_max_bytes = 0 }
    ]
  in
  List.iter
    (fun (name, limits) ->
       match construct limits with
       | Error (Non_positive_limit actual) when String.equal name actual -> ()
       | Error _ -> Alcotest.failf "%s returned the wrong limit error" name
       | Ok _ -> Alcotest.failf "%s accepted a non-positive limit" name)
    invalid;
  match construct { valid with outbox_max_bytes = 16; wire_batch_max_bytes = 17 } with
  | Error (Inconsistent_limits _) -> ()
  | Error _ -> Alcotest.fail "inconsistent bounds returned the wrong limit error"
  | Ok _ -> Alcotest.fail "wire batch larger than the outbox budget was accepted"
;;

let rec supply_snapshot_crypto ~behavior prepared batch_count =
  match Database.next_snapshot_unprotection_batch prepared |> T.require_ok ~behavior with
  | None -> batch_count
  | Some request ->
    let ciphertexts = Database.unprotection_ciphertexts request in
    T.require (ciphertexts <> []) "snapshot emitted an empty crypto batch";
    let plaintexts = List.map (fun (id, value) -> id, value) ciphertexts in
    Database.supply_snapshot_unprotection_batch prepared ~request ~plaintexts
    |> T.require_ok ~behavior;
    supply_snapshot_crypto ~behavior prepared (batch_count + 1)
;;

let prepare_snapshot ?wire_batch_max_bytes ~behavior root support =
  let path, applied_server_cursor, expected_checksum, expected_rows =
    snapshot_input_for root
  in
  let dependencies, location, inspection = absent_inspection ~behavior support in
  let dependencies =
    match wire_batch_max_bytes with
    | None -> dependencies
    | Some wire_batch_max_bytes ->
      let limits = { (T.limits ~behavior) with wire_batch_max_bytes } in
      Database.dependencies
        ~epoch_ms:(fun () -> 1_704_067_200_000L)
        ~monotonic_ns:(fun () -> 1_000_000L)
        ~limits
      |> T.require_ok ~behavior
  in
  let prepared =
    Database.prepare_snapshot_activation
      dependencies
      inspection
      ~path
      ~applied_server_cursor
      ~expected_checksum
      ~expected_rows
    |> T.require_ok ~behavior
  in
  dependencies, location, prepared
;;

let snapshot_input_validation_is_fail_closed () =
  let behavior = "snapshot input validation is fail closed" in
  let cursor = server_cursor 0 in
  T.with_temp_directory "overlay-invalid-input-" (fun root ->
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let dependencies, _location, inspection = absent_inspection ~behavior support in
    let prepare ~path ~expected_rows =
      Database.prepare_snapshot_activation
        dependencies
        inspection
        ~path
        ~applied_server_cursor:cursor
        ~expected_checksum:None
        ~expected_rows
    in
    (match prepare ~path:"relative.snapshot" ~expected_rows:1 with
     | Error Invalid_snapshot_path -> ()
     | Error _ -> Alcotest.fail "relative input returned the wrong error"
     | Ok _ -> Alcotest.fail "relative snapshot input was accepted");
    (match
       prepare ~path:"/definitely/missing/logseq-overlay.snapshot" ~expected_rows:1
     with
     | Error Invalid_snapshot_path -> ()
     | Error _ -> Alcotest.fail "missing input returned the wrong error"
     | Ok _ -> Alcotest.fail "missing snapshot input was accepted");
    let path = Filename.concat root "snapshot" in
    let channel = open_out_bin path in
    close_out channel;
    (match prepare ~path ~expected_rows:(-1) with
     | Error Invalid_expected_rows -> ()
     | Error _ -> Alcotest.fail "negative row count returned the wrong error"
     | Ok _ -> Alcotest.fail "negative snapshot row count was accepted");
    let linked_path = Filename.concat root "snapshot-link" in
    Unix.link path linked_path;
    (match prepare ~path ~expected_rows:0 with
     | Error Invalid_snapshot_path -> ()
     | Error _ -> Alcotest.fail "multiply-linked input returned the wrong error"
     | Ok _ -> Alcotest.fail "multiply-linked snapshot input was accepted");
    T.require
      (not (Sys.file_exists (Filename.concat support "logseq-db-worker")))
      "invalid snapshot input allocated staging resources")
;;

let snapshot_activation_installs_queryable_mirror () =
  let behavior = "snapshot activation installs one queryable mirror" in
  T.with_temp_directory "overlay-snapshot-activation-" (fun root ->
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let dependencies, _location, prepared =
      prepare_snapshot ~wire_batch_max_bytes:128 ~behavior root support
    in
    let batches = supply_snapshot_crypto ~behavior prepared 0 in
    T.require
      (batches > 1)
      "protected snapshot values were not split into bounded batches";
    let inspection =
      Database.commit_snapshot_activation prepared |> T.require_ok ~behavior
    in
    (match Database.mirror_presence inspection with
     | Available { graph_uuid; checkpoint; checksum; _ } ->
       T.require
         (Logseq_db_types.Graph_types.Uuid.equal graph_uuid T.graph_uuid)
         "activated inspection returned the wrong graph UUID";
       T.require
         (Server_cursor.equal checkpoint (server_cursor 0))
         "activated inspection returned the wrong checkpoint";
       T.require (Option.is_some checksum) "activated inspection omitted the checksum"
     | Absent _ -> Alcotest.fail "committed snapshot remained absent");
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies inspection ~graph_name:"activated-graph"
          |> T.require_ok ~behavior
        in
        let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
        let info = Database.graph_info snapshot |> T.require_ok ~behavior in
        Database.release_snapshot snapshot;
        Database.close database |> T.require_ok ~behavior;
        T.require
          (Logseq_db_types.Graph_types.Uuid.equal info.graph_uuid T.graph_uuid)
          "activated mirror was not queryable")))
;;

let canceled_snapshot_activation_removes_temporary_artifacts () =
  let behavior = "canceled snapshot activation removes temporary artifacts" in
  T.with_temp_directory "overlay-snapshot-cancel-" (fun root ->
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let _dependencies, location, prepared = prepare_snapshot ~behavior root support in
    let request =
      match
        Database.next_snapshot_unprotection_batch prepared |> T.require_ok ~behavior
      with
      | Some request -> request
      | None -> Alcotest.fail "protected snapshot did not request decryption"
    in
    let plaintexts = Database.unprotection_ciphertexts request in
    Database.cancel_snapshot_activation prepared;
    (match Database.supply_snapshot_unprotection_batch prepared ~request ~plaintexts with
     | Error Snapshot_preparation_canceled -> ()
     | Error _ -> Alcotest.fail "canceled crypto supply returned the wrong error"
     | Ok () -> Alcotest.fail "canceled preparation accepted crypto input");
    (match Database.next_snapshot_unprotection_batch prepared with
     | Error Snapshot_preparation_canceled -> ()
     | Error _ -> Alcotest.fail "canceled preparation returned the wrong error"
     | Ok _ -> Alcotest.fail "canceled preparation remained usable");
    let refreshed = inspect_mirror location behavior in
    match Database.mirror_presence refreshed with
    | Absent _ -> ()
    | Available _ -> Alcotest.fail "canceled activation installed a mirror")
;;

let snapshot_crypto_results_are_validated_before_staging () =
  let behavior = "snapshot crypto results are validated before staging" in
  T.with_temp_directory "overlay-snapshot-crypto-validation-" (fun root ->
    let prepare name =
      let fixture_root = Filename.concat root (name ^ "-fixture") in
      let support = Filename.concat root (name ^ "-target") in
      Unix.mkdir fixture_root 0o700;
      Unix.mkdir support 0o700;
      let _dependencies, location, prepared =
        prepare_snapshot ~behavior fixture_root support
      in
      let request =
        match
          Database.next_snapshot_unprotection_batch prepared |> T.require_ok ~behavior
        with
        | Some request -> request
        | None -> Alcotest.fail "protected snapshot omitted its crypto request"
      in
      location, prepared, request
    in
    let first_location, first, request = prepare "first" in
    let plaintexts = Database.unprotection_ciphertexts request in
    List.iter
      (fun (name, expected_error, malformed) ->
         match
           Database.supply_snapshot_unprotection_batch
             first
             ~request
             ~plaintexts:malformed
         with
         | Error (Snapshot_crypto_result_error actual_error)
           when T.crypto_result_error_equal expected_error actual_error -> ()
         | Error _ -> Alcotest.failf "%s snapshot crypto returned the wrong error" name
         | Ok () -> Alcotest.failf "%s snapshot crypto was accepted" name)
      (T.malformed_crypto_results ~maximum_value_bytes:(4 * 1_024 * 1_024) plaintexts);
    let _second_location, second, foreign_request = prepare "second" in
    (match
       Database.supply_snapshot_unprotection_batch
         first
         ~request:foreign_request
         ~plaintexts:(Database.unprotection_ciphertexts foreign_request)
     with
     | Error (Snapshot_crypto_result_error Crypto_result_stale) -> ()
     | Error _ -> Alcotest.fail "foreign snapshot request returned the wrong error"
     | Ok () -> Alcotest.fail "foreign snapshot request was accepted");
    Database.supply_snapshot_unprotection_batch first ~request ~plaintexts
    |> T.require_ok ~behavior;
    (match Database.supply_snapshot_unprotection_batch first ~request ~plaintexts with
     | Error (Snapshot_crypto_result_error Crypto_result_stale) -> ()
     | Error _ -> Alcotest.fail "stale snapshot request returned the wrong error"
     | Ok () -> Alcotest.fail "stale snapshot request was accepted");
    Database.cancel_snapshot_activation first;
    Database.cancel_snapshot_activation second;
    match Database.mirror_presence (inspect_mirror first_location behavior) with
    | Absent _ -> ()
    | Available _ -> Alcotest.fail "invalid snapshot crypto installed a mirror")
;;

let stale_snapshot_inspection_cannot_replace_mirror () =
  let behavior = "stale snapshot inspection cannot replace a mirror" in
  T.with_temp_directory "overlay-snapshot-stale-" (fun root ->
    let target = Filename.concat root "target" in
    Unix.mkdir target 0o700;
    let dependencies, _location, inspection = absent_inspection ~behavior target in
    let path, applied_server_cursor, expected_checksum, expected_rows =
      snapshot_input_for root
    in
    ignore (T.seed_mirror target);
    match
      Database.prepare_snapshot_activation
        dependencies
        inspection
        ~path
        ~applied_server_cursor
        ~expected_checksum
        ~expected_rows
    with
    | Error Stale_snapshot_inspection -> ()
    | Error _ -> Alcotest.fail "stale snapshot inspection returned the wrong error"
    | Ok prepared ->
      Database.cancel_snapshot_activation prepared;
      Alcotest.fail "stale snapshot inspection was accepted")
;;

let snapshot_commit_is_single_use () =
  let behavior = "snapshot commit is single-use" in
  T.with_temp_directory "overlay-snapshot-single-use-" (fun root ->
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let _dependencies, _location, prepared = prepare_snapshot ~behavior root support in
    ignore (supply_snapshot_crypto ~behavior prepared 0);
    ignore (Database.commit_snapshot_activation prepared |> T.require_ok ~behavior);
    match Database.commit_snapshot_activation prepared with
    | Error Snapshot_commit_consumed -> ()
    | Error _ -> Alcotest.fail "duplicate snapshot commit returned the wrong error"
    | Ok _ -> Alcotest.fail "snapshot commit was applied twice")
;;

let snapshot_checksum_mismatch_fails_before_activation () =
  let behavior = "snapshot checksum mismatch fails before activation" in
  T.with_temp_directory "overlay-snapshot-checksum-" (fun root ->
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let snapshot_path, expected_rows = snapshot_fixture root in
    let dependencies, _location, inspection = absent_inspection ~behavior support in
    match
      Database.prepare_snapshot_activation
        dependencies
        inspection
        ~path:snapshot_path
        ~applied_server_cursor:(server_cursor 0)
        ~expected_checksum:(Some (checksum "ffffffffffffffff"))
        ~expected_rows
    with
    | Error (Snapshot_parse_error _) ->
      (match Database.mirror_presence (inspect_mirror support behavior) with
       | Absent _ -> ()
       | Available _ -> Alcotest.fail "mismatching checksum published a mirror");
      let staging_root = Filename.concat support "logseq-db-worker/synced-graphs" in
      Alcotest.(check int)
        "mismatch removed staging artifacts"
        0
        (Array.length (Sys.readdir staging_root))
    | Error _ -> Alcotest.fail "checksum mismatch returned the wrong error"
    | Ok prepared ->
      Database.cancel_snapshot_activation prepared;
      Alcotest.fail "checksum mismatch reached activation")
;;

let checksum_snapshot_fixture root ~e2ee ~empty ~duplicates ~title =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let source = Filename.concat root "source" in
  Unix.mkdir source 0o700;
  let database_path = T.seed_mirror source in
  if e2ee then T.mark_snapshot_e2ee database_path;
  let connection =
    Storage.open_database database_path |> T.require_ok ~behavior:"open vector"
  in
  let original =
    Storage.restore_database connection |> T.require_ok ~behavior:"restore vector"
  in
  let base =
    Datascript.datoms original Datascript.Eavt ()
    |> List.of_seq
    |> List.filter (fun (d : Datascript.datom) ->
      not
        (List.mem
           d.a
           [ "block/uuid"
           ; "block/name"
           ; "block/title"
           ; "block/page"
           ; "block/parent"
           ; "block/order"
           ; "block/tags"
           ]))
  in
  let d e a v : Datascript.datom = { e; a; v; tx = 536870913; added = true } in
  let u n = Printf.sprintf "91000000-0000-4000-8000-%012d" n in
  let facts =
    if empty
    then []
    else
      [ d 200000 "block/uuid" (Uuid (u 0))
      ; d 200000 "block/name" (String "journal")
      ; d 200000 "block/title" (String "日誌😀")
      ; d 200001 "block/uuid" (Uuid (u 1))
      ; d 200001 "block/page" (Ref 200000)
      ; d 200001 "block/parent" (Ref 200000)
      ; d 200001 "block/order" (String "a0")
      ; d 200001 "block/title" (String title)
      ; d 200002 "block/uuid" (Uuid (u 2))
      ; d 200002 "block/name" (String "excluded built-in")
      ; d 200002 "logseq.property/built-in?" (Bool true)
      ; d 200003 "block/uuid" (Uuid (u 3))
      ; d 200003 "block/title" (String "excluded orphan")
      ; d 200004 "block/name" (String "excluded without UUID")
      ; d 200005 "block/uuid" (Uuid (u 1))
      ; d 200005 "block/page" (Ref 200004)
      ; d 200005 "block/order" (String "a1")
      ; d 200006 "db/ident" (Keyword "logseq.class/Page")
      ; d 200007 "block/uuid" (Uuid (u 7))
      ; d 200007 "block/tags" (Ref 200006)
      ]
  in
  let repeated =
    if duplicates
    then List.map (fun (d : Datascript.datom) -> { d with tx = d.tx + 1 }) facts
    else []
  in
  let database =
    Datascript.init_db ~schema:(Datascript.schema original) (base @ facts @ repeated)
  in
  let callbacks = Storage.connection_callbacks connection in
  callbacks.begin_staging () |> T.require_ok ~behavior:"begin vector";
  ignore (Datascript.store ~storage:callbacks.storage database);
  let batch =
    callbacks.finish_staging
      None
      [ Datascript.Storage.tail_address, Datascript.Storage_tail [] ]
    |> T.require_ok ~behavior:"finish vector"
  in
  Storage.commit_batch callbacks batch |> T.require_ok ~behavior:"commit vector";
  Storage.close callbacks |> T.require_ok ~behavior:"close vector";
  let path = Filename.concat root "snapshot.transit" in
  let rows = T.write_snapshot_from_database ~database_path ~snapshot_path:path in
  path, rows
;;

let checksum_vectors_preserve_snapshot_semantics () =
  let behavior = "snapshot checksum independent vectors" in
  List.iter
    (fun (e2ee, empty, digest) ->
       List.iter
         (fun duplicates ->
            List.iter
              (fun expected ->
                 T.with_temp_directory "overlay-checksum-vector-" (fun root ->
                   let path, expected_rows =
                     checksum_snapshot_fixture
                       root
                       ~e2ee
                       ~empty
                       ~duplicates
                       ~title:"café é 🚀"
                   in
                   let support = Filename.concat root "target" in
                   Unix.mkdir support 0o700;
                   let dependencies, _, inspection =
                     absent_inspection ~behavior support
                   in
                   let prepared =
                     Database.prepare_snapshot_activation
                       dependencies
                       inspection
                       ~path
                       ~applied_server_cursor:(server_cursor 7)
                       ~expected_checksum:
                         (if expected then Some (checksum digest) else None)
                       ~expected_rows
                     |> T.require_ok ~behavior
                   in
                   Fun.protect
                     ~finally:(fun () -> Database.cancel_snapshot_activation prepared)
                     (fun () ->
                        ignore (supply_snapshot_crypto ~behavior prepared 0);
                        ignore
                          (Database.commit_snapshot_activation prepared
                           |> T.require_ok ~behavior);
                        match
                          Database.mirror_presence (inspect_mirror support behavior)
                        with
                        | Available { checksum = Some actual; checkpoint; _ } ->
                          Alcotest.(check string)
                            "durable independently checked checksum"
                            (Checksum.to_string (checksum digest))
                            (Checksum.to_string actual);
                          T.require
                            (Server_cursor.equal checkpoint (server_cursor 7))
                            "lost checkpoint cursor"
                        | _ -> Alcotest.fail "activation did not persist a checksum")))
              [ false; true ])
         [ false; true ])
    [ false, false, "644f8bcb33ecbfff"
    ; true, false, "aaf8f63fd3b0dd97"
    ; false, true, "0000000000000000"
    ; true, true, "0000000000000000"
    ]
;;

let unused_preparation_checksum_defers_invalid_utf8_without_publication () =
  let behavior = "unused preparation checksum defers invalid UTF-8" in
  T.with_temp_directory "overlay-checksum-late-failure-" (fun root ->
    let path, expected_rows =
      checksum_snapshot_fixture
        root
        ~e2ee:false
        ~empty:false
        ~duplicates:false
        ~title:"\255"
    in
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let dependencies, _, inspection = absent_inspection ~behavior support in
    let prepared =
      Database.prepare_snapshot_activation
        dependencies
        inspection
        ~path
        ~applied_server_cursor:(server_cursor 0)
        ~expected_checksum:None
        ~expected_rows
      |> T.require_ok ~behavior
    in
    Fun.protect
      ~finally:(fun () -> Database.cancel_snapshot_activation prepared)
      (fun () ->
         ignore (supply_snapshot_crypto ~behavior prepared 0);
         for _attempt = 1 to 2 do
           (match Database.commit_snapshot_activation prepared with
            | Error (Snapshot_parse_error message) ->
              T.require
                (String.starts_with ~prefix:"Invalid_argument" message)
                "late failure was not checksum UTF-8 validation"
            | Error _ -> Alcotest.fail "late checksum failure returned the wrong error"
            | Ok _ -> Alcotest.fail "invalid checksum input was published");
           match Database.mirror_presence (inspect_mirror support behavior) with
           | Absent _ -> ()
           | Available _ -> Alcotest.fail "failed checksum published a mirror"
         done;
         Database.cancel_snapshot_activation prepared;
         Database.cancel_snapshot_activation prepared;
         let staging_root = Filename.concat support "logseq-db-worker/synced-graphs" in
         Alcotest.(check int)
           "cancellation removed staging artifacts"
           0
           (Array.length (Sys.readdir staging_root));
         match Database.commit_snapshot_activation prepared with
         | Error Snapshot_preparation_canceled -> ()
         | _ -> Alcotest.fail "canceled late failure remained usable"))
;;

let available_mirror_is_generation_bound () =
  let behavior = "available mirror inspection is generation-bound" in
  T.with_temp_directory "overlay-mirror-inspection-" (fun support ->
    ignore (T.seed_mirror support);
    let _dependencies, _location, inspection = location_and_inspection support behavior in
    match Database.mirror_presence inspection with
    | Available { graph_uuid; checksum; _ } ->
      T.require
        (Logseq_db_types.Graph_types.Uuid.equal graph_uuid T.graph_uuid)
        "mirror inspection returned the wrong graph UUID";
      T.require (Option.is_some checksum) "mirror inspection omitted the checksum"
    | Absent _ -> Alcotest.fail "seeded mirror was reported absent")
;;

let inspect_and_open_validation_is_fail_closed () =
  let behavior = "inspect and open validation is fail closed" in
  (match
     Database.inspect_mirror ~application_support_directory:"   " ~graph_id:T.graph_uuid
   with
   | Error Invalid_application_support_directory -> ()
   | Error _ -> Alcotest.fail "blank support directory returned the wrong error"
   | Ok _ -> Alcotest.fail "blank support directory was accepted");
  T.with_temp_directory "overlay-open-inputs-" (fun root ->
    let absent_support = Filename.concat root "absent" in
    Unix.mkdir absent_support 0o700;
    let dependencies, _location, absent = absent_inspection ~behavior absent_support in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        (match Database.open_ ~sw dependencies absent ~graph_name:"oracle-graph" with
         | Error Mirror_absent -> ()
         | Error _ -> Alcotest.fail "absent mirror returned the wrong open error"
         | Ok database ->
           ignore (Database.close database);
           Alcotest.fail "absent mirror was opened");
        let available_support = Filename.concat root "available" in
        Unix.mkdir available_support 0o700;
        ignore (T.seed_mirror available_support);
        let available = inspect_mirror available_support behavior in
        match Database.open_ ~sw dependencies available ~graph_name:" \t " with
        | Error Invalid_graph_name -> ()
        | Error _ -> Alcotest.fail "blank graph name returned the wrong open error"
        | Ok database ->
          ignore (Database.close database);
          Alcotest.fail "blank graph name was accepted")))
;;

let snapshot_publication_failure_is_retryable () =
  let behavior = "snapshot publication failure is retryable" in
  T.with_temp_directory "overlay-snapshot-retry-" (fun root ->
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let _dependencies, _location, prepared = prepare_snapshot ~behavior root support in
    ignore (supply_snapshot_crypto ~behavior prepared 0);
    let staging_root = Filename.concat support "logseq-db-worker/synced-graphs" in
    Unix.chmod staging_root 0o500;
    let first = Database.commit_snapshot_activation prepared in
    Unix.chmod staging_root 0o700;
    (match first with
     | Error (Snapshot_commit_persistence_failed _) -> ()
     | Error _ -> Alcotest.fail "publication failure returned the wrong error"
     | Ok _ -> Alcotest.fail "publication unexpectedly succeeded without write access");
    let inspection =
      Database.commit_snapshot_activation prepared |> T.require_ok ~behavior
    in
    match Database.mirror_presence inspection with
    | Available { checksum = Some _; _ } -> ()
    | Available { checksum = None; _ } ->
      Alcotest.fail "retried activation omitted its checksum"
    | Absent _ -> Alcotest.fail "retried activation remained absent")
;;

let stale_snapshot_commit_can_be_canceled () =
  let behavior = "stale snapshot commit can be canceled" in
  T.with_temp_directory "overlay-snapshot-stale-commit-" (fun root ->
    let support = Filename.concat root "target" in
    Unix.mkdir support 0o700;
    let _dependencies, _location, prepared = prepare_snapshot ~behavior root support in
    ignore (supply_snapshot_crypto ~behavior prepared 0);
    ignore (T.seed_mirror support);
    (match Database.commit_snapshot_activation prepared with
     | Error Snapshot_commit_stale -> ()
     | Error _ -> Alcotest.fail "stale publication returned the wrong error"
     | Ok _ -> Alcotest.fail "stale publication replaced the active mirror");
    Database.cancel_snapshot_activation prepared;
    Database.cancel_snapshot_activation prepared;
    match Database.commit_snapshot_activation prepared with
    | Error Snapshot_preparation_canceled -> ()
    | Error _ -> Alcotest.fail "canceled persisted preparation returned the wrong error"
    | Ok _ -> Alcotest.fail "canceled persisted preparation was committed")
;;

let stale_delete_cannot_remove_replacement () =
  let behavior = "stale mirror delete is rejected" in
  T.with_temp_directory "overlay-stale-delete-" (fun support ->
    ignore (T.seed_mirror support);
    let _dependencies, _location, inspection = location_and_inspection support behavior in
    ignore (Database.delete_mirror inspection |> T.require_ok ~behavior);
    match Database.delete_mirror inspection with
    | Error Mirror_delete_stale -> ()
    | Error _ -> Alcotest.fail "stale delete returned the wrong typed error"
    | Ok _ -> Alcotest.fail "stale inspection deleted a mirror twice")
;;

let corrupt_outbox_fails_closed () =
  let behavior = "corrupt durable outbox fails closed" in
  T.with_temp_directory "overlay-corrupt-outbox-" (fun support ->
    let database_path = T.seed_mirror support in
    let sqlite = Sqlite3.db_open database_path in
    Sqlite3.Rc.check
      (Sqlite3.exec
         sqlite
         "INSERT INTO sync_outbox(position, record) VALUES(0, 'not-canonical-overlay')");
    T.require (Sqlite3.db_close sqlite) "unable to close corrupt fixture";
    let dependencies, _location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        for _attempt = 1 to 2 do
          match
            Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          with
          | Error (Corrupt_outbox _) -> ()
          | Error Ownership_conflict ->
            Alcotest.fail "failed open retained graph ownership"
          | Error _ -> Alcotest.fail "corrupt outbox returned the wrong open error"
          | Ok database ->
            ignore (Database.close database);
            Alcotest.fail "corrupt outbox was accepted"
        done)))
;;

let persistence_outbox_uses_frozen_v16_json () =
  let top_level_keys =
    [ "acceptanceBarrier"
    ; "attemptCount"
    ; "blockedPriorState"
    ; "blockedReason"
    ; "fingerprint"
    ; "formatVersion"
    ; "intentTimeMs"
    ; "plannedTx"
    ; "sequence"
    ; "dependencyShadows"
    ; "effectFootprint"
    ; "deleteArtifacts"
    ; "mutation"
    ; "normalizedTransaction"
    ; "protectedTransaction"
    ; "state"
    ; "sameIdRetryEligible"
    ; "submissionTBefore"
    ; "submissionOrdinal"
    ; "submissionCount"
    ; "observedOriginCursor"
    ; "staleEarliestConflictCursor"
    ; "staleConflicts"
    ; "syncRevision"
    ]
  in
  let cases =
    [ ( "saveBlock"
      , [ "block"; "mutationId"; "title"; "type" ]
      , fun database ->
          ( Save_block
              { mutation_id = T.mutation_uuid 600
              ; block = T.authoritative_block_uuid
              ; title = "Golden saved block"
              }
          , block_precondition database T.authoritative_block_uuid "freeze saveBlock JSON"
          ) )
    ; ( "insertBlocks"
      , [ "mutationId"; "parent"; "tree"; "asset"; "type" ]
      , fun database ->
          ( T.insert_blocks ~ordinal:601 ()
          , T.insert_precondition
              database
              ~parent:T.page_uuid
              ~behavior:"freeze insertBlocks JSON" ) )
    ; ( "deleteBlocks"
      , [ "mutationId"; "root"; "type" ]
      , fun database ->
          ( Delete_blocks
              { mutation_id = T.mutation_uuid 602; root = T.authoritative_block_uuid }
          , T.delete_precondition
              database
              ~block:T.authoritative_block_uuid
              ~behavior:"freeze deleteBlocks JSON" ) )
    ; ( "createJournalPage"
      , [ "journalDay"; "mutationId"; "page"; "title"; "type" ]
      , fun database ->
          ( T.create_journal_page ~ordinal:603 ()
          , page_precondition database T.missing_page_uuid "freeze createJournalPage JSON"
          ) )
    ; ( "setTaskStatus"
      , [ "block"; "mutationId"; "status"; "type" ]
      , fun database ->
          ( Set_task_status
              { mutation_id = T.mutation_uuid 604
              ; block = T.authoritative_block_uuid
              ; status = Todo
              }
          , block_precondition
              database
              T.authoritative_block_uuid
              "freeze setTaskStatus JSON" ) )
    ; ( "clearTaskStatus"
      , [ "block"; "mutationId"; "type" ]
      , fun database ->
          let setup =
            Set_task_status
              { mutation_id = T.mutation_uuid 605
              ; block = T.authoritative_block_uuid
              ; status = Todo
              }
          in
          let expected =
            block_precondition
              database
              T.authoritative_block_uuid
              "prepare clearTaskStatus JSON"
          in
          (match
             T.commit_mutation database ~expected setup ~behavior:"prepare clear JSON"
           with
           | Local_committed _ -> ()
           | Local_existing _ -> Alcotest.fail "clear JSON setup already existed");
          ( Clear_task_status
              { mutation_id = T.mutation_uuid 606; block = T.authoritative_block_uuid }
          , block_precondition
              database
              T.authoritative_block_uuid
              "freeze clearTaskStatus JSON" ) )
    ]
  in
  List.iter
    (fun (mutation_kind, mutation_keys, prepare) ->
       let behavior = "freeze " ^ mutation_kind ^ " persistence JSON" in
       T.with_temp_directory
         ("overlay-codec-" ^ mutation_kind ^ "-")
         (fun support ->
            let database_path = T.seed_mirror support in
            let dependencies, _location, inspection =
              location_and_inspection support behavior
            in
            Eio_main.run (fun _environment ->
              Eio.Switch.run (fun sw ->
                let database =
                  Database.open_ ~sw dependencies inspection ~graph_name:"oracle-graph"
                  |> T.require_ok ~behavior
                in
                let mutation, expected = prepare database in
                (match T.commit_mutation database ~expected mutation ~behavior with
                 | Local_committed _ -> ()
                 | Local_existing _ -> Alcotest.fail "golden mutation already existed");
                Database.close database |> T.require_ok ~behavior));
            let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
            let records =
              Logseq_db_storage.Sync_outbox_store.read_database sqlite
              |> T.require_ok ~behavior
            in
            T.require (Sqlite3.db_close sqlite) "unable to close golden outbox fixture";
            let source, fields, mutation_fields =
              match
                records
                |> List.find_map (fun source ->
                  match Yojson.Safe.from_string source with
                  | `Assoc fields as json ->
                    (match List.assoc_opt "mutation" fields with
                     | Some (`Assoc mutation_fields) ->
                       (match List.assoc_opt "type" mutation_fields with
                        | Some (`String actual) when String.equal actual mutation_kind ->
                          Some (source, json, fields, mutation_fields)
                        | _ -> None)
                     | _ -> None)
                  | _ -> None)
              with
              | None -> Alcotest.failf "golden %s record is missing" mutation_kind
              | Some (source, json, fields, mutation_fields) ->
                T.require
                  (String.equal source (Yojson.Safe.to_string json))
                  "%s JSON is not compact and canonical"
                  mutation_kind;
                source, fields, mutation_fields
            in
            ignore source;
            Alcotest.(check (list string))
              (mutation_kind ^ " top-level JSON keys")
              top_level_keys
              (List.map fst fields);
            Alcotest.(check (list string))
              (mutation_kind ^ " mutation JSON keys")
              mutation_keys
              (List.map fst mutation_fields);
            (match List.assoc_opt "state" fields with
             | Some (`Assoc [ ("type", `String "queued") ]) -> ()
             | _ ->
               Alcotest.failf "%s did not encode queued state canonically" mutation_kind);
            List.iter
              (fun field ->
                 match List.assoc_opt field fields with
                 | Some `Null -> ()
                 | _ -> Alcotest.failf "%s did not encode %s as null" mutation_kind field)
              [ "acceptanceBarrier"
              ; "blockedPriorState"
              ; "blockedReason"
              ; "protectedTransaction"
              ; "submissionTBefore"
              ; "submissionOrdinal"
              ; "submissionCount"
              ; "observedOriginCursor"
              ; "staleEarliestConflictCursor"
              ]))
    cases
;;

let require_frozen_mutation_receipt database_path outcome expected_keys =
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
  let receipts =
    Logseq_db_storage.Mutation_receipt_store.read_database sqlite
    |> T.require_ok ~behavior:("read " ^ outcome ^ " receipt JSON")
  in
  T.require (Sqlite3.db_close sqlite) "unable to close golden receipt fixture";
  match
    receipts
    |> List.find_map (fun (_key, source) ->
      match Yojson.Safe.from_string source with
      | `Assoc fields as json ->
        (match List.assoc_opt "outcome" fields with
         | Some (`String actual) when String.equal actual outcome ->
           Some (source, json, fields)
         | _ -> None)
      | _ -> None)
  with
  | None -> Alcotest.failf "golden %s receipt is missing" outcome
  | Some (source, json, fields) ->
    T.require
      (String.equal source (Yojson.Safe.to_string json))
      "%s receipt JSON is not compact and canonical"
      outcome;
    Alcotest.(check (list string))
      (outcome ^ " receipt JSON keys")
      expected_keys
      (List.map fst fields)
;;

let duplicate_outbox_member_fails_closed () =
  let behavior = "duplicate durable outbox member fails closed" in
  T.with_temp_directory "overlay-duplicate-outbox-" (fun support ->
    let database_path = T.seed_mirror support in
    let dependencies, location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        (match
           T.commit_mutation
             database
             ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
             (T.insert_blocks ~ordinal:405 ())
             ~behavior
         with
         | Local_committed _ -> ()
         | Local_existing _ -> Alcotest.fail "fresh duplicate fixture already existed");
        Database.close database |> T.require_ok ~behavior;
        let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
        let records =
          Logseq_db_storage.Sync_outbox_store.read_database sqlite |> T.require_ok ~behavior
        in
        Sqlite3.Rc.check
          (Sqlite3.exec
             sqlite
             "DROP TABLE sync_outbox; DROP TABLE sync_outbox_metadata; \
              CREATE TABLE sync_outbox(position INTEGER PRIMARY KEY, record TEXT NOT NULL)");
        Logseq_db_storage.Sync_outbox_store.replace_database sqlite (records @ records)
        |> T.require_ok ~behavior;
        T.require (Sqlite3.db_close sqlite) "unable to close duplicate fixture";
        let refreshed = inspect_mirror location behavior in
        let opening_inspection = refreshed in
        match
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
        with
        | Error (Corrupt_outbox _) -> ()
        | Error _ -> Alcotest.fail "duplicate outbox returned the wrong open error"
        | Ok duplicate ->
          Database.close duplicate |> T.require_ok ~behavior;
          Alcotest.fail "duplicate outbox member was accepted")))
;;

let corrupt_single_outbox_record sqlite record =
  let statement = Sqlite3.prepare sqlite "UPDATE sync_outbox SET record=?" in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize statement)) (fun () ->
    Sqlite3.Rc.check (Sqlite3.bind_text statement 1 record);
    Sqlite3.Rc.check (Sqlite3.step statement))
;;

let noncanonical_outbox_payload_fails_closed () =
  let behavior = "noncanonical durable outbox payload fails closed" in
  T.with_temp_directory "overlay-noncanonical-outbox-" (fun support ->
    let database_path = T.seed_mirror support in
    let dependencies, location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        (match
           T.commit_mutation
             database
             ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
             (T.insert_blocks ~ordinal:406 ())
             ~behavior
         with
         | Local_committed _ -> ()
         | Local_existing _ -> Alcotest.fail "fresh canonical fixture already existed");
        Database.close database |> T.require_ok ~behavior;
        let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
        let records =
          Logseq_db_storage.Sync_outbox_store.read_database sqlite
          |> T.require_ok ~behavior
        in
        let tampered =
          match records with
          | [ source ] ->
            (match Yojson.Safe.from_string source with
             | `Assoc fields ->
               `Assoc
                 (("normalizedTransaction", `String "tampered")
                  :: List.remove_assoc "normalizedTransaction" fields)
               |> Yojson.Safe.to_string
             | _ -> Alcotest.fail "queued fixture record is not JSON")
          | _ -> Alcotest.fail "queued fixture has the wrong outbox cardinality"
        in
        corrupt_single_outbox_record sqlite tampered;
        T.require (Sqlite3.db_close sqlite) "unable to close noncanonical fixture";
        let refreshed = inspect_mirror location behavior in
        let opening_inspection = refreshed in
        match
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
        with
        | Error (Corrupt_outbox _) -> ()
        | Error _ -> Alcotest.fail "noncanonical outbox returned the wrong open error"
        | Ok noncanonical ->
          Database.close noncanonical |> T.require_ok ~behavior;
          Alcotest.fail "noncanonical outbox payload was accepted")))
;;

let inconsistent_origin_evidence_fails_closed () =
  let behavior = "inconsistent durable origin evidence fails closed" in
  T.with_temp_directory "overlay-origin-evidence-" (fun support ->
    let database_path = T.seed_mirror support in
    let dependencies, location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        (match
           T.commit_mutation
             database
             ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
             (T.insert_blocks ~ordinal:407 ())
             ~behavior
         with
         | Local_committed _ -> ()
         | Local_existing _ -> Alcotest.fail "fresh canonical fixture already existed");
        Database.close database |> T.require_ok ~behavior;
        let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
        let records =
          Logseq_db_storage.Sync_outbox_store.read_database sqlite
          |> T.require_ok ~behavior
        in
        let tampered =
          match records with
          | [ source ] ->
            (match Yojson.Safe.from_string source with
             | `Assoc fields ->
               `Assoc
                 (("observedOriginCursor", `String "server-cursor:v1:999")
                  :: List.remove_assoc "observedOriginCursor" fields)
               |> Yojson.Safe.to_string
             | _ -> Alcotest.fail "queued fixture record is not JSON")
          | _ -> Alcotest.fail "queued fixture has the wrong outbox cardinality"
        in
        corrupt_single_outbox_record sqlite tampered;
        T.require (Sqlite3.db_close sqlite) "unable to close origin-evidence fixture";
        let refreshed = inspect_mirror location behavior in
        let opening_inspection = refreshed in
        match
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
        with
        | Error (Corrupt_outbox _) -> ()
        | Error _ -> Alcotest.fail "inconsistent origin evidence returned wrong error"
        | Ok inconsistent ->
          Database.close inconsistent |> T.require_ok ~behavior;
          Alcotest.fail "inconsistent origin evidence was accepted")))
;;

let garbage_collection_preserves_receipt_ledgers () =
  let behavior = "garbage collection preserves mutation and terminal-batch receipts" in
  T.with_temp_directory "overlay-garbage-collection-" (fun support ->
    ignore (T.seed_mirror support);
    let _dependencies, _location, inspection = location_and_inspection support behavior in
    let result = Database.collect_garbage inspection |> T.require_ok ~behavior in
    T.require
      (result.retained_mutation_receipts >= 0
       && result.retained_terminal_batch_receipts >= 0)
      "garbage collection returned invalid retained receipt counts")
;;

let close_then_reopen_preserves_projection () =
  let behavior = "close and reopen preserve logical projection" in
  T.with_temp_directory "overlay-reopen-" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies, _location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let first =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let first_snapshot = Database.current_snapshot first |> T.require_ok ~behavior in
        let first_info = Database.graph_info first_snapshot |> T.require_ok ~behavior in
        Database.release_snapshot first_snapshot;
        Database.close first |> T.require_ok ~behavior;
        let refreshed = inspect_mirror support behavior in
        let opening_inspection = refreshed in
        let second =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let second_snapshot =
          Database.current_snapshot second |> T.require_ok ~behavior
        in
        let second_info = Database.graph_info second_snapshot |> T.require_ok ~behavior in
        Database.release_snapshot second_snapshot;
        Database.close second |> T.require_ok ~behavior;
        T.require
          (Logseq_db_types.Graph_types.Uuid.equal
             first_info.graph_uuid
             second_info.graph_uuid)
          "reopen changed graph identity";
        T.require
          (not
             (Generation.equal
                first_info.version.generation
                second_info.version.generation))
          "reopen reused the previous generation")))
;;

let pending_outbox_survives_reopen () =
  let behavior = "pending outbox survives close and reopen" in
  T.with_temp_directory "overlay-pending-reopen-" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies, location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let first =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let expected = T.insert_precondition first ~parent:T.page_uuid ~behavior in
        (match
           T.commit_mutation first ~expected (T.insert_blocks ~ordinal:400 ()) ~behavior
         with
         | Local_committed _ -> ()
         | Local_existing _ -> Alcotest.fail "fresh pending mutation already existed");
        Database.close first |> T.require_ok ~behavior;
        let refreshed = inspect_mirror location behavior in
        let opening_inspection = refreshed in
        let second =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let snapshot = Database.current_snapshot second |> T.require_ok ~behavior in
        (match
           Database.get_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior
         with
         | [ Present_block { value; _ } ] ->
           T.require (value.block.title = "Inserted") "reopened pending title changed"
         | _ -> Alcotest.fail "reopen lost pending block");
        Database.release_snapshot snapshot;
        let sync = Database.inspect_sync second |> T.require_ok ~behavior in
        (match sync_view_submissions sync with
         | [ descriptor ] when descriptor.state = Queued -> ()
         | _ -> Alcotest.fail "reopen lost queued outbox state");
        Database.close second |> T.require_ok ~behavior)))
;;

let submitted_dependency_shadow_survives_reopen () =
  let behavior = "submitted dependency shadow survives close and reopen" in
  T.with_temp_directory "overlay-shadow-reopen-" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies, location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let first =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let mutation =
          Save_block
            { mutation_id = T.mutation_uuid 401
            ; block = T.authoritative_block_uuid
            ; title = "Frozen across reopen"
            }
        in
        let local =
          match
            T.commit_mutation
              first
              ~expected:(block_precondition first T.authoritative_block_uuid behavior)
              mutation
              ~behavior
          with
          | Local_committed commit -> commit
          | Local_existing _ -> Alcotest.fail "fresh shadow mutation already existed"
        in
        let sync = Database.inspect_sync first |> T.require_ok ~behavior in
        let submit, protection =
          match
            Database.begin_outbox_transition
              first
              ~expected:(sync_view_token sync)
              (Submit_group [ local.mutation_id ])
            |> T.require_ok ~behavior
          with
          | prepared, Some request -> prepared, request
          | _ -> Alcotest.fail "shadow submission omitted protection"
        in
        let encrypted =
          Database.protection_plaintexts protection
          |> List.map (fun (id, plaintext) -> id, "encrypted:" ^ plaintext)
        in
        Database.apply_outbox_transition
          first
          submit
          ~encrypted:(Some (protection, encrypted))
        |> T.require_ok ~behavior
        |> ignore;
        let module Transit = Transit_core.Json in
        let module Codec = Transit_native.Transit.Json in
        let wire =
          Transit.Array
            [ Transit.Array
                [ Transit.Keyword "db/retractEntity"
                ; Transit.Array
                    [ Transit.Keyword "block/uuid"
                    ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
                    ]
                ]
            ]
          |> Codec.to_string ~mode:Codec.Verbose
          |> encoded_transaction_of_string ~maximum_bytes:4_096
          |> T.require_ok ~behavior
        in
        let cursor = server_cursor 1 in
        let batch =
          authoritative_batch
            ~maximum_count:16
            ~maximum_bytes:4_096
            ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
            ~through:cursor
            ~checksum:None
          |> T.require_ok ~behavior
        in
        let sync = Database.inspect_sync first |> T.require_ok ~behavior in
        let prepared, crypto =
          Database.begin_authoritative first ~expected:(sync_view_token sync) batch
          |> T.require_ok ~behavior
        in
        T.require (Option.is_none crypto) "plaintext shadow removal requested crypto";
        let application =
          match
            Database.apply_authoritative first prepared ~decrypted:None
            |> T.require_ok ~behavior
          with
          | Authoritative_applied commit -> commit
          | Authoritative_deferred _ -> Alcotest.fail "shadow removal was deferred"
        in
        ignore application;
        Database.close first |> T.require_ok ~behavior;
        let refreshed = inspect_mirror location behavior in
        let opening_inspection = refreshed in
        let second =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let snapshot = Database.current_snapshot second |> T.require_ok ~behavior in
        (match
           Database.get_blocks snapshot [ T.authoritative_block_uuid ]
           |> T.require_ok ~behavior
         with
         | [ Present_block { value; _ } ] ->
           T.require
             (String.equal value.block.title "Frozen across reopen")
             "reopen lost the frozen dependency shadow"
         | _ -> Alcotest.fail "reopen lost the submitted shadow block");
        (match
           Database.get_structure
             snapshot
             (Children { parent = T.page_uuid; limit = 200; cursor = None })
           |> T.require_ok ~behavior
         with
         | Children_result { items; _ } ->
           T.require
             (List.exists
                (fun (item : child_member) ->
                   Graph.Uuid.equal item.block.block.uuid T.authoritative_block_uuid)
                items)
             "reopen lost the shadow parent membership"
         | Page_tree_result _ -> Alcotest.fail "children query returned a page tree");
        Database.release_snapshot snapshot;
        Database.close second |> T.require_ok ~behavior)))
;;

let open_owns_graph_exclusively () =
  let behavior = "open owns one graph exclusively" in
  T.with_temp_directory "overlay-exclusive-owner-" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies, _location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let first =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        (match
           Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
         with
         | Error Ownership_conflict -> ()
         | Error _ -> Alcotest.fail "second open returned the wrong ownership error"
         | Ok second ->
           ignore (Database.close second);
           Alcotest.fail "second open acquired an already-owned graph");
        Database.close first |> T.require_ok ~behavior;
        let reopened =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        Database.close reopened |> T.require_ok ~behavior)))
;;

let no_change_receipt_survives_reopen () =
  let behavior = "No_change receipt survives close and reopen" in
  T.with_temp_directory "overlay-no-change-reopen-" (fun support ->
    let database_path = T.seed_mirror support in
    let dependencies, location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let first =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let snapshot = Database.current_snapshot first |> T.require_ok ~behavior in
        let revision =
          match
            Database.get_blocks snapshot [ T.missing_block_uuid ]
            |> T.require_ok ~behavior
          with
          | [ Missing_block { revision; _ } ] -> revision
          | _ -> Alcotest.fail "No_change target unexpectedly exists"
        in
        Database.release_snapshot snapshot;
        let expected =
          Database.write_precondition
            ~blocks:[ T.missing_block_uuid, revision ]
            ~pages:[]
            ~scopes:[]
          |> T.require_ok ~behavior
        in
        let mutation =
          Save_block
            { mutation_id = T.mutation_uuid 405
            ; block = T.missing_block_uuid
            ; title = "Still missing"
            }
        in
        (match T.commit_mutation first ~expected mutation ~behavior with
         | Local_committed { status = No_change; _ } -> ()
         | _ -> Alcotest.fail "fresh missing-target mutation was not No_change");
        Database.close first |> T.require_ok ~behavior;
        require_frozen_mutation_receipt
          database_path
          "noChange"
          [ "fingerprint"; "formatVersion"; "mutationId"; "outcome" ];
        let refreshed = inspect_mirror location behavior in
        let opening_inspection = refreshed in
        let second =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        (match
           Database.commit_local
             second
             ~expected:(T.empty_precondition ~behavior)
             mutation
           |> T.require_ok ~behavior
         with
         | Local_existing (Existing_applied { status = Already_applied; _ }) -> ()
         | _ -> Alcotest.fail "reopen lost the durable No_change receipt");
        Database.close second |> T.require_ok ~behavior)))
;;

let authoritative_checkpoint_and_root_survive_reopen () =
  let behavior = "authoritative checkpoint and root survive reopen" in
  T.with_temp_directory "overlay-authoritative-reopen-" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies, location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let first =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let module Transit = Transit_core.Json in
        let module Codec = Transit_native.Transit.Json in
        let wire =
          Transit.Array
            [ Transit.Array
                [ Transit.Keyword "db/add"
                ; Transit.Array
                    [ Transit.Keyword "block/uuid"
                    ; Transit.Uuid
                        (Logseq_db_types.Graph_types.Uuid.to_string
                           T.authoritative_block_uuid)
                    ]
                ; Transit.Keyword "block/updated-at"
                ; Transit.Int 1_704_067_200_456
                ]
            ]
          |> Codec.to_string ~mode:Codec.Verbose
          |> encoded_transaction_of_string ~maximum_bytes:4_096
          |> T.require_ok ~behavior
        in
        let cursor =
          Server_cursor.of_string "server-cursor:v1:1" |> T.require_ok ~behavior
        in
        let batch =
          authoritative_batch
            ~maximum_count:16
            ~maximum_bytes:4_096
            ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
            ~through:cursor
            ~checksum:None
          |> T.require_ok ~behavior
        in
        let sync = Database.inspect_sync first |> T.require_ok ~behavior in
        let prepared, request =
          Database.begin_authoritative first ~expected:(sync_view_token sync) batch
          |> T.require_ok ~behavior
        in
        T.require
          (Option.is_none request)
          "plaintext authoritative fixture requested crypto";
        let application =
          match
            Database.apply_authoritative first prepared ~decrypted:None
            |> T.require_ok ~behavior
          with
          | Authoritative_applied commit -> commit
          | Authoritative_deferred _ -> Alcotest.fail "authoritative fixture was deferred"
        in
        ignore application;
        Database.close first |> T.require_ok ~behavior;
        let refreshed = inspect_mirror location behavior in
        (match Database.mirror_presence refreshed with
         | Available { checkpoint; _ } ->
           T.require
             (Server_cursor.equal checkpoint cursor)
             "reopen inspection lost authoritative checkpoint"
         | Absent _ -> Alcotest.fail "authoritative commit removed the mirror");
        let opening_inspection = refreshed in
        let second =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let snapshot = Database.current_snapshot second |> T.require_ok ~behavior in
        (match
           Database.get_blocks snapshot [ T.authoritative_block_uuid ]
           |> T.require_ok ~behavior
         with
         | [ Present_block { value; _ } ] ->
           T.require
             (value.block.updated_at_ms = 1_704_067_200_456L)
             "reopen lost authoritative block update"
         | _ -> Alcotest.fail "reopen lost authoritative block");
        Database.release_snapshot snapshot;
        Database.close second |> T.require_ok ~behavior)))
;;

let outbox_persistence_failure_is_atomic () =
  let behavior = "outbox persistence failure is atomic" in
  T.with_temp_directory "overlay-outbox-failure-" (fun support ->
    let database_path = T.seed_mirror support in
    let dependencies, _location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let before = Database.current_snapshot database |> T.require_ok ~behavior in
        let before_version = Database.snapshot_version before in
        Database.release_snapshot before;
        let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
        let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
        Sqlite3.Rc.check
          (Sqlite3.exec
             sqlite
             "CREATE TRIGGER fail_overlay_outbox_insert BEFORE INSERT ON sync_outbox \
              BEGIN SELECT RAISE(ABORT, 'injected overlay outbox failure'); END");
        T.require (Sqlite3.db_close sqlite) "unable to close outbox failure injector";
        (match
           Database.commit_local database ~expected (T.insert_blocks ~ordinal:410 ())
         with
         | Error (Local_commit_persistence_failed _) -> ()
         | Error _ -> Alcotest.fail "outbox failure returned the wrong commit error"
         | Ok _ -> Alcotest.fail "outbox failure exposed a successful commit");
        let after = Database.current_snapshot database |> T.require_ok ~behavior in
        let after_version = Database.snapshot_version after in
        T.require
          (Projection_revision.equal
             before_version.projection_revision
             after_version.projection_revision)
          "failed outbox commit advanced projection revision";
        (match Database.get_blocks after [ T.block_uuid ] |> T.require_ok ~behavior with
         | [ Missing_block _ ] -> ()
         | _ -> Alcotest.fail "failed outbox commit exposed the pending block");
        Database.release_snapshot after;
        let sync = Database.inspect_sync database |> T.require_ok ~behavior in
        T.require
          (sync_view_submissions sync = [])
          "failed outbox commit exposed a durable submission";
        ignore (Database.close database))))
;;

let submit_persistence_failure_restores_queued_state () =
  let behavior = "submit persistence failure restores queued state" in
  T.with_temp_directory "overlay-submit-failure-" (fun support ->
    let database_path = T.seed_mirror support in
    let dependencies, _location, inspection = location_and_inspection support behavior in
    let opening_inspection = inspection in
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
        let mutation_id =
          match
            T.commit_mutation
              database
              ~expected
              (T.insert_blocks ~ordinal:420 ())
              ~behavior
          with
          | Local_committed commit -> commit.mutation_id
          | Local_existing _ -> Alcotest.fail "fresh submit fixture already existed"
        in
        let queued = Database.inspect_sync database |> T.require_ok ~behavior in
        let prepared, request =
          match
            Database.begin_outbox_transition
              database
              ~expected:(sync_view_token queued)
              (Submit_group [ mutation_id ])
            |> T.require_ok ~behavior
          with
          | prepared, Some request -> prepared, request
          | _ -> Alcotest.fail "submit fixture omitted protection"
        in
        let encrypted =
          Database.protection_plaintexts request
          |> List.map (fun (id, plaintext) -> id, "encrypted:" ^ plaintext)
        in
        let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
        let module Store = Logseq_db_storage.Sync_outbox_store in
        let durable_before = Store.read_database sqlite |> T.require_ok ~behavior in
        let revision_before = Store.read_revision sqlite |> T.require_ok ~behavior in
        Sqlite3.Rc.check
          (Sqlite3.exec
             sqlite
             "CREATE TRIGGER fail_overlay_submit BEFORE INSERT ON sync_outbox BEGIN \
              SELECT RAISE(ABORT, 'injected submit failure'); END");
        T.require (Sqlite3.db_close sqlite) "unable to close submit failure injector";
        (match
           Database.apply_outbox_transition
             database
             prepared
             ~encrypted:(Some (request, encrypted))
         with
         | Error (Outbox_commit_persistence_failed _) -> ()
         | Error _ -> Alcotest.fail "submit failure returned the wrong error"
         | Ok _ -> Alcotest.fail "submit failure exposed a successful transition");
        let after = Database.inspect_sync database |> T.require_ok ~behavior in
        T.require
          (sync_token_equal (sync_view_token queued) (sync_view_token after))
          "failed submit advanced sync token";
        (match sync_view_submissions after with
         | [ descriptor ] when descriptor.state = Queued && descriptor.attempt_count = 0
           -> ()
         | _ -> Alcotest.fail "failed submit did not restore Queued state");
        let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
        Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close sqlite)) (fun () ->
          Alcotest.(check (list string)) "failed submit rolls back durable mutable record"
            durable_before (Store.read_database sqlite |> T.require_ok ~behavior);
          T.require (Store.read_revision sqlite |> T.require_ok ~behavior = revision_before)
            "failed submit rolls back metadata revision";
          Sqlite3.Rc.check (Sqlite3.exec sqlite "DROP TRIGGER fail_overlay_submit");
          let prepared, request = Database.begin_outbox_transition database
              ~expected:(sync_view_token after) (Submit_group [ mutation_id ])
            |> T.require_ok ~behavior in
          let request = Option.get request in
          let encrypted = Database.protection_plaintexts request
            |> List.map (fun (id, plaintext) -> id, "encrypted:" ^ plaintext) in
          let retried = Database.apply_outbox_transition database prepared
              ~encrypted:(Some (request, encrypted)) |> T.require_ok ~behavior in
          T.require (Store.read_database sqlite |> T.require_ok ~behavior <> durable_before)
            "retry after rollback failed to persist its changed frozen baseline";
          let current_revision = Store.read_revision sqlite |> T.require_ok ~behavior |> Option.get in
          T.require (current_revision = Option.get revision_before + 1)
            "successful retry must advance metadata exactly once";
          let durable_after_retry = Store.read_database sqlite |> T.require_ok ~behavior in
          (* A second public storage writer advances only its revision. Database
             owns executing the CAS and must reject its now stale durable baseline. *)
          Sqlite3.Rc.check (Sqlite3.exec sqlite "BEGIN IMMEDIATE");
          Store.apply_delta sqlite
            { expected_revision = current_revision; revision = current_revision + 1
            ; upserts = []; deletes = [] } |> T.require_ok ~behavior;
          Sqlite3.Rc.check (Sqlite3.exec sqlite "COMMIT");
          let submitted_view = Database.inspect_sync database |> T.require_ok ~behavior in
          let batch = Option.get retried.submission_batch in
          let prepared, request = Database.begin_outbox_transition database
              ~expected:(sync_view_token submitted_view)
              (Retry_group (submission_batch_id batch)) |> T.require_ok ~behavior in
          let encrypted = Option.map (fun request -> request,
              Database.protection_plaintexts request
              |> List.map (fun (id, plaintext) -> id, "encrypted:" ^ plaintext)) request in
          (match Database.apply_outbox_transition database prepared ~encrypted with
           | Error (Outbox_commit_persistence_failed _) -> ()
           | _ -> Alcotest.fail "stale durable metadata CAS exposed a successful retry");
          Alcotest.(check (list string)) "metadata CAS failure preserves every payload"
            durable_after_retry (Store.read_database sqlite |> T.require_ok ~behavior);
          T.require (Store.read_revision sqlite |> T.require_ok ~behavior = Some (current_revision + 1))
            "metadata CAS failure overwrote the winning writer revision";
          let after_conflict = Database.inspect_sync database |> T.require_ok ~behavior in
          T.require (sync_token_equal (sync_view_token submitted_view) (sync_view_token after_conflict))
            "metadata CAS failure published an in-memory revision");
        ignore (Database.close database))))
;;

let applied_receipt_survives_reopen () =
  let behavior = "Applied receipt survives close and reopen" in
  let survived =
    T.with_temp_directory "overlay-applied-receipt-reopen-" (fun support ->
      let database_path = T.seed_mirror support in
      let dependencies, location, inspection = location_and_inspection support behavior in
      let opening_inspection = inspection in
      Eio_main.run (fun _environment ->
        Eio.Switch.run (fun sw ->
          let first =
            Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
            |> T.require_ok ~behavior
          in
          let mutation =
            Types.Save_block
              { mutation_id = T.mutation_uuid 430
              ; block = T.authoritative_block_uuid
              ; title = "Authoritative block"
              }
          in
          let local =
            match
              T.commit_mutation
                first
                ~expected:(block_precondition first T.authoritative_block_uuid behavior)
                mutation
                ~behavior
            with
            | Local_committed commit -> commit
            | Local_existing _ -> Alcotest.fail "fresh receipt fixture already existed"
          in
          let sync = Database.inspect_sync first |> T.require_ok ~behavior in
          let submit, protection =
            match
              Database.begin_outbox_transition
                first
                ~expected:(sync_view_token sync)
                (Submit_group [ local.mutation_id ])
              |> T.require_ok ~behavior
            with
            | prepared, Some request -> prepared, request
            | _ -> Alcotest.fail "receipt fixture omitted protection"
          in
          let encrypted =
            Database.protection_plaintexts protection
            |> List.map (fun (id, plaintext) -> id, "encrypted:" ^ plaintext)
          in
          let submitted =
            Database.apply_outbox_transition
              first
              submit
              ~encrypted:(Some (protection, encrypted))
            |> T.require_ok ~behavior
          in
          let batch = Option.get submitted.submission_batch in
          let transaction =
            batch
            |> submission_batch_wires
            |> List.hd
            |> submission_wire_protected_transaction
          in
          let wire =
            transaction
            |> encoded_transaction_of_string ~maximum_bytes:(4 * 1_024 * 1_024)
            |> T.require_ok ~behavior
          in
          let cursor = server_cursor 1 in
          let authoritative_batch =
            authoritative_batch
              ~maximum_count:16
              ~maximum_bytes:(4 * 1_024 * 1_024)
              ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
              ~through:cursor
              ~checksum:None
            |> T.require_ok ~behavior
          in
          let sync = Database.inspect_sync first |> T.require_ok ~behavior in
          let authoritative, request =
            match
              Database.begin_authoritative
                first
                ~expected:(sync_view_token sync)
                authoritative_batch
              |> T.require_ok ~behavior
            with
            | authoritative, Some request -> authoritative, request
            | _ -> Alcotest.fail "protected receipt fixture omitted unprotection"
          in
          let plaintexts =
            Database.unprotection_ciphertexts request
            |> List.map (fun (id, ciphertext) ->
              let prefix = "encrypted:" in
              T.require
                (String.starts_with ~prefix ciphertext)
                "receipt fixture changed its protected envelope";
              let module Transit = Transit_core.Json in
              let module Codec = Transit_native.Transit.Json in
              let encoded =
                String.sub
                  ciphertext
                  (String.length prefix)
                  (String.length ciphertext - String.length prefix)
              in
              match Codec.of_string encoded with
              | Transit.String plaintext -> id, plaintext
              | _ -> Alcotest.fail "receipt plaintext was not a Transit string")
          in
          let application =
            match
              Database.apply_authoritative
                first
                authoritative
                ~decrypted:(Some (request, plaintexts))
              |> T.require_ok ~behavior
            with
            | Authoritative_applied commit -> commit
            | Authoritative_deferred _ ->
              Alcotest.fail "ordinary receipt incorporation was deferred"
          in
          ignore application;
          let sync = Database.inspect_sync first |> T.require_ok ~behavior in
          let accept, _crypto =
            Database.begin_outbox_transition
              first
              ~expected:(sync_view_token sync)
              (Accept_group
                 { batch_id = submission_batch_id batch
                 ; barrier =
                     { through = server_cursor 1; checksum = checksum "0000000000000000" }
                 })
            |> T.require_ok ~behavior
          in
          Database.apply_outbox_transition first accept ~encrypted:None
          |> T.require_ok ~behavior
          |> ignore;
          Database.close first |> T.require_ok ~behavior;
          require_frozen_mutation_receipt
            database_path
            "applied"
            [ "fingerprint"; "formatVersion"; "mutationId"; "outcome" ];
          let refreshed = inspect_mirror location behavior in
          let opening_inspection = refreshed in
          let second =
            Database.open_ ~sw dependencies opening_inspection ~graph_name:"oracle-graph"
            |> T.require_ok ~behavior
          in
          let survived =
            match
              Database.commit_local
                second
                ~expected:(T.empty_precondition ~behavior)
                mutation
            with
            | Ok (Local_existing (Existing_applied duplicate)) ->
              duplicate.status = Already_applied
            | Ok (Local_existing _ | Local_committed _) | Error _ -> false
          in
          let before_duplicate = Database.inspect_sync second |> T.require_ok ~behavior in
          let duplicate, _crypto =
            Database.begin_outbox_transition
              second
              ~expected:(sync_view_token before_duplicate)
              (Accept_group
                 { batch_id = submission_batch_id batch
                 ; barrier =
                     { through = server_cursor 1; checksum = checksum "0000000000000000" }
                 })
            |> T.require_ok ~behavior
          in
          Database.apply_outbox_transition second duplicate ~encrypted:None
          |> T.require_ok ~behavior
          |> ignore;
          let after_duplicate = Database.inspect_sync second |> T.require_ok ~behavior in
          let duplicate_is_idempotent =
            sync_token_equal
              (sync_view_token before_duplicate)
              (sync_view_token after_duplicate)
          in
          Database.close second |> T.require_ok ~behavior;
          survived && duplicate_is_idempotent)))
  in
  T.require survived "reopen lost the terminal Applied receipt"
;;

module Codec = Logseq_db_storage.Logseq_sqlite_codec

let legacy_storage_payloads_roundtrip () =
  let root_content =
    {|{"~:schema":{"~:block/title":{"~:db/valueType":"~:db.type/string"}},"~:max-eid":42,"~:max-tx":536870913,"~:eavt":"10","~:aevt":"11","~:avet":"12","~:duplicate-datoms":[],"~:max-addr":21,"~:branching-factor":32,"~:ref-type":"~:weak","~:index-order-version":1}|}
  in
  let decode content = Codec.decode_storage_payload content |> Result.get_ok in
  let root = decode root_content in
  (match root with
   | Datascript.Storage_root root ->
     T.require (root.storage_schema_idents = []) "legacy root invented schema identities";
     T.require (root.storage_eavt_metadata = None) "legacy root invented counts"
   | _ -> Alcotest.failf "legacy root changed payload kind");
  let payloads =
    [ root
    ; decode {|{"~:keys":[[42,"~:block/title","sample",536870913]]}|}
    ; decode {|{"~:keys":[[42,"~:block/title","sample",536870913]],"~:children":[20,21]}|}
    ]
  in
  List.iter
    (fun payload ->
       let encoded = Codec.encode_storage_payload payload |> Result.get_ok in
       T.require (decode encoded = payload) "legacy payload lost data on roundtrip")
    payloads;
  let branch = List.nth payloads 2 in
  let content, addresses = Codec.encode_physical_payload branch |> Result.get_ok in
  T.require (addresses = [ "20"; "21" ]) "legacy branch address column changed";
  T.require
    (Codec.decode_physical_payload ~content ~addresses |> Result.get_ok = branch)
    "legacy physical branch lost keys/addresses"
;;

let root_schema_identities_and_counts_roundtrip () =
  let sample_schema_attr =
    Datascript.
      { cardinality = Many
      ; unique = Some Identity
      ; indexed = true
      ; is_component = false
      ; no_history = false
      ; doc = Some "sample"
      ; value_type = Some StringType
      ; tuple_attrs = None
      ; tuple_types = None
      }
  in
  let root =
    Datascript.
      { storage_schema = [ "block/title", sample_schema_attr ]
      ; storage_schema_idents = [ 42, "block/title" ]
      ; storage_max_eid = 42
      ; storage_max_tx = 536870913
      ; storage_eavt = "10"
      ; storage_aevt = "11"
      ; storage_avet = "12"
      ; storage_eavt_metadata = Some { storage_index_count = 5; storage_index_shift = 1 }
      ; storage_aevt_metadata = Some { storage_index_count = 5; storage_index_shift = 1 }
      ; storage_avet_metadata = Some { storage_index_count = 3; storage_index_shift = 0 }
      ; storage_duplicate_datoms = []
      ; storage_max_addr = 12
      ; storage_branching_factor = 32
      ; storage_ref_type = Persistent_sorted_set.Weak
      }
  in
  let encoded = Codec.encode_storage_payload (Storage_root root) |> Result.get_ok in
  let decoded = Codec.decode_storage_payload encoded |> Result.get_ok in
  T.require (decoded = Datascript.Storage_root root) "root identities/counts lost";
  let metadata = Codec.decode_root_index_metadata encoded |> Result.get_ok in
  T.require (metadata.eavt = { count = 5; shift = 1 }) "root EAVT count changed";
  T.require (metadata.avet = { count = 3; shift = 0 }) "root AVET count changed";
  match Codec.decode_transit encoded |> Result.get_ok with
  | Transit_core.Json.Map entries ->
    T.require
      (List.mem
         (Transit_core.Json.Keyword "index-order-version", Transit_core.Json.Int 1)
         entries)
      "legacy Journal order marker disappeared"
  | _ -> Alcotest.failf "root changed Transit representation"
;;

let storage_address_reuse_survives_commit_or_rollback ~fail_commit () =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Session = Logseq_db_storage.Storage_session in
  let behavior = "public storage address reuse and legacy reopen" in
  T.with_temp_directory "storage-api-compat-" (fun directory ->
    let path = Filename.concat directory "mirror.sqlite" in
    T.copy_storage_fixture path;
    let physical_rows () =
      let sqlite = Sqlite3.db_open ~mode:`READONLY path in
      Fun.protect
        ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
        (fun () ->
           let rows = ref [] in
           Sqlite3.Rc.check
             (Sqlite3.exec
                sqlite
                "SELECT addr, content, addresses FROM kvs ORDER BY addr"
                ~cb:(fun row _ -> rows := Array.to_list row :: !rows));
           List.rev !rows)
    in
    let rows_before = physical_rows () in
    let connection = Storage.open_database path |> T.require_ok ~behavior in
    let base_callbacks = Storage.connection_callbacks connection in
    let before = Storage.restore_database connection |> T.require_ok ~behavior in
    let before_datoms = Datascript.datoms before Datascript.Eavt () |> List.of_seq in
    let root =
      match base_callbacks.storage.storage_restore Datascript.Storage.root_address with
      | Some (Datascript.Storage_root root) -> root
      | _ -> Alcotest.fail "legacy fixture has no root"
    in
    let old_addresses = Hashtbl.create 128 in
    List.iter
      (fun address -> Hashtbl.replace old_addresses address ())
      (base_callbacks.storage.storage_list_addresses ());
    let staged_writes = ref [] in
    let applied_writes = ref 0 in
    let reused_node_written = ref false in
    let callbacks =
      { base_callbacks with
        finish_staging =
          (fun metadata extras ->
            Result.map
              (fun (batch : Storage.batch) ->
                 staged_writes := batch.writes;
                 batch)
              (base_callbacks.finish_staging metadata extras))
      ; upsert =
          (fun write ->
            incr applied_writes;
            if fail_commit && !reused_node_written
            then Error "injected compatibility rollback"
            else (
              let result = base_callbacks.upsert write in
              (match result with
               | Ok ()
                 when write.address <> Datascript.Storage.root_address
                      && write.address <> Datascript.Storage.tail_address
                      && Hashtbl.mem old_addresses write.address ->
                 reused_node_written := true
               | Ok () | Error _ -> ());
              result))
      }
    in
    let session =
      Session.create
        ~tail:(Datascript.Storage.restore_tail_groups callbacks.storage)
        ~callbacks
    in
    let identity_entity = root.storage_max_eid + 1 in
    let identity = "journal.compat/value" in
    let ops =
      Datascript.Add (Entity_id identity_entity, "db/ident", Keyword identity)
      :: List.init (root.storage_branching_factor + 1) (fun index ->
        Datascript.Add
          ( Entity_id (identity_entity + index + 1)
          , "block/title"
          , String ("Compatibility " ^ string_of_int index) ))
    in
    let staged =
      Session.stage_transact session ~authoritative_before:before ops
      |> T.require_ok ~behavior
    in
    T.require (physical_rows () = rows_before) "staging changed legacy disk rows";
    T.require
      (List.exists
         (fun (write : Storage.write) ->
            write.address <> Datascript.Storage.root_address
            && write.address <> Datascript.Storage.tail_address
            && Hashtbl.mem old_addresses write.address)
         !staged_writes)
      "compaction did not exercise existing node address reuse";
    let expected_after =
      Session.staged_db_after staged
      |> fun database -> Datascript.datoms database Datascript.Eavt () |> List.of_seq
    in
    (match Session.commit_staged session staged with
     | Error (Session.Persistence_failed _) when fail_commit ->
       T.require
         (!applied_writes >= 4 && !reused_node_written)
         "failure did not follow a successful SQL rewrite of an existing node";
       T.require (Session.is_fatal session) "failed commit was not terminal";
       T.require (physical_rows () = rows_before) "rollback changed legacy rows"
     | Ok () when not fail_commit -> ()
     | _ -> Alcotest.fail "unexpected compatibility commit result");
    Session.close session |> T.require_ok ~behavior;
    let reopened = Storage.open_database path |> T.require_ok ~behavior in
    Fun.protect
      ~finally:(fun () ->
        Storage.close (Storage.connection_callbacks reopened) |> T.require_ok ~behavior)
      (fun () ->
         let restored = Storage.restore_database reopened |> T.require_ok ~behavior in
         let expected = if fail_commit then before_datoms else expected_after in
         let actual = Datascript.datoms restored Datascript.Eavt () |> List.of_seq in
         T.require (actual = expected) "legacy reopen lost or changed datoms";
         T.require
           (Datascript.schema restored = Datascript.schema before)
           "reopen changed schema";
         if not fail_commit
         then (
           let callbacks = Storage.connection_callbacks reopened in
           (match callbacks.storage.storage_restore Datascript.Storage.root_address with
            | Some (Datascript.Storage_root root) ->
              T.require
                (List.mem (identity_entity, identity) root.storage_schema_idents)
                "compaction lost schema identity metadata";
              T.require
                (Persistent_sorted_set.count restored.Datascript.eavt_index
                 + List.length restored.duplicate_datoms
                 = List.length actual)
                "restore snapshot count disagrees with datoms"
            | _ -> Alcotest.fail "committed root missing");
           Storage.garbage_stats callbacks |> T.require_ok ~behavior |> ignore)))
;;

(* The SQL write set is owned by Database persistence, not a pure reducer.
   Public Database operations below reproduce the defect; SQLite triggers only
   observe their committed durable row changes. *)
let with_outbox_write_fixture behavior f =
  T.with_temp_directory "overlay-incremental-outbox-" (fun support ->
    let path = T.seed_mirror support in
    let dependencies, _, inspection = location_and_inspection support behavior in
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let database =
          Database.open_ ~sw dependencies inspection ~graph_name:"write-set-fixture"
          |> T.require_ok ~behavior
        in
        let sqlite = Sqlite3.db_open ~mode:`NO_CREATE path in
        Sqlite3.Rc.check
          (Sqlite3.exec sqlite
             "CREATE TABLE outbox_write_audit (kind TEXT NOT NULL, payload_bytes INTEGER NOT NULL); \
              CREATE TRIGGER audit_outbox_insert AFTER INSERT ON sync_outbox BEGIN \
              INSERT INTO outbox_write_audit VALUES('insert', length(CAST(NEW.record AS BLOB))); END; \
              CREATE TRIGGER audit_outbox_update AFTER UPDATE ON sync_outbox BEGIN \
              INSERT INTO outbox_write_audit VALUES('update', length(CAST(NEW.record AS BLOB))); END; \
              CREATE TRIGGER audit_outbox_delete AFTER DELETE ON sync_outbox BEGIN \
              INSERT INTO outbox_write_audit VALUES('delete', 0); END");
        Fun.protect
          ~finally:(fun () ->
            ignore (Sqlite3.db_close sqlite);
            ignore (Database.close database))
          (fun () -> f ~sw ~dependencies ~support ~path ~sqlite database))))
;;

let outbox_write_count sqlite =
  let count = ref 0 in
  Sqlite3.Rc.check
    (Sqlite3.exec sqlite "SELECT count(*) FROM outbox_write_audit"
       ~cb:(fun row _ -> count := int_of_string (Option.get row.(0))));
  !count
;;

let outbox_payload_bytes sqlite =
  let count = ref 0 in
  Sqlite3.Rc.check
    (Sqlite3.exec sqlite "SELECT coalesce(sum(payload_bytes),0) FROM outbox_write_audit"
       ~cb:(fun row _ -> count := int_of_string (Option.get row.(0))));
  !count
;;

let reset_outbox_write_count sqlite =
  Sqlite3.Rc.check (Sqlite3.exec sqlite "DELETE FROM outbox_write_audit")
;;

let persisted_outbox sqlite behavior =
  Logseq_db_storage.Sync_outbox_store.read_database sqlite |> T.require_ok ~behavior
;;

let append_outbox_save database ordinal behavior =
  let mutation =
    Save_block
      { mutation_id = T.mutation_uuid (10_000 + ordinal)
      ; block = T.authoritative_block_uuid
      ; title = Printf.sprintf "Incremental edit %d" ordinal
      }
  in
  let commit =
    match
      Database.commit_local database
        ~expected:(block_precondition database T.authoritative_block_uuid behavior)
        mutation
      |> T.require_ok ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh outbox write fixture reused an identity"
  in
  mutation, commit
;;

let apply_outbox_event database transition behavior =
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, request =
    Database.begin_outbox_transition database ~expected:(sync_view_token view) transition
    |> T.require_ok ~behavior
  in
  let encrypted =
    Option.map
      (fun request ->
        request,
        Database.protection_plaintexts request
        |> List.map (fun (id, plaintext) -> id, "encrypted:" ^ plaintext))
      request
  in
  Database.apply_outbox_transition database prepared ~encrypted |> T.require_ok ~behavior
;;

let incremental_outbox_appends count () =
  let behavior = Printf.sprintf "incremental outbox appends %d" count in
  with_outbox_write_fixture behavior
    (fun ~sw:_ ~dependencies:_ ~support:_ ~path:_ ~sqlite database ->
      for ordinal = 1 to count do
        ignore (append_outbox_save database ordinal behavior)
      done;
      Alcotest.(check int) "one durable row write per appended intent" count
        (outbox_write_count sqlite);
      let stored = persisted_outbox sqlite behavior in
      Alcotest.(check int) "all intents recover in order" count (List.length stored);
      let final_bytes = List.fold_left (fun total record -> total + String.length record) 0 stored in
      Alcotest.(check int) "each appended payload is persisted exactly once" final_bytes
        (outbox_payload_bytes sqlite);
      Printf.printf "outbox append N=%d committed_row_changes=%d logical_payload_bytes=%d final_payload_bytes=%d\n%!"
        count (outbox_write_count sqlite) (outbox_payload_bytes sqlite) final_bytes)
;;

let incremental_outbox_preserves_unchanged_rows () =
  let behavior = "incremental outbox preserves unchanged rows" in
  with_outbox_write_fixture behavior
    (fun ~sw:_ ~dependencies:_ ~support:_ ~path:_ ~sqlite database ->
      ignore (append_outbox_save database 1 behavior);
      let before = List.hd (persisted_outbox sqlite behavior) in
      ignore (append_outbox_save database 2 behavior);
      Alcotest.(check string) "unrelated revision does not reencode prior payload" before
        (List.hd (persisted_outbox sqlite behavior)))
;;

let incremental_outbox_no_change_and_identity () =
  let behavior = "incremental outbox No_change and identity" in
  with_outbox_write_fixture behavior
    (fun ~sw:_ ~dependencies:_ ~support:_ ~path:_ ~sqlite database ->
      let mutation, _ = append_outbox_save database 1 behavior in
      for ordinal = 2 to 32 do
        ignore (append_outbox_save database ordinal behavior)
      done;
      reset_outbox_write_count sqlite;
      let no_change =
        Save_block
          { mutation_id = T.mutation_uuid 20_001
          ; block = T.block_uuid
          ; title = "Missing target"
          }
      in
      (match Database.commit_local database
               ~expected:(block_precondition database T.block_uuid behavior) no_change
             |> T.require_ok ~behavior with
       | Local_committed { status = No_change; _ } -> ()
       | _ -> Alcotest.fail "missing target must produce a durable No_change receipt");
      (match Database.commit_local database ~expected:(T.empty_precondition ~behavior) mutation
             |> T.require_ok ~behavior with
       | Local_existing _ -> ()
       | _ -> Alcotest.fail "same-ID replay appended another intent");
      (match Database.commit_local database ~expected:(T.empty_precondition ~behavior)
               (Save_block { mutation_id = T.mutation_uuid 10_001
                           ; block = T.authoritative_block_uuid; title = "Different intent" }) with
       | Error Mutation_identity_conflict -> ()
       | _ -> Alcotest.fail "same-ID different intent must remain a conflict");
      Alcotest.(check int) "receipt and identity checks do not rewrite outbox rows" 0
        (outbox_write_count sqlite))
;;

let incremental_outbox_batch_updates () =
  let behavior = "incremental outbox batch updates" in
  with_outbox_write_fixture behavior
    (fun ~sw:_ ~dependencies:_ ~support:_ ~path:_ ~sqlite database ->
      let commits = List.init 64 (fun n -> snd (append_outbox_save database (n + 1) behavior)) in
      let ids = List.take 32 commits |> List.map (fun (commit : local_commit) -> commit.mutation_id) in
      reset_outbox_write_count sqlite;
      let submitted = apply_outbox_event database (Submit_group ids) behavior in
      Alcotest.(check int) "submit persists its members only" 32 (outbox_write_count sqlite);
      let batch = Option.get submitted.submission_batch in
      reset_outbox_write_count sqlite;
      ignore
        (apply_outbox_event database
           (Accept_group
              { batch_id = submission_batch_id batch
              ; barrier = { through = server_cursor 32; checksum = checksum "0000000000000000" }
              }) behavior);
      Alcotest.(check int) "accept persists its members only" 32 (outbox_write_count sqlite);
      let stored = persisted_outbox sqlite behavior in
      let view = Database.inspect_sync database |> T.require_ok ~behavior in
      Alcotest.(check int) "mutable transport updates remain durable" 32
        (List.fold_left
           (fun count descriptor -> match descriptor.state with
             | Accepted_pending_authoritative _ -> count + 1 | _ -> count)
           0 (sync_view_submissions view));
      Alcotest.(check int) "other queued rows remain present" 64 (List.length stored))
;;

let reject_and_discard database (commit : local_commit) behavior =
  let submitted = apply_outbox_event database (Submit_group [ commit.mutation_id ]) behavior in
  let batch = Option.get submitted.submission_batch in
  ignore
    (apply_outbox_event database
       (Reject_group
          { batch_id = submission_batch_id batch
          ; resolution = Definitive
              { reason = Invalid_request
              ; partition = { accepted_prefix = []; failed_member = Some commit.mutation_id
                            ; unexecuted_suffix = []; acceptance_barrier = None
                            ; missing_uuids = []; diagnostics = [] }
              }
          }) behavior);
  Database.discard_blocked database ~mutation_id:commit.mutation_id |> T.require_ok ~behavior |> ignore
;;

let incremental_outbox_middle_delete_and_empty_revision () =
  let behavior = "incremental outbox middle delete and empty revision" in
  with_outbox_write_fixture behavior
    (fun ~sw ~dependencies ~support ~path:_ ~sqlite database ->
      let commits = List.init 3 (fun n -> snd (append_outbox_save database (n + 1) behavior)) in
      let middle = List.nth commits 1 in
      let submitted = apply_outbox_event database (Submit_group [ middle.mutation_id ]) behavior in
      let batch = Option.get submitted.submission_batch in
      ignore (apply_outbox_event database
                (Reject_group { batch_id = submission_batch_id batch
                              ; resolution = Definitive
                                  { reason = Invalid_request
                                  ; partition = { accepted_prefix = []; failed_member = Some middle.mutation_id
                                                ; unexecuted_suffix = []; acceptance_barrier = None
                                                ; missing_uuids = []; diagnostics = [] } } }) behavior);
      let before = persisted_outbox sqlite behavior in
      reset_outbox_write_count sqlite;
      Database.discard_blocked database ~mutation_id:middle.mutation_id |> T.require_ok ~behavior |> ignore;
      Alcotest.(check int) "middle discard deletes one row" 1 (outbox_write_count sqlite);
      Alcotest.(check (list string)) "remaining sequence holes and payloads are stable"
        [ List.nth before 0; List.nth before 2 ] (persisted_outbox sqlite behavior);
      reject_and_discard database (List.nth commits 0) behavior;
      reject_and_discard database (List.nth commits 2) behavior;
      let before_reopen = Database.inspect_sync database |> T.require_ok ~behavior in
      Database.close database |> T.require_ok ~behavior;
      let inspection = inspect_mirror support behavior in
      let reopened = Database.open_ ~sw dependencies inspection ~graph_name:"empty-queue"
                     |> T.require_ok ~behavior in
      let after_reopen = Database.inspect_sync reopened |> T.require_ok ~behavior in
      T.require (sync_token_equal (sync_view_token before_reopen) (sync_view_token after_reopen))
        "empty durable queue lost its independent sync revision";
      Database.close reopened |> T.require_ok ~behavior)
;;

let incremental_outbox_empty_revision () =
  let behavior = "incremental outbox empty revision" in
  with_outbox_write_fixture behavior
    (fun ~sw ~dependencies ~support ~path:_ ~sqlite:_ database ->
      let _, commit = append_outbox_save database 1 behavior in
      reject_and_discard database commit behavior;
      let before = Database.inspect_sync database |> T.require_ok ~behavior in
      Database.close database |> T.require_ok ~behavior;
      let reopened = Database.open_ ~sw dependencies (inspect_mirror support behavior)
                       ~graph_name:"empty-revision" |> T.require_ok ~behavior in
      let after = Database.inspect_sync reopened |> T.require_ok ~behavior in
      T.require (sync_token_equal (sync_view_token before) (sync_view_token after))
        "empty queue must retain its durable sync revision";
      Database.close reopened |> T.require_ok ~behavior)
;;

let incremental_outbox_unrelated_authoritative () =
  let behavior = "incremental outbox unrelated authoritative" in
  with_outbox_write_fixture behavior
    (fun ~sw:_ ~dependencies:_ ~support:_ ~path:_ ~sqlite database ->
      let commits = List.init 32 (fun n -> snd (append_outbox_save database (n + 1) behavior)) in
      let ids = List.map (fun (commit : local_commit) -> commit.mutation_id) commits in
      ignore (apply_outbox_event database (Submit_group ids) behavior);
      let before = persisted_outbox sqlite behavior in
      reset_outbox_write_count sqlite;
      let module Transit = Transit_core.Json in
      let module Codec = Transit_native.Transit.Json in
      let wire =
        Transit.Array
          [ Transit.Array
              [ Transit.Keyword "db/add"
              ; Transit.Array [ Transit.Keyword "block/uuid"
                              ; Transit.Uuid (Logseq_db_types.Graph_types.Uuid.to_string T.page_uuid) ]
              ; Transit.Keyword "audit/unrelated"
              ; Transit.Int 1 ] ]
        |> Codec.to_string ~mode:Codec.Verbose
        |> encoded_transaction_of_string ~maximum_bytes:4096 |> T.require_ok ~behavior
      in
      let batch = authoritative_batch ~maximum_count:16 ~maximum_bytes:4096
                    ~transactions:[ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
                    ~through:(server_cursor 1) ~checksum:None |> T.require_ok ~behavior in
      let view = Database.inspect_sync database |> T.require_ok ~behavior in
      let prepared, request = Database.begin_authoritative database
                                ~expected:(sync_view_token view) batch |> T.require_ok ~behavior in
      T.require (Option.is_none request) "unrelated transaction unexpectedly needs crypto";
      (match Database.apply_authoritative database prepared ~decrypted:None |> T.require_ok ~behavior with
       | Authoritative_applied _ -> ()
       | _ -> Alcotest.fail "unrelated authoritative batch was deferred");
      Alcotest.(check int) "unrelated checkpoint does not rewrite frozen submissions" 0
        (outbox_write_count sqlite);
      Alcotest.(check (list string)) "frozen submission payloads survive unchanged" before
        (persisted_outbox sqlite behavior))
;;

let incremental_outbox_legacy_migration () =
  let behavior = "incremental outbox legacy migration" in
  with_outbox_write_fixture behavior
    (fun ~sw ~dependencies ~support ~path:_ ~sqlite database ->
      ignore (append_outbox_save database 1 behavior);
      ignore (append_outbox_save database 2 behavior);
      let records = persisted_outbox sqlite behavior in
      Database.close database |> T.require_ok ~behavior;
      Sqlite3.Rc.check (Sqlite3.exec sqlite
        "DROP TABLE sync_outbox; DROP TABLE IF EXISTS sync_outbox_metadata; \
         CREATE TABLE sync_outbox(position INTEGER PRIMARY KEY, record TEXT NOT NULL)");
      let legacy = List.map
        (fun record -> match Yojson.Safe.from_string record with
          | `Assoc fields -> `Assoc (("syncRevision", `Int 57) :: List.remove_assoc "syncRevision" fields)
                            |> Yojson.Safe.to_string
          | _ -> Alcotest.fail "legacy fixture omitted record JSON") records in
      Logseq_db_storage.Sync_outbox_store.replace_database sqlite legacy |> T.require_ok ~behavior;
      let inspection = inspect_mirror support behavior in
      let reopened = Database.open_ ~sw dependencies inspection ~graph_name:"legacy-queue"
                     |> T.require_ok ~behavior in
      let view = Database.inspect_sync reopened |> T.require_ok ~behavior in
      let expected = sync_token_of_string "sync-token:v1:57" |> T.require_ok ~behavior in
      T.require (sync_token_equal expected (sync_view_token view)) "legacy migration lost global revision";
      ignore (append_outbox_save reopened 3 behavior);
      Database.close reopened |> T.require_ok ~behavior;
      let again = Database.open_ ~sw dependencies (inspect_mirror support behavior)
                    ~graph_name:"migrated-queue" |> T.require_ok ~behavior in
      Alcotest.(check int) "migrated and new mutations all recover" 3
        (List.length (sync_view_submissions (Database.inspect_sync again |> T.require_ok ~behavior)));
      T.require
        (sync_token_equal (sync_token_of_string "sync-token:v1:58" |> T.require_ok ~behavior)
           (sync_view_token (Database.inspect_sync again |> T.require_ok ~behavior)))
        "migrated metadata did not advance atomically";
      Database.close again |> T.require_ok ~behavior)
;;

let incremental_outbox_migration_writer_lock () =
  let behavior = "incremental outbox migration writer lock" in
  with_outbox_write_fixture behavior
    (fun ~sw ~dependencies ~support ~path:_ ~sqlite database ->
      ignore (append_outbox_save database 1 behavior);
      let legacy = persisted_outbox sqlite behavior in
      Database.close database |> T.require_ok ~behavior;
      Sqlite3.Rc.check (Sqlite3.exec sqlite
        "DROP TABLE sync_outbox; DROP TABLE IF EXISTS sync_outbox_metadata; \
         CREATE TABLE sync_outbox(position INTEGER PRIMARY KEY, record TEXT NOT NULL)");
      Logseq_db_storage.Sync_outbox_store.replace_database sqlite legacy |> T.require_ok ~behavior;
      Sqlite3.Rc.check (Sqlite3.exec sqlite "BEGIN IMMEDIATE");
      Fun.protect ~finally:(fun () -> Sqlite3.Rc.check (Sqlite3.exec sqlite "ROLLBACK"))
        (fun () -> match Database.open_ ~sw dependencies (inspect_mirror support behavior)
                           ~graph_name:"locked-migration" with
          | Error _ -> ()
          | Ok opened -> ignore (Database.close opened);
                         Alcotest.fail "write-required migration succeeded under another writer lock");
      Alcotest.(check (list string)) "failed migration retains complete legacy rows" legacy
        (persisted_outbox sqlite behavior);
      let reopened = Database.open_ ~sw dependencies (inspect_mirror support behavior)
                       ~graph_name:"migration-retry" |> T.require_ok ~behavior in
      Alcotest.(check int) "migration retries without losing a row" 1
        (List.length (sync_view_submissions (Database.inspect_sync reopened |> T.require_ok ~behavior)));
      Database.close reopened |> T.require_ok ~behavior)
;;

(* Database ownership cannot interpose a writer between its read and migration
   through a pure event. Exercise the public storage migration at that boundary. *)
let incremental_outbox_migration_rejects_stale_rows () =
  let behavior = "incremental outbox migration rejects stale rows" in
  with_outbox_write_fixture behavior
    (fun ~sw:_ ~dependencies:_ ~support:_ ~path:_ ~sqlite database ->
      ignore (append_outbox_save database 1 behavior);
      ignore (append_outbox_save database 2 behavior);
      let all_records = persisted_outbox sqlite behavior in
      Database.close database |> T.require_ok ~behavior;
      Sqlite3.Rc.check (Sqlite3.exec sqlite
        "DROP TABLE sync_outbox; DROP TABLE sync_outbox_metadata; \
         CREATE TABLE sync_outbox(position INTEGER PRIMARY KEY, record TEXT NOT NULL)");
      let module Store = Logseq_db_storage.Sync_outbox_store in
      Store.replace_database sqlite [ List.hd all_records ] |> T.require_ok ~behavior;
      let validated = Store.read_database sqlite |> T.require_ok ~behavior in
      let rows_of records = List.map
          (fun record ->
             let open Yojson.Safe.Util in
             let json = Yojson.Safe.from_string record in
             Store.{ mutation_id = json |> member "mutation" |> member "mutationId" |> to_string
                   ; sequence = json |> member "sequence" |> to_int
                   ; record }) records in
      let rows = rows_of validated in
      Store.replace_database sqlite all_records |> T.require_ok ~behavior;
      (match Store.migrate_database sqlite ~revision:0 ~expected_records:validated rows with
       | Error _ -> ()
       | Ok () -> Alcotest.fail "migration discarded a row added after its validated snapshot");
      Alcotest.(check (list string)) "stale migration preserves all later rows" all_records
        (Store.read_database sqlite |> T.require_ok ~behavior);
      T.require (Store.read_revision sqlite |> T.require_ok ~behavior = None)
        "stale migration must roll back its format change";
      Store.migrate_database sqlite ~revision:0 ~expected_records:all_records (rows_of all_records)
      |> T.require_ok ~behavior;
      (match Store.migrate_database sqlite ~revision:0 ~expected_records:validated rows with
       | Error _ -> ()
       | Ok () -> Alcotest.fail "matching revision concealed stale incremental rows");
      Alcotest.(check (list string)) "incremental stale restore preserves all rows" all_records
        (Store.read_database sqlite |> T.require_ok ~behavior))
;;

let cases =
  [ Alcotest.test_case "incremental outbox appends 1" `Quick (incremental_outbox_appends 1)
  ; Alcotest.test_case "incremental outbox appends 32" `Quick (incremental_outbox_appends 32)
  ; Alcotest.test_case "incremental outbox appends 1000" `Quick (incremental_outbox_appends 1000)
  ; Alcotest.test_case "incremental outbox unchanged rows" `Quick incremental_outbox_preserves_unchanged_rows
  ; Alcotest.test_case "incremental outbox No_change and identity" `Quick incremental_outbox_no_change_and_identity
  ; Alcotest.test_case "incremental outbox batch updates" `Quick incremental_outbox_batch_updates
  ; Alcotest.test_case "incremental outbox middle delete and empty revision" `Quick incremental_outbox_middle_delete_and_empty_revision
  ; Alcotest.test_case "incremental outbox legacy migration" `Quick incremental_outbox_legacy_migration
  ; Alcotest.test_case "incremental outbox empty revision" `Quick incremental_outbox_empty_revision
  ; Alcotest.test_case "incremental outbox unrelated authoritative" `Quick incremental_outbox_unrelated_authoritative
  ; Alcotest.test_case "incremental outbox migration writer lock" `Quick incremental_outbox_migration_writer_lock
  ; Alcotest.test_case "incremental outbox migration rejects stale rows" `Quick incremental_outbox_migration_rejects_stale_rows
  ; Alcotest.test_case
      "legacy storage payloads roundtrip"
      `Quick
      legacy_storage_payloads_roundtrip
  ; Alcotest.test_case
      "root schema identities and counts roundtrip"
      `Quick
      root_schema_identities_and_counts_roundtrip
  ; Alcotest.test_case
      "storage reused addresses commit and reopen"
      `Quick
      (storage_address_reuse_survives_commit_or_rollback ~fail_commit:false)
  ; Alcotest.test_case
      "storage reused addresses rollback and reopen"
      `Quick
      (storage_address_reuse_survives_commit_or_rollback ~fail_commit:true)
  ; Alcotest.test_case
      "dependency construction validates every limit"
      `Quick
      dependency_construction_validates_every_limit
  ; Alcotest.test_case
      "snapshot input validation is fail closed"
      `Quick
      snapshot_input_validation_is_fail_closed
  ; Alcotest.test_case
      "snapshot activation installs a queryable mirror"
      `Quick
      snapshot_activation_installs_queryable_mirror
  ; Alcotest.test_case
      "snapshot cancellation removes temporary artifacts"
      `Quick
      canceled_snapshot_activation_removes_temporary_artifacts
  ; Alcotest.test_case
      "snapshot crypto results are validated before staging"
      `Quick
      snapshot_crypto_results_are_validated_before_staging
  ; Alcotest.test_case
      "stale snapshot inspection cannot replace a mirror"
      `Quick
      stale_snapshot_inspection_cannot_replace_mirror
  ; Alcotest.test_case
      "snapshot commit is single-use"
      `Quick
      snapshot_commit_is_single_use
  ; Alcotest.test_case
      "snapshot checksum independent vectors"
      `Quick
      checksum_vectors_preserve_snapshot_semantics
  ; Alcotest.test_case
      "unused preparation checksum defers invalid UTF-8"
      `Quick
      unused_preparation_checksum_defers_invalid_utf8_without_publication
  ; Alcotest.test_case
      "snapshot checksum mismatch fails before activation"
      `Quick
      snapshot_checksum_mismatch_fails_before_activation
  ; Alcotest.test_case
      "mirror inspection is generation-bound"
      `Quick
      available_mirror_is_generation_bound
  ; Alcotest.test_case
      "inspect and open validation is fail closed"
      `Quick
      inspect_and_open_validation_is_fail_closed
  ; Alcotest.test_case
      "snapshot publication failure is retryable"
      `Quick
      snapshot_publication_failure_is_retryable
  ; Alcotest.test_case
      "stale snapshot commit can be canceled"
      `Quick
      stale_snapshot_commit_can_be_canceled
  ; Alcotest.test_case
      "stale delete cannot remove replacement"
      `Quick
      stale_delete_cannot_remove_replacement
  ; Alcotest.test_case "corrupt outbox fails closed" `Quick corrupt_outbox_fails_closed
  ; Alcotest.test_case
      "persistence outbox uses frozen V16 JSON"
      `Quick
      persistence_outbox_uses_frozen_v16_json
  ; Alcotest.test_case
      "duplicate outbox member fails closed"
      `Quick
      duplicate_outbox_member_fails_closed
  ; Alcotest.test_case
      "noncanonical outbox payload fails closed"
      `Quick
      noncanonical_outbox_payload_fails_closed
  ; Alcotest.test_case
      "inconsistent origin evidence fails closed"
      `Quick
      inconsistent_origin_evidence_fails_closed
  ; Alcotest.test_case
      "garbage collection preserves receipt ledgers"
      `Quick
      garbage_collection_preserves_receipt_ledgers
  ; Alcotest.test_case
      "close and reopen preserve projection"
      `Quick
      close_then_reopen_preserves_projection
  ; Alcotest.test_case
      "pending outbox survives reopen"
      `Quick
      pending_outbox_survives_reopen
  ; Alcotest.test_case
      "submitted dependency shadow survives reopen"
      `Quick
      submitted_dependency_shadow_survives_reopen
  ; Alcotest.test_case "open owns graph exclusively" `Quick open_owns_graph_exclusively
  ; Alcotest.test_case
      "No_change receipt survives reopen"
      `Quick
      no_change_receipt_survives_reopen
  ; Alcotest.test_case
      "authoritative checkpoint and root survive reopen"
      `Quick
      authoritative_checkpoint_and_root_survive_reopen
  ; Alcotest.test_case
      "outbox persistence failure is atomic"
      `Quick
      outbox_persistence_failure_is_atomic
  ; Alcotest.test_case
      "submit persistence failure restores queued state"
      `Quick
      submit_persistence_failure_restores_queued_state
  ; Alcotest.test_case
      "Applied receipt survives reopen"
      `Quick
      applied_receipt_survives_reopen
  ]
;;

let () = Alcotest.run "logseq_overlay_db storage" [ "mirror and durability", cases ]
