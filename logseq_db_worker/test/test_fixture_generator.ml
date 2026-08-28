open Logseq_db_types.Mutation
module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_fixture_generator.Fixture_generator
module P = Logseq_db_worker.Protocol
module G = Logseq_db_types.Graph_types

let uuid value = G.Uuid.of_string value |> Result.get_ok

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_directory prefix run =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)
;;

let engine (generated : F.generated) =
  let config =
    Logseq_db_worker.Config.create
      ~application_support_directory:generated.F.support_root
      ~target:(Snapshot { token = generated.snapshot_token })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:P.maximum_response_bytes
      ~default_page_size:P.default_page_size
    |> Result.get_ok
  in
  Logseq_db_worker.Engine.open_
    ~dependencies:Logseq_db_worker_test_support.Adapter_fixture.dependencies
    config
  |> Result.get_ok
;;

let create support mode =
  match F.create ~support_root:support ~mode with
  | Ok generated -> generated
  | Error message -> T.fail "fixture generation failed: %s" message
;;

let graph_info_request =
  P.
    { api_version
    ; request_id = uuid "99000000-0000-4000-8000-000000000001"
    ; command = Read Graph_info
    }
;;

let test_runtime_flow_fixture_opens_through_engine () =
  with_temp_directory "logseq-runtime-fixture-" (fun support ->
    let generated = create support F.Runtime_flow in
    T.require
      (String.equal generated.support_root (Unix.realpath support))
      "generator did not return the canonical support root";
    T.require
      (String.equal
         generated.graph_dir
         (Filename.concat
            (Filename.concat
               (Filename.concat generated.support_root "logseq-db-worker")
               "snapshots")
            (G.Uuid.to_string generated.snapshot_token)))
      "generator returned an unexpected snapshot directory";
    let engine = engine generated in
    (match Logseq_db_worker.Engine.execute engine graph_info_request with
     | P.Succeeded { success = Graph_info_result info; _ } ->
       T.require
         (String.equal info.graph_name "runtime-flow-source")
         "generated graph name changed"
     | _ -> T.fail "generated runtime fixture did not answer Graph_info");
    T.require
      (Logseq_db_worker.Engine.close engine = Ok ())
      "generated Engine did not close")
;;

let test_failure_fixture_terminalizes_on_real_mutation () =
  with_temp_directory "logseq-failure-fixture-" (fun support ->
    let generated = create support F.Runtime_flow_with_persistence_failure in
    let engine = engine generated in
    let basis = Option.value (Logseq_db_worker.Engine.basis engine) ~default:0L in
    let request =
      P.
        { api_version
        ; request_id = uuid "99000000-0000-4000-8000-000000000002"
        ; command =
            Mutate
              (Page
                 (Create_page
                    { title = "Failure probe"
                    ; kind =
                        Create_ordinary_page
                          { uuid = uuid "99000000-0000-4000-a000-000000000001" }
                    ; context =
                        { mutation_id = uuid "99000000-0000-4000-9000-000000000001"
                        ; expected_basis = basis
                        }
                    }))
        }
    in
    (match Logseq_db_worker.Engine.execute engine request with
     | exception Logseq_db_worker.Engine.Fatal_storage_error _ -> ()
     | _ -> T.fail "persistence-failure fixture did not terminalize the Engine");
    match Logseq_db_worker.Engine.close engine with
    | Error _ -> ()
    | Ok () -> T.fail "terminal fixture Engine close lost its fatal diagnostic")
;;

let test_pagination_fixture_contains_two_continued_journal_days () =
  with_temp_directory "logseq-pagination-fixture-" (fun support ->
    let generated = create support F.Runtime_flow_with_pagination in
    let engine = engine generated in
    Fun.protect
      ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
      (fun () ->
         let continued_page day =
           let page =
             uuid
               (Printf.sprintf
                  "00000001-%04d-%04d-0000-000000000000"
                  (day / 10_000)
                  (day mod 10_000))
           in
           let request =
             P.
               { api_version
               ; request_id = uuid (Printf.sprintf "99000000-0000-4000-8000-%012x" day)
               ; command =
                   Read (Get_children { parent = page; limit = 64; cursor = None })
               }
           in
           match Logseq_db_worker.Engine.execute engine request with
           | P.Succeeded { success = Children_result result; _ } ->
             T.require (List.length result.items = 64) "pagination fixture page is short";
             T.require
               (Option.is_some result.continuation)
               "pagination fixture page has no continuation"
           | _ -> T.fail "pagination fixture journal page did not load"
         in
         continued_page 20260805;
         continued_page 20260804))
;;

let test_generator_refuses_to_replace_existing_source () =
  with_temp_directory "logseq-duplicate-fixture-" (fun support ->
    ignore (create support F.Runtime_flow);
    match F.create ~support_root:support ~mode:F.Runtime_flow with
    | Error _ -> ()
    | Ok _ -> T.fail "fixture generator replaced an existing source")
;;

let test_encrypted_warm_start_fixture_has_a_selected_ready_mirror () =
  with_temp_directory "logseq-encrypted-warm-fixture-" (fun support ->
    let generated =
      match F.create_encrypted_warm_start ~support_root:support with
      | Ok generated -> generated
      | Error message -> T.fail "encrypted fixture generation failed: %s" message
    in
    T.require
      (String.equal generated.support_root (Unix.realpath support))
      "encrypted fixture did not return its canonical support root";
    let catalog_root =
      Filename.concat generated.support_root "logseq-db-worker/sync-catalogs"
    in
    let catalogs = Sys.readdir catalog_root |> Array.to_list in
    T.require (List.length catalogs = 1) "encrypted fixture omitted its catalog";
    let catalog =
      Yojson.Safe.from_file (Filename.concat catalog_root (List.hd catalogs))
    in
    let open Yojson.Safe.Util in
    T.require
      (catalog
       |> member "selectedGraph"
       |> to_string
       = Logseq_db_types.Graph_types.Uuid.to_string generated.graph_id)
      "encrypted fixture graph is not selected";
    T.require
      (catalog |> member "graphs" |> to_list |> List.length = 1)
      "encrypted fixture catalog is not scoped to one graph";
    T.require
      (catalog |> member "mirrors" |> index 0 |> member "status" |> to_string = "ready")
      "encrypted fixture mirror is not marked ready";
    T.require
      (Sys.file_exists (Filename.concat generated.graph_dir "db.sqlite"))
      "encrypted fixture mirror has no database")
;;

let () =
  T.run
    "fixture-generator"
    [ T.case "runtime fixture opens" test_runtime_flow_fixture_opens_through_engine
    ; T.case
        "failure fixture terminalizes"
        test_failure_fixture_terminalizes_on_real_mutation
    ; T.case
        "pagination fixture has continued days"
        test_pagination_fixture_contains_two_continued_journal_days
    ; T.case
        "existing fixture is not replaced"
        test_generator_refuses_to_replace_existing_source
    ; T.case
        "encrypted warm-start fixture has selected ready mirror"
        test_encrypted_warm_start_fixture_has_a_selected_ready_mirror
    ]
;;
