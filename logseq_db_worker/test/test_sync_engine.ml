module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module P = Logseq_db_worker.Protocol
module Engine = Logseq_db_worker.Engine
module Config = Logseq_db_worker.Config
module Graph_types = Logseq_db_worker.Graph_types
module Pending = Logseq_db_worker.Sync_pending
module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

let request_id value = F.uuid value
let execute engine request = Engine.execute engine request

let open_engine fixture =
  match Engine.open_ ~dependencies:F.dependencies fixture.F.sync_config with
  | Ok value -> value
  | Error error ->
    T.fail "unable to open synced engine: %s" (Logseq_db_worker.Error.message error)
;;

let sync_request ?(transport = P.Websocket) id payload =
  F.sync_receive_request ~request_id:id ~transport ~payload
;;

let read_page engine id =
  let request =
    P.
      { api_version
      ; request_id = request_id id
      ; command =
          Read
            (Get_page
               { page = Page_by_uuid (F.uuid "11111111-1111-4111-8111-111111111111") })
      }
  in
  match execute engine request with
  | P.Succeeded { success = Page_result page; _ } -> page
  | _ -> T.fail "synced page read failed"
;;

let sync_status engine id =
  let request =
    P.{ api_version; request_id = request_id id; command = Read Sync_status }
  in
  match execute engine request with
  | P.Succeeded { success = Sync_status_result status; _ } -> status
  | _ -> T.fail "sync status read failed"
;;

let graph_basis engine id =
  match execute engine (F.graph_info_request ~request_id:id ()) with
  | P.Succeeded { success = Graph_info_result info; _ } -> info.basis
  | _ -> T.fail "graph info failed"
;;

let save_page_request ~basis ~request_id ~mutation_id ~title =
  P.
    { api_version
    ; request_id = F.uuid request_id
    ; command =
        Mutate
          (Structural
             (Save_block
                { block = F.uuid "11111111-1111-4111-8111-111111111111"
                ; title
                ; context = { mutation_id = F.uuid mutation_id; expected_basis = basis }
                }))
    }
;;

let sync_pending engine id =
  let request = P.{ api_version; request_id = F.uuid id; command = Read Sync_pending } in
  match execute engine request with
  | P.Succeeded { success = Sync_pending_result pending; _ } -> pending
  | _ -> T.fail "sync pending read failed"
;;

let execute_allowlisted engine ~request_id ~mutation =
  let request =
    P.{ api_version; request_id = F.uuid request_id; command = Mutate mutation }
  in
  match execute engine request with
  | P.Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
  | P.Failed failure ->
    T.fail
      "allowlisted synced mutation failed: %s"
      (Logseq_db_worker.Error.message failure.error)
  | _ -> T.fail "allowlisted synced mutation returned an unexpected outcome"
;;

let foreground_pull_case () =
  F.with_synced (fun fixture ->
    let payload = F.sync_pull_wire fixture ~title:"Synced Oracle Page" in
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let response =
           execute engine (sync_request "51000000-0000-4000-8000-000000000001" payload)
         in
         let result =
           match response with
           | P.Succeeded { success = Sync_result result; _ } -> result
           | _ -> T.fail "valid pull did not return Sync_result"
         in
         T.require (result.activity = P.Pull_applied) "valid pull was not applied";
         let mutation =
           match result.mutation with
           | Some value -> value
           | None -> T.fail "applied pull omitted invalidation metadata"
         in
         T.require
           (Int64.compare mutation.basis_after mutation.basis_before > 0)
           "applied pull did not advance local basis";
         T.require
           (String.equal
              (read_page engine "51000000-0000-4000-8000-000000000002").title
              "Synced Oracle Page")
           "read path did not observe pulled graph state";
         let status = sync_status engine "51000000-0000-4000-8000-000000000003" in
         T.require (status.state = P.Sync_active) "successful pull did not stay active";
         T.require (status.applied_server_t = 41) "sync status lost server t";
         let duplicate =
           execute
             engine
             (sync_request
                ~transport:P.Http_pull
                "51000000-0000-4000-8000-000000000004"
                payload)
         in
         match duplicate with
         | P.Succeeded
             { success = Sync_result { activity = Pull_duplicate; mutation = None; _ }
             ; _
             } -> ()
         | _ -> T.fail "HTTP duplicate did not share WebSocket replay semantics"))
