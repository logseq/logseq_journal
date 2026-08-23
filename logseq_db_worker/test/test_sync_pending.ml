module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module Pending = Logseq_db_worker.Sync_pending
module Protocol = Logseq_db_worker.Protocol
module Graph_types = Logseq_db_worker.Graph_types

let entry state =
  let mutation_id = F.uuid "20000000-0000-4000-8000-000000000001" in
  let request =
    Protocol.
      { api_version
      ; request_id = F.uuid "10000000-0000-4000-8000-000000000001"
      ; command =
          Mutate
            (Structural
               (Save_block
                  { block = F.uuid "11111111-1111-4111-8111-111111111111"
                  ; title = "Durable pending title"
                  ; context = { mutation_id; expected_basis = 40L }
                  }))
      }
  in
  Pending.
    { mutation_id; request; tx = {|[["~:db/add",1]]|}; outliner_op = "save-block"; state }
;;

let durable_round_trip_case () =
  F.with_temp_directory "sync-pending-" (fun graph_dir ->
    let pending =
      match Pending.open_ ~graph_dir with
      | Ok value -> value
      | Error message -> T.fail "open pending: %s" message
    in
    (match Pending.append pending (entry Pending.Queued) with
     | Ok () -> ()
     | Error message -> T.fail "append pending: %s" message);
    let reopened =
      match Pending.open_ ~graph_dir with
      | Ok value -> value
      | Error message -> T.fail "reopen pending: %s" message
    in
    match Pending.entries reopened with
    | [ restored ] ->
      T.require
        (Graph_types.Uuid.equal restored.mutation_id (entry Pending.Queued).mutation_id)
        "stable pending mutation ID changed";
      T.require (restored.state = Pending.Queued) "pending state changed";
      T.require
        (String.equal restored.tx {|[["~:db/add",1]]|})
        "pending transaction changed"
    | _ -> T.fail "pending entry did not round trip")
;;

let state_and_corruption_case () =
  F.with_temp_directory "sync-pending-state-" (fun graph_dir ->
    let pending = Pending.open_ ~graph_dir |> Result.get_ok in
    Pending.append pending (entry (Pending.Accepted 42)) |> Result.get_ok;
    let accepted = Pending.open_ ~graph_dir |> Result.get_ok |> Pending.entries in
    (match accepted with
     | [ { state = Pending.Accepted 42; _ } ] -> ()
     | _ -> T.fail "accepted server t was not durable");
    let channel = open_out_bin (Pending.path pending) in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel {|{"version":1,"entries":[{"secret":"key"}]}|});
    match Pending.open_ ~graph_dir with
    | Error _ -> ()
    | Ok _ -> T.fail "corrupt pending intent data was accepted")
;;

let cases =
  [ T.case "round trip durable versioned pending intents" durable_round_trip_case
  ; T.case "persist accepted state and reject corruption" state_and_corruption_case
  ]
;;

let () = T.run "sync pending" cases
