module W = Journal_worker_coordination.Worker_api
module C = Journal_worker_coordination.Worker_pure_coordinator
module R = Journal_worker_coordination.Worker_effect_runner
module Mailbox = Logseq_db_worker_lui.Journal_worker
module Runtime = Logseq_db_worker_lui.Journal_worker_runtime
module Id = Logseq_db_worker_lui.Journal_worker_ids
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module P = Logseq_db_worker.Protocol
module T = Logseq_db_worker_test_support.Test_support
module Sync = Logseq_sync_pure_reducer.Core
module SR = Logseq_sync_effect_runner.Effect_runner

let require condition message = if not condition then failwith message
let uuid value = W.Uuid.of_string value |> Result.get_ok
let second_graph = uuid "9c000000-0000-4000-8000-000000000003"
let client_id = uuid "9c000000-0000-4000-8000-000000000001"

let crypto =
  SR.crypto
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unused")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unused")
  |> Result.get_ok
;;

let secrets =
  SR.secrets
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
      Error "unused")
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      Error "unused")
    ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Error (SR.Wrapped_graph_key_unavailable "unused"))
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
      Error "unused")
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let with_client f =
  T.with_managed (fun fixture ->
    let root = fixture.config.application_support_directory in
    ignore (Test_support.seed_mirror root);
    ignore (Test_support.seed_mirror ~graph_id:second_graph root);
    let graph : Sync.graph =
      { graph_id = Test_support.graph_uuid
      ; name = "Coordination synthetic"
      ; encrypted = false
      ; schema = { major = 65; minor = 33; exact = true }
      }
    in
    let catalogs = Filename.concat root "logseq-db-worker/sync-catalogs" in
    Unix.mkdir catalogs 0o700;
    let key =
      Digestif.SHA256.digest_string "user-1\000https://api.logseq.io"
      |> Digestif.SHA256.to_hex
    in
    Out_channel.with_open_bin
      (Filename.concat catalogs (key ^ ".json"))
      (fun output ->
         output_string
           output
           (Sync.catalog_cache
              ~user_id:"user-1"
              ~graphs:
                [ graph
                ; { graph with
                    graph_id = second_graph
                  ; name = "Second coordination synthetic"
                  }
                ]
              ~selected_graph:(Some graph.graph_id)
            |> Sync.encode_catalog_cache));
    let deps =
      Service.dependencies
        ~overlay:fixture.overlay
        ~crypto
        ~secrets
        ~tls_authenticator:(SR.system_tls_authenticator () |> Result.get_ok)
    in
    let client =
      Runtime.start
        ~runtime_epoch:(Id.Runtime.Epoch.of_int64 9000L)
        (Service.create ~dependencies:deps)
        fixture.config
      |> Result.get_ok
    in
    Fun.protect ~finally:(fun () -> Runtime.stop client) (fun () -> f client))
;;