;;

let checksum_pause_is_visible_and_readable_case () =
  F.with_synced (fun fixture ->
    let payload =
      F.sync_pull_wire fixture ~title:"Should roll back"
      |> Yojson.Safe.from_string
      |> function
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (name, value) ->
                if String.equal name "checksum"
                then name, `String "0000000000000000"
                else name, value)
             fields)
        |> Yojson.Safe.to_string
      | _ -> T.fail "pull fixture is not an object"
    in
    let engine = open_engine fixture in
    let response =
      execute engine (sync_request "52000000-0000-4000-8000-000000000001" payload)
    in
    (match response with
     | P.Succeeded { success = Sync_result result; _ } ->
       T.require (result.activity = P.Sync_paused) "checksum mismatch did not pause";
       T.require (Option.is_some result.last_error) "checksum mismatch omitted UI error"
     | _ -> T.fail "checksum mismatch did not return visible sync state");
    T.require
      (String.equal
         (read_page engine "52000000-0000-4000-8000-000000000002").title
         "Oracle Page")
      "checksum pause made the current graph unusable or replaced it";
    let status = sync_status engine "52000000-0000-4000-8000-000000000003" in
    T.require (status.state = P.Sync_paused_state) "sync status did not expose pause";
    T.require (status.applied_server_t = 40) "paused status advanced server t";
    T.require (Option.is_some status.last_error) "paused status lost durable error";
    (match Engine.close engine with
     | Ok () -> ()
     | Error message -> T.fail "unable to close paused engine: %s" message);
    let reopened = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close reopened))
      (fun () ->
         let durable = sync_status reopened "52000000-0000-4000-8000-000000000004" in
         T.require (durable.state = P.Sync_paused_state) "pause was not durable";
         T.require
           (String.equal
              (read_page reopened "52000000-0000-4000-8000-000000000005").title
              "Oracle Page")
           "reopened paused mirror was not readable";
         match
           execute
             reopened
             (sync_request
                "52000000-0000-4000-8000-000000000006"
                (F.sync_pull_wire fixture ~title:"Still blocked"))
         with
         | P.Failed _ -> ()
         | _ -> T.fail "paused sync accepted another pull"))
;;

let local_graph_rejects_sync_receive_case () =
  F.with_snapshot (fun fixture ->
    let engine =
      match Engine.open_ ~dependencies:F.dependencies fixture.config with
      | Ok value -> value
      | Error _ -> T.fail "unable to open local engine"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         match
           execute
             engine
             (sync_request
                "53000000-0000-4000-8000-000000000001"
                {|{"type":"changed","t":1}|})
         with
         | P.Failed _ -> ()
         | _ -> T.fail "local graph accepted a sync transport envelope"))
;;

let hello_and_changed_request_pull_without_advancing_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let require_pull id payload =
           match execute engine (sync_request id payload) with
           | P.Succeeded
               { success = Sync_result { activity = Pull_required; applied_server_t; _ }
               ; _
               } ->
             T.require (applied_server_t = 40) "sync hint advanced the durable cursor"
           | _ -> T.fail "sync hint did not request a pull"
         in
         require_pull
           "54000000-0000-4000-8000-000000000001"
           {|{"type":"hello","t":41,"checksum":"ac9682b5e1f889e3"}|};
         require_pull "54000000-0000-4000-8000-000000000002" {|{"type":"changed","t":42}|};
         let status = sync_status engine "54000000-0000-4000-8000-000000000003" in
         T.require (status.applied_server_t = 40) "sync hints changed durable server t"))
;;

let encrypted_pull_unlocks_and_decrypts_in_memory_case () =
  F.with_synced (fun fixture ->
    let config =
      match fixture.F.sync_config.Config.target with
      | Config.Synced_graph target ->
        { fixture.sync_config with
          target =
            Synced_graph
              { target with
                e2ee =
                  Some
                    { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                    ; user_id = "cognito-user-1"
                    ; encrypted_graph_key = "wrapped-key-transit"
                    }
              }
        }
      | _ -> T.fail "synced fixture target changed"
    in
    let unlocks = ref [] in
    let crypto =
      { Logseq_db_worker.Sync_e2ee.unavailable_crypto with
        decrypt_aes_gcm =
          (fun ~key ~iv ~ciphertext ->
            T.require (String.equal key (String.make 32 'g')) "wrong graph key used";
            T.require (String.equal iv "iv") "encrypted value IV changed";
            T.require (String.equal ciphertext "ciphertext") "ciphertext changed";
            Ok
              (Codec.to_string
                 ~mode:Codec.Verbose
                 (Transit.String "Encrypted remote title")))
      }
    in
    let dependencies =
      { F.dependencies with
        crypto
      ; unlock_graph_key =
          (fun ~managed_sync_origin:_ ~user_id ~encrypted_graph_key ->
            unlocks := (user_id, encrypted_graph_key) :: !unlocks;
            Logseq_db_worker.Sync_graph_key.of_string (String.make 32 'g'))
      }
    in
    let engine =
      match Engine.open_ ~dependencies config with
      | Ok value -> value
      | Error error ->
        T.fail "encrypted mirror did not open: %s" (Logseq_db_worker.Error.message error)
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         T.require
           (!unlocks = [ "cognito-user-1", "wrapped-key-transit" ])
           "graph key was not unlocked exactly once for the signed-in user";
         let checksum =
           F.sync_pull_wire fixture ~title:"Encrypted remote title"
           |> Yojson.Safe.from_string
           |> Yojson.Safe.Util.member "checksum"
           |> Yojson.Safe.Util.to_string
         in
         let encrypted_value =
           Codec.to_string
             ~mode:Codec.Verbose
             (Transit.Array [ Binary "iv"; Binary "ciphertext" ])
         in
         let tx =
           Codec.to_string
             ~mode:Codec.Verbose
             (Transit.Array
                [ Transit.Array
                    [ Keyword "db/add"
                    ; Array
                        [ Keyword "block/uuid"
                        ; Uuid "11111111-1111-4111-8111-111111111111"
                        ]
                    ; Keyword "block/title"
                    ; String encrypted_value
                    ; Int 536870914
                    ]
                ])
         in
         let payload =
           Yojson.Safe.to_string
             (`Assoc
                 [ "type", `String "pull/ok"
                 ; "t", `Int 41
                 ; "checksum", `String checksum
                 ; ( "txs"
                   , `List
                       [ `Assoc
                           [ "t", `Int 41
                           ; "tx", `String tx
                           ; "outliner-op", `String "save-block"
                           ]
                       ] )
                 ])
         in
         (match
            execute engine (sync_request "55000000-0000-4000-8000-000000000001" payload)
          with
          | P.Succeeded { success = Sync_result { activity = Pull_applied; _ }; _ } -> ()
          | _ -> T.fail "encrypted pull was not applied");
         T.require
           (String.equal
              (read_page engine "55000000-0000-4000-8000-000000000002").title
              "Encrypted remote title")
           "decrypted pull did not reach the plaintext mirror"))
