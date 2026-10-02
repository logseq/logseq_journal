module T = Logseq_db_worker_test_support.Test_support
module P = Logseq_db_worker.Protocol
module ID = Logseq_db_worker_lui.Journal_worker_ids
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Runner = Logseq_sync_effect_runner.Effect_runner
module Worker = Logseq_db_worker_lui.Journal_worker
module Worker_runtime = Logseq_db_worker_lui.Journal_worker_runtime

let crypto =
  Runner.crypto
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unavailable")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unavailable")
  |> Result.get_ok
;;

let secrets =
  Runner.secrets
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
      Error "unavailable")
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      Error "unavailable")
    ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Error (Runner.Wrapped_graph_key_unavailable "unavailable"))
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
      Error "unavailable")
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let dependencies =
  Service.dependencies
    ~overlay:(T.overlay_dependencies ())
    ~tls_authenticator:(Runner.system_tls_authenticator () |> Result.get_ok)
    ~secrets
    ~crypto
;;

let accepted = function
  | Worker.Accepted request_id -> request_id
  | Full | Not_ready | Stopping -> T.fail "worker request was not accepted"
;;

let await_response client request_id =
  let rec loop () =
    match
      Worker.For_testing.drain_events client ~max_events:64
      |> List.find_map (function
        | Worker.Response { request_id = actual; outcome = Completed response; _ }
          when ID.Worker.Request_id.equal request_id actual -> Some response
        | Response _ | Push _ | Terminal _ -> None)
    with
    | Some response -> response
    | None ->
      Worker.For_testing.await_output client;
      loop ()
  in
  loop ()
;;

let with_client config run =
  let service = Service.create ~dependencies in
  let client =
    Worker_runtime.start ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2_000L) service config
    |> Result.fold ~ok:Fun.id ~error:(fun message -> T.fail "%s" message)
  in
  Fun.protect ~finally:(fun () -> Worker_runtime.stop client) (fun () -> run client)
;;

let v2_graph_info_request () =
  let json =
    `Assoc
      [ "apiVersion", `Int 2
      ; "requestId", `String "00000000-0000-4000-8000-000000000001"
      ; "command", `Assoc [ "type", `String "graphInfo" ]
      ]
  in
  match P.request_of_yojson json with
  | Ok request -> request
  | Error error ->
    T.fail
      "unable to build v2 graph-info request: %s"
      (Logseq_db_worker.Error.message error)
;;

let test_managed_worker_starts_closed_and_replies_with_v2_envelope () =
  T.with_managed (fun fixture ->
    with_client fixture.config (fun client ->
      let request = v2_graph_info_request () in
      let id = Worker.send client (Service.Graph_request request) |> accepted in
      match await_response client id with
      | Service.Graph_response response ->
        (match P.response_to_yojson response with
         | `Assoc
             [ ("apiVersion", `Int 2)
             ; ("requestId", `String "00000000-0000-4000-8000-000000000001")
             ; ("outcome", `Assoc (("type", `String "failed") :: _))
             ] -> ()
         | json ->
           T.fail
             "pre-selection v2 request did not return a v2 failure envelope: %s"
             (Yojson.Safe.to_string json))
      | _ -> T.fail "managed worker returned the wrong response kind"))
;;

let test_managed_client_command_is_accepted () =
  T.with_managed (fun fixture ->
    with_client fixture.config (fun client ->
      let id =
        Worker.send
          client
          (Service.Client_command (Restore_local_account { user_id = "fixture-user" }))
        |> accepted
      in
      match await_response client id with
      | Service.Client_command_completed -> ()
      | _ -> T.fail "managed client command returned the wrong response"))
;;

module Mailbox = Logseq_db_worker_lui.Journal_bounded_mailbox.Coalesced
module Transfer = Logseq_sync_pure_reducer.Asset_transfer

let asset_scope generation : Service.asset_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://api.logseq.io"
      ; user_id = "fixture-user"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id =
      Logseq_db_types.Graph_types.Uuid.of_string "00000000-0000-4000-8000-999999999999"
      |> Result.get_ok
  ; graph_generation = generation
  }
;;

let asset_uuid suffix =
  Logseq_db_types.Graph_types.Uuid.of_string
    (Printf.sprintf "00000000-0000-4000-8000-%012d" suffix)
  |> Result.get_ok
;;

let availability scope consumer asset state =
  Service.Asset_notice
    (scope, Asset_availability { consumer; asset; availability = state })
;;

let collect_asset_burst pushes =
  let mailbox = Mailbox.create ~capacity:6 in
  List.iter
    (fun push ->
       ignore
         (Mailbox.push
            ~merge:(Service.coalesce_push ~topic:(ID.Worker.Push_topic.of_int 5))
            mailbox
            ~topic:5
            push))
    pushes;
  Mailbox.drain mailbox ~max_items:6
  |> List.concat_map (fun (_, push) -> Service.asset_notices push)
