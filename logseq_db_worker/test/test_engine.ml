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