;;

let durable_optimistic_pending_and_echo_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    let basis = graph_basis engine "56000000-0000-4000-8000-000000000001" in
    let mutation_id = "26000000-0000-4000-8000-000000000001" in
    (match
       execute
         engine
         (save_page_request
            ~basis
            ~request_id:"56000000-0000-4000-8000-000000000002"
            ~mutation_id
            ~title:"Offline optimistic title")
     with
     | P.Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
     | _ -> T.fail "synced allowlisted mutation was not accepted");
    T.require
      (String.equal
         (read_page engine "56000000-0000-4000-8000-000000000003").title
         "Offline optimistic title")
      "pending mutation was not projected optimistically";
    (match Engine.close engine with
     | Ok () -> ()
     | Error message -> T.fail "close pending engine: %s" message);
    let reopened = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close reopened))
      (fun () ->
         T.require
           (String.equal
              (read_page reopened "56000000-0000-4000-8000-000000000004").title
              "Offline optimistic title")
           "optimistic pending mutation did not survive restart";
         let pending = sync_pending reopened "56000000-0000-4000-8000-000000000005" in
         T.require (pending.count = 1) "durable pending count changed";
         let payload = Option.get pending.payload |> Yojson.Safe.from_string in
         let open Yojson.Safe.Util in
         T.require (payload |> member "type" |> to_string = "tx/batch") "wrong batch type";
         T.require
           (payload
            |> member "txs"
            |> to_list
            |> List.hd
            |> member "tx-id"
            |> to_string
            = mutation_id)
           "tx/batch lost the stable mutation ID";
         (match
            execute
              reopened
              (sync_request
                 "56000000-0000-4000-8000-000000000006"
                 {|{"type":"tx/batch/ok","t":41,"checksum":"0000000000000000"}|})
          with
          | P.Succeeded { success = Sync_result { activity = Pull_required; _ }; _ } -> ()
          | _ -> T.fail "tx/batch acceptance did not request authoritative pull");
         T.require
           ((sync_pending reopened "56000000-0000-4000-8000-000000000007").payload = None)
           "accepted intent was resubmitted before its echo";
         let echo = F.sync_pull_wire fixture ~title:"Offline optimistic title" in
         (match
            execute reopened (sync_request "56000000-0000-4000-8000-000000000008" echo)
          with
          | P.Succeeded { success = Sync_result { activity = Pull_applied; _ }; _ } -> ()
          | _ -> T.fail "authoritative self echo was not applied");
         T.require
           ((sync_pending reopened "56000000-0000-4000-8000-000000000009").count = 0)
           "authoritative echo did not clear the accepted intent"))