;;

let test_ready_survives_acceptance () =
  let scope = asset_scope 1 in
  let ready = availability scope "visible" (asset_uuid 1) (Ready "cached") in
  let accepted = Service.Asset_notice (scope, Asset_demand_accepted "visible") in
  T.require
    (collect_asset_burst [ ready; accepted ]
     = [ ( scope
         , Asset_availability
             { consumer = "visible"; asset = asset_uuid 1; availability = Ready "cached" }
         )
       ; scope, Asset_demand_accepted "visible"
       ])
    "Ready must survive demand acceptance in the same asset topic"
;;

let test_assets_consumers_and_scopes_survive () =
  let scope = asset_scope 1 in
  let next_scope = asset_scope 2 in
  let pushes =
    [ availability scope "a" (asset_uuid 1) (Ready "first")
    ; availability scope "a" (asset_uuid 2) (Ready "second")
    ; availability scope "b" (asset_uuid 1) (Ready "shared")
    ; availability next_scope "a" (asset_uuid 1) (Ready "new-graph")
    ; Service.Asset_notice (scope, Asset_capacity_available)
    ]
  in
  T.require
    (List.length (collect_asset_burst pushes) = 5)
    "Distinct assets, consumers, graph scopes and capacity must not overwrite each other"
;;

let test_retry_keeps_latest_fact_in_arrival_order () =
  let scope = asset_scope 1 in
  let asset = asset_uuid 1 in
  let failed =
    Transfer.Failed { failure = Not_found; attempts = 1; retry_scheduled = false }
  in
  let collected =
    collect_asset_burst
      [ availability scope "a" asset failed
      ; Service.Asset_notice (scope, Asset_backpressure "a")
      ; availability scope "a" asset Queued
      ; availability scope "a" asset (Ready "retried")
      ; Service.Asset_notice (scope, Asset_demand_accepted "a")
      ]
  in
  T.require
    (collected
     = [ ( scope
         , Asset_availability { consumer = "a"; asset; availability = Ready "retried" } )
       ; scope, Asset_demand_accepted "a"
       ])
    "Retry should replace only the same fact, keeping Ready and latest admission ordered"
;;

let test_uploads_do_not_erase_downloads () =
  let scope = asset_scope 1 in
  let upload operation status =
    Service.Asset_notice
      ( scope
      , Upload_status
          { operation = asset_uuid operation
          ; asset = asset_uuid 1
          ; target = asset_uuid 3
          ; title = "Fixture upload"
          ; status
          } )
  in
  let result =
    collect_asset_burst
      [ availability scope "a" (asset_uuid 1) (Ready "download")
      ; upload 10 Preparing
      ; upload 11 Sending
      ; upload 10 Uploaded
      ]
  in
  T.require
    (List.length result = 3)
    "Upload operations and download availability must retain independent latest facts"
;;

let test_pending_asset_facts_have_hard_bound () =
  let scope = asset_scope 1 in
  let pushes =
    List.init 4097 (fun index ->
      availability scope (string_of_int index) (asset_uuid 1) Queued)
  in
  let exhausted =
    try
      ignore (collect_asset_burst pushes);
      false
    with
    | Failure message -> message = "Worker pending asset fact limit exceeded"
  in
  T.require
    exhausted
    "Asset burst overflow must fail explicitly instead of dropping facts"
;;

let test_snapshot_topics_still_replace () =
  let mailbox = Mailbox.create ~capacity:1 in
  ignore (Mailbox.push mailbox ~topic:0 1);
  ignore (Mailbox.push mailbox ~topic:0 2);
  T.require
    (Mailbox.drain mailbox ~max_items:1 = [ 0, 2 ])
    "Ordinary snapshot topics should retain their latest value"
;;

let () =
  T.run
    "lui worker service"
    [ T.case "Ready survives acceptance" test_ready_survives_acceptance
    ; T.case "distinct asset facts survive" test_assets_consumers_and_scopes_survive
    ; T.case
        "retry retains latest ordered facts"
        test_retry_keeps_latest_fact_in_arrival_order
    ; T.case "uploads and downloads are independent" test_uploads_do_not_erase_downloads
    ; T.case "pending asset facts are bounded" test_pending_asset_facts_have_hard_bound
    ; T.case "snapshot topics still replace" test_snapshot_topics_still_replace
    ; T.case
        "managed worker starts closed with a v2 envelope"
        test_managed_worker_starts_closed_and_replies_with_v2_envelope
    ; T.case "managed client command is accepted" test_managed_client_command_is_accepted
    ]
;;
