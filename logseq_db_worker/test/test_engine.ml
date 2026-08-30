module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module P = Logseq_db_worker.Protocol
module Engine = Logseq_db_worker.Engine

let open_engine fixture =
  match Engine.open_ ~dependencies:F.dependencies fixture.F.config with
  | Ok engine -> engine
  | Error error -> T.fail "Engine open failed: %s" (Logseq_db_worker.Error.message error)
;;

let graph_info engine =
  match Engine.execute engine (F.graph_info_request ()) with
  | P.Succeeded { basis; success = Graph_info_result graph; _ } -> basis, graph
  | _ -> T.fail "Engine Graph_info failed"
;;

let mutation basis =
  F.create_page_request
    ~basis
    ~request_id:"61000000-0000-4000-8000-000000000001"
    ~mutation_id:"62000000-0000-4000-8000-000000000001"
    ~page_uuid:"63000000-0000-4000-8000-000000000001"
    ~title:"Engine lifecycle page"
;;

let mutation_result = function
  | P.Succeeded { success = Mutation_result result; _ } -> result
  | _ -> T.fail "Engine mutation failed"
;;

let test_graph_info_reports_admission_and_mode () =
  F.with_snapshot (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis, graph = graph_info engine in
         T.require (basis >= 0L) "Engine reported a negative basis";
         T.require
           (graph.Logseq_db_types.Graph_types.mode = Snapshot)
           "snapshot Engine did not report exclusive snapshot mode";
         T.require
           (List.mem Logseq_db_types.Graph_types.Ownership_verified graph.admission_facts)
           "Engine omitted verified ownership from admission facts";
         T.require
           (List.exists
              (function
                | Logseq_db_types.Graph_types.Compatible_schema
                    { minimum = { major = 65; minor = 33 }
                    ; actual = { major = 65; minor }
                    }
                  when minor >= 33 -> true
                | _ -> false)
              graph.admission_facts)
           "Engine omitted the >= 65.33 admission fact"))
;;

let test_basis_conflict_is_typed_and_non_mutating () =
  F.with_snapshot (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis, _ = graph_info engine in
         let request = mutation (Int64.pred basis) in
         (match Engine.execute engine request with
          | P.Failed { phase = Execute; basis = Some actual; error; _ } ->
            T.require (Int64.equal actual basis) "conflict omitted current basis";
            T.require
              (Logseq_db_worker.Error.code error = Conflict)
              "basis mismatch did not return Conflict"
          | _ -> T.fail "basis mismatch was not a typed execute failure");
         T.require (Engine.basis engine = Some basis) "rejected mutation advanced basis"))
;;

let test_live_mutation_cache_is_idempotent () =
  F.with_snapshot (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis, _ = graph_info engine in
         let request = mutation basis in
         let first = Engine.execute engine request |> mutation_result in
         let second = Engine.execute engine request |> mutation_result in
         T.require (first.status = Applied) "first mutation was not applied";
         T.require (first = second) "live mutation cache changed the receipt";
         T.require
           (Engine.basis engine = Some first.basis_after)
           "idempotent replay advanced Engine basis"))
;;

let test_live_mutation_cache_rejects_reused_id_for_different_content () =
  F.with_snapshot (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis, _ = graph_info engine in
         let first = Engine.execute engine (mutation basis) |> mutation_result in
         let changed =
           F.create_page_request
             ~basis
             ~request_id:"61000000-0000-4000-8000-000000000002"
             ~mutation_id:"62000000-0000-4000-8000-000000000001"
             ~page_uuid:"63000000-0000-4000-8000-000000000001"
             ~title:"Different Engine lifecycle page"
         in
         (match Engine.execute engine changed with
          | P.Failed { phase = Execute; error; _ } ->
            T.require
              (Logseq_db_worker.Error.code error = Conflict)
              "reused mutation ID returned the wrong error"
          | _ -> T.fail "reused mutation ID with different content was accepted");
         T.require
           (Engine.basis engine = Some first.basis_after)
           "rejected mutation ID reuse advanced Engine basis"))
;;

let managed_scope graph_id =
  let account : Logseq_sync_pure_reducer.Core.account_scope =
    { managed_sync_origin = Uri.of_string "https://api.logseq.io"
    ; user_id = "user-1"
    ; account_generation = 1
    ; presentation_generation = 1
    ; lifecycle_generation = 1L
    }
  in
  Logseq_sync_pure_reducer.Core.{ account; graph_id; graph_generation = 1 }