;;

let submitted_batch_requeues_in_live_runtime_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis = graph_basis engine "56500000-0000-4000-8000-000000000001" in
         let mutation_id = F.uuid "26500000-0000-4000-8000-000000000001" in
         ignore
           (execute
              engine
              (save_page_request
                 ~basis
                 ~request_id:"56500000-0000-4000-8000-000000000002"
                 ~mutation_id:(Graph_types.Uuid.to_string mutation_id)
                 ~title:"Retry without restart"));
         T.require
           (Option.is_some
              (sync_pending engine "56500000-0000-4000-8000-000000000003").payload)
           "queued intent did not produce its first batch";
         T.require
           (Result.is_error
              (Engine.requeue_submitted
                 engine
                 ~mutation_ids:[ F.uuid "26500000-0000-4000-8000-000000000099" ]))
           "unknown submitted transaction ID was silently accepted";
         (match Engine.requeue_submitted engine ~mutation_ids:[ mutation_id ] with
          | Ok () -> ()
          | Error message -> T.fail "requeue submitted intent: %s" message);
         let retried = sync_pending engine "56500000-0000-4000-8000-000000000004" in
         let retried_id =
           Option.get retried.payload
           |> Yojson.Safe.from_string
           |> Yojson.Safe.Util.member "txs"
           |> Yojson.Safe.Util.to_list
           |> List.hd
           |> Yojson.Safe.Util.member "tx-id"
           |> Yojson.Safe.Util.to_string
         in
         T.require
           (String.equal retried_id (Graph_types.Uuid.to_string mutation_id))
           "live requeue changed the stable transaction ID";
         T.require
           ((sync_pending engine "56500000-0000-4000-8000-000000000005").payload = None)
           "submitted intent was emitted twice in one runtime"))
;;

let submitted_batch_resolves_from_authoritative_echo_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis = graph_basis engine "56700000-0000-4000-8000-000000000001" in
         let mutation_id = F.uuid "26700000-0000-4000-8000-000000000001" in
         ignore
           (execute
              engine
              (save_page_request
                 ~basis
                 ~request_id:"56700000-0000-4000-8000-000000000002"
                 ~mutation_id:(Graph_types.Uuid.to_string mutation_id)
                 ~title:"Accepted before suspension"));
         ignore (sync_pending engine "56700000-0000-4000-8000-000000000003");
         (match
            execute
              engine
              (sync_request
                 "56700000-0000-4000-8000-000000000004"
                 (F.sync_pull_wire fixture ~title:"Accepted before suspension"))
          with
          | P.Succeeded { success = Sync_result { activity = Pull_applied; _ }; _ } -> ()
          | _ -> T.fail "authoritative echo for submitted intent was not applied");
         T.require
           ((sync_pending engine "56700000-0000-4000-8000-000000000005").count = 1)
           "authoritative echo inferred acknowledgement before recovery";
         (match Engine.requeue_submitted engine ~mutation_ids:[ mutation_id ] with
          | Ok () -> ()
          | Error message -> T.fail "requeue submitted intent: %s" message);
         let recovered = sync_pending engine "56700000-0000-4000-8000-000000000006" in
         T.require
           (recovered.count = 0)
           "authoritative echo left an already-satisfied intent queued";
         T.require
           (recovered.payload = None)
           "authoritative echo produced a duplicate retry batch"))