let test_client_to_typed_read () =
  with_client (fun client ->
    let events = Queue.create ()
    and state = ref (C.initial ~client_id) in
    let published = ref 0
    and deliveries = ref [] in
    let runner =
      R.create
        ~client
        ~managed_origin:"https://api.logseq.io"
        ~user_id:"user-1"
        ~post:(fun event -> Queue.add event events)
        ~publish:(fun _ -> incr published)
      |> Result.get_ok
    in
    let apply transition =
      state := transition.C.next;
      List.iter (R.submit runner) transition.instructions
    in
    Mailbox.on_event client (fun event ->
      let delivery = R.on_event runner event in
      deliveries := (event, delivery.R.disposition) :: !deliveries);
    let pump () =
      Mailbox.Private.deliver client ~max_events:64;
      let remaining = Queue.length events in
      for _ = 1 to remaining do
        apply (C.step !state (Queue.take events))
      done
    in
    let wait predicate =
      let deadline = Unix.gettimeofday () +. 4. in
      while (not (predicate ())) && Unix.gettimeofday () < deadline do
        pump ();
        Thread.delay 0.001
      done;
      require (predicate ()) "coordination did not reach expected runtime state"
    in
    wait (fun () ->
      match C.bootstrap (C.view !state) with
      | W.Bootstrap_not_ready _ -> true
      | _ -> false);
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Restore_local_account { user_id = "user-1" })));
    let current_session () =
      Option.bind
        (C.projection (C.view !state))
        (fun projection ->
           List.find_map
             (fun resident ->
                if resident.W.phase = W.Open then Some resident.session else None)
             (W.residents projection))
    in
    wait (fun () -> Option.is_some (current_session ()));
    let session = Option.get (current_session ()) in
    let budget =
      W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
    in
    let request operation =
      let ticket, transition = C.request !state session operation |> Result.get_ok in
      apply transition;
      wait (fun () -> Option.is_some (C.reply (C.view !state) ticket));
      ticket, C.reply (C.view !state) ticket |> Option.get
    in
    let info_ticket, info = request (W.Query (budget, W.Graph_info)) in
    (match info with
     | W.Answered (Ok info) ->
       require
         (W.Uuid.equal info.graph_uuid Test_support.graph_uuid)
         "typed graph identity mismatch"
     | _ -> failwith "graph info failed");
    let _, page =
      request
        (W.Query (budget, W.Page { uuid = Test_support.page_uuid; revision = None }))
    in
    (match page with
     | W.Answered (Ok (P.V2_present_page { page; _ })) ->
       require (page.uuid = Test_support.page_uuid) "page DTO lost identity"
     | _ -> failwith "page lookup failed");
    let _, children =
      request
        (W.Query
           ( budget
           , W.Child_members
               { parent = Test_support.page_uuid; revision = None; after = None } ))
    in
    let next =
      match children with
      | W.Answered (Ok children) ->
        require
          (List.length children.items = 1 && Option.is_some children.next)
          "bounded children lost More";
        Option.get children.next
      | _ -> failwith "children lookup failed"
    in
    let _, continued =
      request
        (W.Query
           ( budget
           , W.Child_members
               { parent = Test_support.page_uuid; revision = None; after = Some next } ))
    in
    (match continued with
     | W.Answered (Ok children) ->
       require (List.length children.items = 1) "continuation failed"
     | _ -> failwith "typed continuation failed");
    (match
       C.request
         !state
         session
         (W.Query
            ( budget
            , W.Child_members
                { parent = Test_support.authoritative_block_uuid
                ; revision = None
                ; after = Some next
                } ))
     with
     | Error (W.Invalid_input _) -> ()
     | _ -> failwith "foreign parent accepted continuation");
    let _, summary =
      request
        (W.Query
           ( budget
           , W.Block_summary
               { block = Test_support.authoritative_block_uuid; after = None } ))
    in
    (match summary with
     | W.Answered (Ok summary) ->
       require (Option.is_some summary.page) "atomic summary lost owning page";
       (match summary.lookup, summary.page with
        | P.V2_present_block { value; revision }, Some (P.V2_present_page { page; _ }) ->
          require
            (revision <> "" && value.block.title = "Authoritative block")
            "full DTO lost source/revision";
          let projected =
            Journal_graph_projection.block_on_page
              ~page
              ~revision
              ~child_count:(List.length summary.items)
              ~time_context:{ localtime = Unix.gmtime }
              value.block
            |> Result.get_ok
          in
          require
            (Journal_model.source projected = "Authoritative block")
            "actual App projection lost typed DTO source"
        | _ -> failwith "atomic summary missing canonical block")
     | _ -> failwith "atomic summary failed");
    let baseline =
      List.find_map
        (fun (event, _) ->
           match event with
           | Mailbox.Push { payload = Service.Coordination_updates updates; _ } ->
             List.find_map
               (function
                 | Service.Coordination_snapshot b
                   when Option.is_some b.baseline.state.sync.selected
                        && List.exists
                             (fun (_, g) -> g.Logseq_db_worker.phase = Graph_open)
                             b.baseline.state.residents -> Some b
                 | _ -> None)
               updates
           | _ -> None)
        !deliveries
      |> Option.get
    in
    let revision =
      match summary with
      | W.Answered (Ok { lookup = P.V2_present_block { revision; _ }; _ }) -> revision
      | _ -> assert false
    in
    let mutation_request : P.request =
      { api_version = P.api_version
      ; request_id = uuid "9c000000-0000-4000-8000-000000000004"
      ; command =
          V2_save_block
            { mutation_id = uuid "9c000000-0000-4000-8000-000000000005"
            ; block = Test_support.authoritative_block_uuid
            ; title = "Read capability must not write"
            ; preconditions =
                { blocks = [ Test_support.authoritative_block_uuid, revision ]
                ; pages = []
                ; scopes = []
                }
            }
      }
    in
    let actual =
      match
        Mailbox.send
          client
          (Service.Coordination_query
             { registration = baseline.registration
             ; owner = Option.get baseline.baseline.state.sync.selected
             ; request = mutation_request
             })
      with
      | Accepted id -> id
      | _ -> failwith "negative test transport was not admitted"
    in
    let outcome () =
      List.find_map
        (function
          | Mailbox.Response { request_id; outcome; _ }, _
            when Id.Worker.Request_id.equal request_id actual -> Some outcome
          | _ -> None)
        !deliveries
    in
    wait (fun () -> Option.is_some (outcome ()));
    require
      (match outcome () with
       | Some (Mailbox.Failed _) -> true
       | _ -> false)
      "backend accepted a mutation through a read-only registration";
    let _, unchanged =
      request
        (W.Query
           ( budget
           , W.Outline_block
               { uuid = Test_support.authoritative_block_uuid; revision = None } ))
    in
    (match unchanged with
     | W.Answered (Ok (P.V2_present_block { value; _ })) ->
       require
         (value.block.title = "Authoritative block")
         "rejected read capability altered storage"
     | _ -> failwith "guard verification read failed");
    let tiny = W.read_budget session ~maximum_items:1 ~maximum_bytes:1 |> Result.get_ok in
    let _, oversized = request (W.Query (tiny, W.Graph_info)) in
    (match oversized with
     | W.Answered (Error W.Response_budget_exceeded) -> ()
     | _ -> failwith "oversized singleton was not rejected");
    let owned =
      List.find_map
        (function
          | (Mailbox.Response _, R.Consumed) as pair -> Some (fst pair)
          | _ -> None)
        !deliveries
      |> Option.get
    in
    require
      ((R.on_event runner owned).disposition = R.Consumed)
      "owned duplicate fell through";
    require
      (List.exists (fun (_, d) -> d = R.Unowned_response) !deliveries)
      "legacy response ownership disappeared";
    let forgotten = C.step !state (C.Forget info_ticket) in
    apply forgotten;
    require
      (C.reply (C.view !state) info_ticket = None)
      "forgotten ticket retained rendering result";
    require (!published > 0) "coordinator did not publish";
    ignore
      (Mailbox.send
         client
         (Service.Client_command
            (Configure_resident_graphs [ Test_support.graph_uuid; second_graph ])));
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun p ->
          List.length (W.residents p) = 2
          && List.for_all (fun r -> r.W.phase = W.Open) (W.residents p))
        (C.projection (C.view !state)));
    let selected () = Option.bind (C.projection (C.view !state)) W.selected in
    let initial_presentation = Option.map W.presentation_generation (selected ()) in
    ignore
      (Mailbox.send client (Service.Client_command (Focus_resident_graph second_graph)));
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun p -> W.graph_id (W.presentation_session p) = second_graph)
        (selected ()));
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Focus_resident_graph Test_support.graph_uuid)));
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun p ->
          W.graph_id (W.presentation_session p) = Test_support.graph_uuid
          && Some (W.presentation_generation p) <> initial_presentation)
        (selected ()));
    require
      (Option.fold
         ~none:false
         ~some:(fun p -> W.equal_session (W.presentation_session p) session)
         (selected ()))
      "focus roundtrip revoked resident execution instead of presentation";
    apply (C.step !state C.Retry_bootstrap);
    require
      (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
      "retry admitted old session";
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun next -> not (W.equal_session next session))
        (current_session ()));
    require
      ((R.on_event runner owned).disposition = R.Consumed)
      "rebind lost old response ownership";
    let replacement = Option.get (current_session ()) in
    let next_budget =
      W.read_budget replacement ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
    in
    let ticket, transition =
      C.request !state replacement (W.Query (next_budget, W.Graph_info)) |> Result.get_ok
    in
    apply transition;
    apply (C.step !state (C.Cancel ticket));
    apply (C.step !state (C.Forget ticket));
    require
      (R.shutdown runner = R.Draining)
      "shutdown fabricated immediate unregister ACK";
    wait (fun () -> R.shutdown runner = R.Stopped);
    require
      (C.reply (C.view !state) ticket = None)
      "late cancelled read revived a forgotten consumer")
;;

let () =
  test_client_to_typed_read ();
  print_endline "Worker coordination real client/read/cleanup passed"
;;
