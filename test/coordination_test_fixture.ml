module W = Journal_worker_coordination.Worker_api
module P = Logseq_db_worker.Protocol
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Id = Logseq_db_worker_lui.Journal_worker_ids
module Sync = Logseq_sync_pure_reducer.Core

let check condition message = if not condition then failwith message
let uuid s = W.Uuid.of_string s |> Result.get_ok
let graph = uuid "98000000-0000-4000-8000-000000000001"

let limits : P.v2_capability_limits =
  { response_budget_bytes = 65536
  ; outbox_max_records = 32
  ; outbox_max_bytes = 65536
  ; change_max_items = 32
  ; change_max_bytes = 65536
  ; dispatcher_capacity = 32
  ; wire_batch_max_bytes = 65536
  }
;;

let fixture ?(graph_generation = 7) ?(limits = limits) epoch =
  let issuer =
    W.issuer
      ~managed_origin:"https://example.invalid"
      ~user_id:"synthetic"
      ~runtime_epoch:(Id.Runtime.Epoch.of_int64 epoch)
      ~worker_generation:Id.Worker.Generation.one
    |> Result.get_ok
  in
  let module I = (val issuer : W.ISSUER) in
  let registration =
    match I.bootstrap_request () with
    | Ok (S.Register_coordination id) -> id
    | _ -> assert false
  in
  let account : Sync.account_scope =
    { managed_sync_origin = Uri.of_string "https://example.invalid"
    ; user_id = "synthetic"
    ; account_generation = 1
    ; presentation_generation = 1
    ; lifecycle_generation = 1L
    }
  in
  let scope : Sync.graph_scope = { account; graph_id = graph; graph_generation } in
  let cfg =
    Sync.limits
      ~maximum_response_bytes:65536
      ~maximum_artifact_bytes:65536
      ~submission_batch_size:1
    |> Result.get_ok
    |> fun limits ->
    Sync.config ~managed_sync_origin:account.managed_sync_origin ~limits |> Result.get_ok
  in
  let state = Sync.initial cfg |> Result.get_ok |> Sync.state in
  let state =
    { state with
      snapshot =
        { state.snapshot with
          selected_graph = Some graph
        ; resident_graphs = [ graph ]
        ; startup =
            { state.snapshot.startup with
              account_generation = 1
            ; graph_generation
            ; presentation_generation = 1
            }
        }
    }
  in
  let owner : S.timeline_scope =
    { startup = { account_generation = 1; presentation_generation = 1 }
    ; graph_id = graph
    ; graph_generation
    }
  in
  let sync : Sync.coordination_state =
    { account = Some account
    ; desired_residents = [ graph ]
    ; residents = [ scope, state ]
    ; selected = Some owner
    ; deletion = None
    }
  in
  let physical : Logseq_db_worker.graph_state =
    { graph_id = Some graph
    ; generation = graph_generation
    ; phase = Graph_open
    ; error = None
    }
  in
  let raw : S.coordination_baseline =
    { registration
    ; authority_user = None
    ; limits
    ; baseline =
        { version = 1L
        ; presentation = 1L
        ; state = { sync; residents = [ scope, physical ] }
        }
    }
  in
  let projection =
    match I.bootstrap (S.Coordination_registered raw) with
    | Ok (W.Ready p) -> p
    | _ -> failwith "valid fixture baseline rejected"
  in
  let session = (List.hd (W.residents projection)).session in
  issuer, raw, projection, session
;;
