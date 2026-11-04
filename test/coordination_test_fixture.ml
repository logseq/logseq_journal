module W = Journal_worker_coordination.Worker_api
module P = Logseq_db_worker.Protocol
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Id = Logseq_db_worker_lui.Journal_worker_ids
module Sync = Logseq_sync_pure_reducer.Core

let check condition message = if not condition then failwith message
let uuid s = W.Uuid.of_string s |> Result.get_ok
let graph = uuid "98000000-0000-4000-8000-000000000001"

let limits : Worker_pure_data.capability_limits =
  { response_budget_bytes = 65536
  ; outbox_max_records = 32
  ; outbox_max_bytes = 65536
  ; change_max_items = 32
  ; change_max_bytes = 65536
  ; dispatcher_capacity = 32
  ; wire_batch_max_bytes = 65536
  }
;;

let fixture ?(graph = graph) ?(graph_generation = 7) ?(limits = limits) epoch =
  let issuer =
    Worker_effect_authority.issuer
      ~managed_origin:"https://example.invalid"
      ~user_id:"synthetic"
      ~runtime_epoch:(Id.Runtime.Epoch.of_int64 epoch)
      ~worker_generation:Id.Worker.Generation.one
    |> Result.get_ok
  in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
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

(* Stable typed cursors for pure route tests; constructed only through the public
   issuer/decode boundary, without exposing or inventing a continuation seal. *)
let child_cursor_fixture = lazy (fixture 6100L)

let child_continuation token =
  let issuer, _, _, session = Lazy.force child_cursor_fixture in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:Worker_pure_data.default_page_size ~maximum_bytes:65536
    |> Result.get_ok
  in
  let operation =
    W.Query (budget, W.Child_members { parent = graph; revision = None; after = None })
  in
  let request_id = uuid "98000000-0000-4000-8000-000000006100" in
  ignore
    (I.request session ~request_id:(W.request_id request_id) operation |> Result.get_ok);
  let response =
    S.Graph_response
      (P.V2_response
         { api_version = P.api_version
         ; request_id
         ; outcome =
             V2_children_outcome
               { parent = graph
               ; revision_scope = Worker_pure_data.V2_children_revision graph
               ; scope_revision = "fixture"
               ; items = []
               ; next_cursor =
                   Some
                     (Logseq_db_types.Graph_types.Cursor.of_string token |> Result.get_ok)
               }
         })
  in
  match I.reply session ~request_id:(W.request_id request_id) operation response with
  | Ok (W.Answered (Ok children)) -> Option.get children.next
  | _ -> failwith "valid route continuation rejected"
;;
