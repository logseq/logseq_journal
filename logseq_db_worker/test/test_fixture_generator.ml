module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_fixture_generator.Fixture_generator
module A = Logseq_db_worker_test_support.Adapter_fixture
module P = Logseq_db_worker.Protocol

let with_temp_directory run = A.with_temp_directory "logseq-managed-fixture-" run

let create support mode =
  F.create ~support_root:support ~mode
  |> Result.fold ~ok:Fun.id ~error:(fun message ->
    T.fail "fixture generation failed: %s" message)
;;

let attachment generated =
  let checkpoint =
    Logseq_db_storage.Sync_checkpoint_store.read_path
      (Filename.concat generated.F.graph_dir "db.sqlite")
    |> Result.get_ok
  in
  Logseq_db_worker.Engine.
    { graph_id = generated.graph_id
    ; graph_name = "runtime-flow-source"
    ; graph_dir = generated.graph_dir
    ; database_path = Filename.concat generated.graph_dir "db.sqlite"
    ; checkpoint
    }
;;

let test_managed_fixture_opens_through_engine () =
  with_temp_directory (fun support ->
    let generated = create support F.Runtime_flow in
    let engine =
      Logseq_db_worker.Engine.open_
        ~dependencies:A.dependencies
        ~response_budget_bytes:P.maximum_response_bytes
        (attachment generated)
      |> Result.get_ok
    in
    Fun.protect
      ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
      (fun () ->
         match Logseq_db_worker.Engine.execute engine (A.graph_info_request ()) with
         | P.Succeeded { success = Graph_info_result info; _ } ->
           T.require
             (String.equal info.graph_name "runtime-flow-source")
             "managed fixture graph name changed"
         | _ -> T.fail "managed fixture did not answer Graph_info"))
;;

let test_pagination_fixture_is_durable () =
  with_temp_directory (fun support ->
    let generated = create support F.Runtime_flow_with_pagination in
    let engine =
      Logseq_db_worker.Engine.open_
        ~dependencies:A.dependencies
        ~response_budget_bytes:P.maximum_response_bytes
        (attachment generated)
      |> Result.get_ok
    in
    Fun.protect
      ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
      (fun () ->
         let page =
           Logseq_db_types.Graph_types.Uuid.of_string
             "00000001-2026-0805-0000-000000000000"
           |> Result.get_ok
         in
         let request =
           P.
             { api_version
             ; request_id =
                 Logseq_db_types.Graph_types.Uuid.of_string
                   "99000000-0000-4000-8000-000000000001"
                 |> Result.get_ok
             ; command = Read (Get_children { parent = page; limit = 64; cursor = None })
             }
         in
         match Logseq_db_worker.Engine.execute engine request with
         | P.Succeeded { success = Children_result result; _ } ->
           T.require (List.length result.items = 64) "managed fixture page is short";
           T.require
             (Option.is_some result.continuation)
             "managed fixture has no continuation"
         | _ -> T.fail "managed pagination fixture did not load"))
;;

let test_generator_refuses_replacement () =
  with_temp_directory (fun support ->
    ignore (create support F.Runtime_flow);
    match F.create ~support_root:support ~mode:F.Runtime_flow with
    | Error _ -> ()
    | Ok _ -> T.fail "managed fixture generator replaced an existing mirror")
;;

let () =
  T.run
    "fixture-generator"
    [ T.case "managed fixture opens" test_managed_fixture_opens_through_engine
    ; T.case "managed pagination is durable" test_pagination_fixture_is_durable
    ; T.case "existing managed fixture is not replaced" test_generator_refuses_replacement
    ]
;;
