open Logseq_db_types.Mutation
module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module Engine = Logseq_db_worker.Engine
module Protocol = Logseq_db_worker.Protocol
module Graph = Logseq_db_types.Graph_types

let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let test_synced_attachment_opens_and_reads () =
  F.with_managed (fun fixture ->
    let engine = F.open_engine fixture |> Result.get_ok in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         match Engine.execute engine (F.graph_info_request ()) with
         | Protocol.Succeeded { success = Graph_info_result info; _ } ->
           T.require (String.equal info.graph_name "oracle-graph") "graph name changed";
           let encoded =
             Protocol.response_to_yojson (Engine.execute engine (F.graph_info_request ()))
           in
           let text = Yojson.Safe.to_string encoded in
           T.require (not (String.contains text '\000')) "graph response contains NUL";
           T.require
             (not (String.starts_with ~prefix:"syncedLocalFirst" text))
             "obsolete graph mode leaked"
         | _ -> T.fail "managed attachment did not answer Graph_info"))
;;

let test_attachment_rejects_mismatched_identity () =
  F.with_managed (fun fixture ->
    let other = uuid "70000000-0000-4000-8000-000000000001" in
    let checkpoint =
      Logseq_db_types.Sync_checkpoint.create
        ~graph_id:other
        ~schema:Graph.{ major = 65; minor = 33 }
        ~applied_server_t:0
        ~checksum:"0000000000000000"
      |> Result.get_ok
    in
    let attachment = Engine.{ fixture.attachment with checkpoint } in
    match
      Engine.open_
        ~dependencies:F.dependencies
        ~response_budget_bytes:fixture.config.response_budget_bytes
        attachment
    with
    | Error error ->
      T.require
        (Logseq_db_worker.Error.code error = Invalid_request)
        "identity mismatch returned the wrong error"
    | Ok engine ->
      ignore (Engine.close engine);
      T.fail "mismatched attachment identity was accepted")
;;

let test_managed_mutation_uses_prepare_commit_boundary () =
  F.with_managed (fun fixture ->
    let engine = F.open_engine fixture |> Result.get_ok in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let page = uuid "00000001-2026-0901-0000-000000000000" in
         let mutation =
           Page
             (Create_page
                { title = "Managed journal"
                ; kind =
                    Create_journal_page
                      { journal_day = 20260901; supplied_uuid = Some page }
                ; context =
                    { mutation_id = uuid "80000000-0000-4000-9000-000000000001"
                    ; expected_basis = Option.get (Engine.basis engine)
                    }
                })
         in
         let identity = Logseq_db_types.Mutation.identify mutation in
         let prepared =
           Engine.prepare_managed_mutation engine ~identity mutation
           |> Result.fold ~ok:Fun.id ~error:(fun message ->
             T.fail "managed prepare failed: %s" message)
         in
         let success =
           Engine.commit_managed_mutation engine prepared ~outbox_records:[]
           |> Result.fold ~ok:Fun.id ~error:(fun message ->
             T.fail "managed commit failed: %s" message)
         in
         T.require (success.status = Applied) "managed mutation did not apply";
         let request =
           Protocol.
             { api_version
             ; request_id = uuid "80000000-0000-4000-a000-000000000001"
             ; command = Read (Get_page { page = Page_by_uuid page })
             }
         in
         match Engine.execute engine request with
         | Succeeded { success = Page_result _; _ } -> ()
         | _ -> T.fail "managed projection did not expose the committed page"))
;;

let () =
  T.run
    "managed Engine"
    [ T.case "synced attachment opens and reads" test_synced_attachment_opens_and_reads
    ; T.case
        "attachment validates graph identity"
        test_attachment_rejects_mismatched_identity
    ; T.case
        "managed mutation uses prepare/commit"
        test_managed_mutation_uses_prepare_commit_boundary
    ]
;;