;;

let test_capture_managed_outbox_uses_shared_identity_and_round_trips () =
  F.with_synced_mirror (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis, _ = graph_info engine in
         let mutation =
           Logseq_db_types.Mutation.Structural
             (Insert_blocks
                { roots =
                    [ { uuid = F.uuid "64000000-0000-4000-8000-000000000001"
                      ; title = "Captured source"
                      ; children = []
                      }
                    ]
                ; position =
                    Relative (Last_child (F.uuid "11111111-1111-4111-8111-111111111111"))
                ; context =
                    { mutation_id = F.uuid "62000000-0000-4000-8000-000000000011"
                    ; expected_basis = basis
                    }
                })
         in
         let identity = Logseq_db_types.Mutation.identify mutation in
         let prepared =
           match Engine.prepare_managed_mutation engine ~identity mutation with
           | Ok prepared -> prepared
           | Error message -> T.fail "Capture preparation failed: %s" message
         in
         T.require
           (String.equal
              (Engine.prepared_mutation_payload prepared)
              (Logseq_db_types.Mutation.identity_payload identity))
           "Engine preparation did not retain the shared identity payload";
         let checkpoint = Engine.sync_checkpoint engine |> Result.get_ok in
         let scope = managed_scope checkpoint.graph_id in
         let key = Logseq_sync_pure_reducer.Core.graph_key_handle ~id:"test-key" ~scope in
         let input =
           Logseq_sync_pure_reducer.Core.local_batch_input
             ~scope
             ~key:(Some key)
             ~outbox_records:[]
             ~mutation_id:(Logseq_db_types.Mutation.context mutation).mutation_id
             ~mutation_payload:(Engine.prepared_mutation_payload prepared)
             ~mutation_fingerprint:
               (Logseq_db_types.Mutation.identity_fingerprint identity)
             ~outliner_op:(Engine.prepared_mutation_outliner_op prepared)
             ~database:(Engine.prepared_mutation_database prepared)
             ~operations:(Engine.prepared_mutation_operations prepared)
           |> Result.get_ok
         in
         let plan =
           Logseq_sync_pure_reducer.Core.begin_local_batch input |> Result.get_ok
         in
         let encrypted_values =
           match Logseq_sync_pure_reducer.Core.local_batch_crypto_request plan with
           | None -> None
           | Some request ->
             Some (List.map (fun _ -> "iv", "ciphertext") request.plaintexts)
         in
         let record =
           Logseq_sync_pure_reducer.Core.finish_local_batch plan encrypted_values
           |> Result.get_ok
         in
         let encoded =
           Logseq_sync_pure_reducer.Core.encode_outbox_records [ record ] |> Result.get_ok
         in
         let result =
           Engine.commit_managed_mutation engine prepared ~outbox_records:encoded
         in
         T.require (Result.is_ok result) "Capture outbox commit failed";
         let durable = Engine.managed_outbox_records engine |> Result.get_ok in
         let decoded =
           Logseq_sync_pure_reducer.Core.decode_outbox_records durable |> Result.get_ok
         in
         T.require (List.length decoded = 1) "Capture durable outbox record was lost";
         let durable_record = List.hd decoded in
         T.require
           (String.equal
              (Logseq_sync_pure_reducer.Core.outbox_record_fingerprint durable_record)
              (Logseq_db_types.Mutation.identity_fingerprint identity))
           "Capture durable outbox fingerprint drifted from the shared identity";
         T.require
           (String.length
              (Logseq_sync_pure_reducer.Core.outbox_record_fingerprint durable_record)
            = 64)
           "Capture durable outbox fingerprint exceeded its bounded digest"))
;;

let snapshot_entries fixture =
  let directory =
    Filename.concat (Filename.concat fixture.F.support "logseq-db-worker") "snapshots"
  in
  Sys.readdir directory
  |> Array.to_list
  |> List.filter (fun name -> not (String.starts_with ~prefix:"." name))
;;