;;

let submitted_batch_still_recovers_after_restart_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    let basis = graph_basis engine "56600000-0000-4000-8000-000000000001" in
    ignore
      (execute
         engine
         (save_page_request
            ~basis
            ~request_id:"56600000-0000-4000-8000-000000000002"
            ~mutation_id:"26600000-0000-4000-8000-000000000001"
            ~title:"Retry after restart"));
    ignore (sync_pending engine "56600000-0000-4000-8000-000000000003");
    (match Engine.close engine with
     | Ok () -> ()
     | Error message -> T.fail "close submitted engine: %s" message);
    let reopened = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close reopened))
      (fun () ->
         T.require
           (Option.is_some
              (sync_pending reopened "56600000-0000-4000-8000-000000000004").payload)
           "submitted intent was not recovered after restart"))
;;

let stale_rebases_same_id_and_partial_blocks_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let first_id = "27000000-0000-4000-8000-000000000001" in
         let first_basis = graph_basis engine "57000000-0000-4000-8000-000000000001" in
         ignore
           (execute
              engine
              (save_page_request
                 ~basis:first_basis
                 ~request_id:"57000000-0000-4000-8000-000000000002"
                 ~mutation_id:first_id
                 ~title:"Local rebased title"));
         ignore (sync_pending engine "57000000-0000-4000-8000-000000000003");
         (match
            execute
              engine
              (sync_request
                 "57000000-0000-4000-8000-000000000004"
                 {|{"type":"tx/reject","reason":"stale","t":41}|})
          with
          | P.Succeeded { success = Sync_result { activity = Pull_required; _ }; _ } -> ()
          | _ -> T.fail "stale rejection did not request pull");
         (match
            execute
              engine
              (sync_request
                 "57000000-0000-4000-8000-000000000005"
                 (F.sync_pull_wire fixture ~title:"Concurrent remote title"))
          with
          | P.Succeeded { success = Sync_result { activity = Pull_applied; _ }; _ } -> ()
          | _ -> T.fail "stale recovery pull was not applied");
         T.require
           (String.equal
              (read_page engine "57000000-0000-4000-8000-000000000006").title
              "Local rebased title")
           "stale recovery lost the optimistic intent";
         let retried = sync_pending engine "57000000-0000-4000-8000-000000000007" in
         let retried_id =
           Option.get retried.payload
           |> Yojson.Safe.from_string
           |> Yojson.Safe.Util.member "txs"
           |> Yojson.Safe.Util.to_list
           |> List.hd
           |> Yojson.Safe.Util.member "tx-id"
           |> Yojson.Safe.Util.to_string
         in
         T.require (String.equal retried_id first_id) "stale rebase changed the tx ID";
         let second_id = "27000000-0000-4000-8000-000000000002" in
         let second_basis = graph_basis engine "57000000-0000-4000-8000-000000000008" in
         ignore
           (execute
              engine
              (save_page_request
                 ~basis:second_basis
                 ~request_id:"57000000-0000-4000-8000-000000000009"
                 ~mutation_id:second_id
                 ~title:"Second pending title"));
         ignore (sync_pending engine "57000000-0000-4000-8000-000000000010");
         let rejection =
           Printf.sprintf
             {|{"type":"tx/reject","reason":"db transact failed","t":42,"success-tx-ids":["%s"],"failed-tx-id":"%s","data":"upstream validation detail"}|}
             first_id
             second_id
         in
         (match
            execute engine (sync_request "57000000-0000-4000-8000-000000000011" rejection)
          with
          | P.Succeeded
              { success =
                  Sync_result
                    { activity = Sync_submission_blocked; last_error = Some message; _ }
              ; _
              } ->
            T.require
              (String.equal
                 message
                 (Printf.sprintf
                    "Sync transaction batch partially rejected; accepted tx IDs: [%s]; \
                     failed tx ID: %s; server reason: db transact failed: upstream \
                     validation detail"
                    first_id
                    second_id))
              "partial rejection hid transaction IDs or the server reason"
          | _ -> T.fail "partial rejection did not block the pump visibly");
         let blocked = sync_pending engine "57000000-0000-4000-8000-000000000012" in
         T.require (blocked.payload = None) "blocked pump produced another batch";
         T.require (Option.is_some blocked.blocked_error) "blocked pump hid its error";
         let durable =
           Logseq_db_worker.Sync_pending.open_ ~graph_dir:fixture.graph_dir
           |> Result.get_ok
           |> Logseq_db_worker.Sync_pending.entries
         in
         T.require
           (List.exists
              (fun (entry : Logseq_db_worker.Sync_pending.entry) ->
                 Graph_types.Uuid.equal entry.mutation_id (F.uuid first_id)
                 && entry.state = Pending.Accepted 42)
              durable)
           "partial success was not retained until echo";
         T.require
           (List.exists
              (fun (entry : Logseq_db_worker.Sync_pending.entry) ->
                 Graph_types.Uuid.equal entry.mutation_id (F.uuid second_id)
                 &&
                 match entry.state with
                 | Pending.Blocked _ -> true
                 | _ -> false)
              durable)
           "failed partial transaction did not become durable blocked state"))