let test_first_mutation_creates_backup_and_reopens () =
  F.with_snapshot (fun fixture ->
    T.require
      (List.length (snapshot_entries fixture) = 1)
      "fixture started with extra snapshots";
    let engine = open_engine fixture in
    let basis, _ = graph_info engine in
    let result = Engine.execute engine (mutation basis) |> mutation_result in
    T.require (result.status = Applied) "mutation did not commit";
    let _, graph = graph_info engine in
    T.require
      (List.mem Logseq_db_types.Graph_types.Backup_verified graph.admission_facts)
      "committed mutation omitted Backup_verified";
    (match Engine.close engine with
     | Ok () -> ()
     | Error message -> T.fail "committed Engine close failed: %s" message);
    T.require
      (List.length (snapshot_entries fixture) = 2)
      "first mutation did not create exactly one recovery snapshot";
    let reopened = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close reopened))
      (fun () ->
         let request =
           P.
             { api_version
             ; request_id = F.uuid "61000000-0000-4000-8000-000000000002"
             ; command =
                 Read
                   (Get_page
                      { page =
                          Page_by_uuid (F.uuid "63000000-0000-4000-8000-000000000001")
                      })
             }
         in
         match Engine.execute reopened request with
         | P.Succeeded { basis; success = Page_result _; _ } ->
           T.require (Int64.equal basis result.basis_after) "reopen lost committed basis"
         | _ -> T.fail "reopen lost committed page"))
;;

let test_fatal_persistence_terminalizes_engine () =
  F.with_snapshot ~fail_mutation_writes:true (fun fixture ->
    let engine = open_engine fixture in
    let basis, _ = graph_info engine in
    (match Engine.execute engine (mutation basis) with
     | exception Engine.Fatal_storage_error _ -> ()
     | _ -> T.fail "persistence failure did not raise Fatal_storage_error");
    (match Engine.execute engine (F.graph_info_request ()) with
     | exception Engine.Fatal_storage_error _ -> ()
     | _ -> T.fail "fatal Engine accepted a later request");
    match Engine.close engine with
    | Error _ -> ()
    | Ok () -> T.fail "fatal Engine close lost its diagnostic")
;;

let test_closed_engine_returns_typed_failure () =
  F.with_snapshot (fun fixture ->
    let engine = open_engine fixture in
    (match Engine.close engine with
     | Ok () -> ()
     | Error message -> T.fail "Engine close failed: %s" message);
    match Engine.execute engine (F.graph_info_request ()) with
    | P.Failed { phase = Execute; error; _ } ->
      T.require
        (Logseq_db_worker.Error.code error = Closed_session)
        "closed Engine returned the wrong error"
    | _ -> T.fail "closed Engine accepted a request")
;;

let test_close_failure_releases_internal_resources () =
  F.with_snapshot (fun fixture ->
    let engine = open_engine fixture in
    let lock_path = Filename.concat fixture.resolved.graph_dir "db-worker.lock" in
    let channel = open_out_bin lock_path in
    output_string channel "{}\n";
    close_out channel;
    (match Engine.close engine with
     | Error _ -> ()
     | Ok () -> T.fail "ownership identity change was not diagnosed");
    Unix.unlink lock_path;
    match Engine.open_ ~dependencies:F.dependencies fixture.config with
    | Error error ->
      T.fail
        "failed close retained the owner primitive or SQLite handle: %s"
        (Logseq_db_worker.Error.message error)
    | Ok replacement ->
      (match Engine.close replacement with
       | Ok () -> ()
       | Error message -> T.fail "replacement Engine did not close: %s" message))
;;

let () =
  T.run
    "engine"
    [ T.case
        "Graph_info reports admission facts and target mode"
        test_graph_info_reports_admission_and_mode
    ; T.case
        "expected basis conflict is typed and non-mutating"
        test_basis_conflict_is_typed_and_non_mutating
    ; T.case "live mutation ID cache deduplicates" test_live_mutation_cache_is_idempotent
    ; T.case
        "live mutation ID cache rejects different content"
        test_live_mutation_cache_rejects_reused_id_for_different_content
    ; T.case
        "Capture managed outbox shares identity and round-trips"
        test_capture_managed_outbox_uses_shared_identity_and_round_trips
    ; T.case
        "first mutation creates backup and reopens"
        test_first_mutation_creates_backup_and_reopens
    ; T.case
        "fatal persistence terminalizes Engine"
        test_fatal_persistence_terminalizes_engine
    ; T.case
        "closed Engine returns typed failure"
        test_closed_engine_returns_typed_failure
    ; T.case
        "close failure releases internal resources"
        test_close_failure_releases_internal_resources
    ]
;;