;;

let permanent_rejection_displays_server_error_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let mutation_id = "29000000-0000-4000-8000-000000000001" in
         let basis = graph_basis engine "59000000-0000-4000-8000-000000000001" in
         ignore
           (execute
              engine
              (save_page_request
                 ~basis
                 ~request_id:"59000000-0000-4000-8000-000000000002"
                 ~mutation_id
                 ~title:"Permanently rejected title"));
         ignore (sync_pending engine "59000000-0000-4000-8000-000000000003");
         let rejection =
           {|{"type":"tx/reject","reason":"invalid tx","data":"attribute is not allowed"}|}
         in
         (match
            execute engine (sync_request "59000000-0000-4000-8000-000000000004" rejection)
          with
          | P.Succeeded
              { success =
                  Sync_result
                    { activity = Sync_submission_blocked; last_error = Some message; _ }
              ; _
              } ->
            T.require
              (String.equal
                 message
                 "Sync service rejected the transaction (invalid tx): attribute is not \
                  allowed")
              "permanent rejection hid the server error"
          | _ -> T.fail "permanent rejection did not block the pump visibly");
         let blocked = sync_pending engine "59000000-0000-4000-8000-000000000005" in
         T.require (blocked.payload = None) "permanent rejection did not stop the pump";
         T.require
           (blocked.blocked_error
            = Some
                "Sync service rejected the transaction (invalid tx): attribute is not \
                 allowed")
           "permanent rejection did not persist the server error"))
;;

let complete_allowlist_is_durable_and_typed_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let page = F.uuid "11111111-1111-4111-8111-111111111111" in
         let journal_page = F.uuid "00000001-2026-0822-0000-000000000000" in
         let inserted = F.uuid "31000000-0000-4000-8000-000000000001" in
         let context mutation_id =
           P.
             { mutation_id = F.uuid mutation_id
             ; expected_basis = graph_basis engine "58000000-0000-4000-8000-000000000001"
             }
         in
         execute_allowlisted
           engine
           ~request_id:"58000000-0000-4000-8000-000000000002"
           ~mutation:
             (P.Page
                (Create_page
                   { title = "Aug 22nd, 2026"
                   ; kind =
                       Create_journal_page
                         { journal_day = 20260822; supplied_uuid = Some journal_page }
                   ; context = context "28000000-0000-4000-8000-000000000000"
                   }));
         execute_allowlisted
           engine
           ~request_id:"58000000-0000-4000-8000-000000000003"
           ~mutation:
             (P.Structural
                (Insert_blocks
                   { roots = [ { uuid = inserted; title = "Captured"; children = [] } ]
                   ; position = Relative (First_child page)
                   ; context = context "28000000-0000-4000-8000-000000000001"
                   }));
         execute_allowlisted
           engine
           ~request_id:"58000000-0000-4000-8000-000000000004"
           ~mutation:
             (P.Property
                (Set_property
                   { block = inserted
                   ; property = Property_by_ident "logseq.property/status"
                   ; value = Default_value "Todo"
                   ; context = context "28000000-0000-4000-8000-000000000002"
                   }));
         execute_allowlisted
           engine
           ~request_id:"58000000-0000-4000-8000-000000000005"
           ~mutation:
             (P.Property
                (Remove_property
                   { block = inserted
                   ; property = Property_by_ident "logseq.property/status"
                   ; context = context "28000000-0000-4000-8000-000000000003"
                   }));
         execute_allowlisted
           engine
           ~request_id:"58000000-0000-4000-8000-000000000006"
           ~mutation:
             (P.Structural
                (Delete_blocks
                   { roots = [ inserted ]
                   ; context = context "28000000-0000-4000-8000-000000000004"
                   }));
         let entries =
           Pending.open_ ~graph_dir:fixture.graph_dir |> Result.get_ok |> Pending.entries
         in
         T.require (List.length entries = 5) "allowlisted intents were not durable";
         T.require
           (List.map (fun (entry : Pending.entry) -> entry.outliner_op) entries
            = [ "create-page"
              ; "insert-blocks"
              ; "save-block"
              ; "save-block"
              ; "delete-blocks"
              ])
           "allowlisted intents used unexpected upstream operation labels";
         T.require
           (List.for_all
              (fun (entry : Pending.entry) ->
                 String.length entry.tx > 0 && not (String.contains entry.tx '\000'))
              entries)
           "allowlisted intents did not persist typed Transit transactions"))
;;

let ordinary_page_creation_stays_outside_allowlist_case () =
  F.with_synced (fun fixture ->
    let engine = open_engine fixture in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         let basis = graph_basis engine "59000000-0000-4000-8000-000000000001" in
         let mutation =
           P.Page
             (Create_page
                { title = "Not allowlisted"
                ; kind =
                    Create_ordinary_page
                      { uuid = F.uuid "32000000-0000-4000-8000-000000000001" }
                ; context =
                    { mutation_id = F.uuid "29000000-0000-4000-8000-000000000001"
                    ; expected_basis = basis
                    }
                })
         in
         let request =
           P.
             { api_version
             ; request_id = F.uuid "59000000-0000-4000-8000-000000000002"
             ; command = Mutate mutation
             }
         in
         match execute engine request with
         | P.Failed failure ->
           T.require
             (Logseq_db_worker.Error.code failure.error = Unsupported_semantics)
             "ordinary page creation returned the wrong synced rejection"
         | _ -> T.fail "ordinary page creation escaped the synced mutation allowlist"))
;;

let cases =
  [ T.case "apply foreground pull and preserve HTTP/WS parity" foreground_pull_case
  ; T.case
      "expose durable non-blocking checksum pause"
      checksum_pause_is_visible_and_readable_case
  ; T.case "reject sync envelopes for local graphs" local_graph_rejects_sync_receive_case
  ; T.case
      "request pull for hello and changed hints"
      hello_and_changed_request_pull_without_advancing_case
  ; T.case
      "unlock and decrypt encrypted pulls in memory"
      encrypted_pull_unlocks_and_decrypts_in_memory_case
  ; T.case
      "persist optimistic intents until authoritative echo"
      durable_optimistic_pending_and_echo_case
  ; T.case
      "requeue submitted batches in the live runtime with stable IDs"
      submitted_batch_requeues_in_live_runtime_case
  ; T.case
      "resolve submitted batches from authoritative echoes without retry"
      submitted_batch_resolves_from_authoritative_echo_case
  ; T.case
      "retain submitted recovery after runtime restart"
      submitted_batch_still_recovers_after_restart_case
  ; T.case
      "rebase stale intents and durably block partial failures"
      stale_rebases_same_id_and_partial_blocks_case
  ; T.case
      "display and persist permanent rejection server errors"
      permanent_rejection_displays_server_error_case
  ; T.case
      "persist the complete first-release mutation allowlist"
      complete_allowlist_is_durable_and_typed_case
  ; T.case
      "keep ordinary page creation outside the synced mutation allowlist"
      ordinary_page_creation_stays_outside_allowlist_case
  ]
;;

let () = T.run "sync engine" cases
