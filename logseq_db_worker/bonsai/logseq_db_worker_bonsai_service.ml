module Db = Logseq_db_worker
module Api = Logseq_sync.Api
module Engine = Db.Engine
module Protocol = Db.Protocol
module ID = Bonsai_flutter_spec.Id

type client_command =
  | Restore_local_account of { user_id : string }
  | Reconcile_authenticated_user of { user_id : string option }
  | Acknowledge_local_feed
  | Acknowledge_timeline_presented
  | Provide_token of
      { request : Api.token_request
      ; token : string
      }
  | Reject_token of Api.token_request
  | Select_graph of Api.graph_id
  | Return_to_graph_picker
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password of string
  | Delete_local_cache of Api.graph_id
  | Set_foreground of bool

type request =
  | Client_command of client_command
  | Graph_request of Protocol.request
  | Get_graph_state

type response =
  | Client_state of Api.state
  | Graph_response of Protocol.response
  | Graph_state of Db.graph_state

type push =
  | Graph_push of Protocol.push
  | Client_state_changed of Api.state
  | Need_id_token of Api.token_request
  | Bootstrap_progress of Api.bootstrap_progress
  | Graph_state_changed of Db.graph_state

let invalidation_topic = ID.Worker.Push_topic.of_int 0
let manager_topic = ID.Worker.Push_topic.of_int 1
let auth_topic = ID.Worker.Push_topic.of_int 2
let bootstrap_topic = ID.Worker.Push_topic.of_int 3
let graph_state_topic = ID.Worker.Push_topic.of_int 4

let random_key () =
  let channel = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel 32 |> Bytes.of_string)
;;

type dependencies =
  { engine : Engine.dependencies
  ; secrets : Api.secrets
  ; crypto : Api.crypto
  }

let dependencies ~engine ~secrets ~crypto = { engine; secrets; crypto }

let production_dependencies () =
  let engine =
    Engine.
      { clocks =
          { epoch_ms = (fun () -> Unix.gettimeofday () *. 1_000. |> Int64.of_float)
          ; monotonic_ns = Mtime_clock.elapsed_ns
          }
      ; cursor_authentication_key = random_key ()
      }
  in
  let secrets = Api.apple_secrets () |> Result.get_ok in
  let crypto = Api.apple_crypto () |> Result.get_ok in
  { engine; secrets; crypto }
;;

let take count values =
  let rec loop remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop count [] values
;;

let protocol_invalidation (invalidation : Api.invalidation) =
  let rec fit limit =
    let changed_uuids = take limit invalidation.changed_uuids in
    let push =
      Protocol.Graph_invalidated
        { basis = invalidation.basis
        ; changed_uuids
        ; changed_uuids_truncated =
            invalidation.changed_uuids_truncated
            || List.length changed_uuids < List.length invalidation.changed_uuids
        ; invalidate_graph_info = true
        ; invalidate_pages = true
        ; invalidate_tags = true
        ; invalidate_properties = true
        ; invalidate_tasks = true
        ; invalidate_references = true
        }
    in
    let bytes = Protocol.push_to_yojson push |> Yojson.Safe.to_string |> String.length in
    if bytes <= Protocol.maximum_push_bytes
    then push
    else if limit = 0
    then failwith "sync invalidation metadata exceeds its protocol budget"
    else fit (limit / 2)
  in
  fit (List.length invalidation.changed_uuids)
;;

let mutation_invalidation (success : Logseq_db_types.Mutation.success) =
  Api.
    { basis = success.basis_after
    ; changed_uuids = success.changed_uuids
    ; changed_uuids_truncated = success.changed_uuids_truncated
    }
;;

let graph_failure (request : Protocol.request) message =
  let error =
    Db.Error.create ~code:Db.Error.Closed_session ~message ~details:[] |> Result.get_ok
  in
  Protocol.failed ~request_id:request.request_id ~phase:Execute ~basis:None error
;;

let config_for_graph config request =
  let graph = Api.graph_open_request_graph request in
  Db.Config.create
    ~application_support_directory:config.Db.Config.application_support_directory
    ~target:
      (Synced_mirror
         { graph_id = graph.graph_id
         ; graph_name = graph.name
         ; graph_dir = Api.graph_open_request_graph_directory request
         ; database_path = Api.graph_open_request_database_path request
         ; checkpoint = Api.graph_open_request_checkpoint request
         })
    ~compatibility_profile:config.compatibility_profile
    ~response_budget_bytes:config.response_budget_bytes
    ~default_page_size:config.default_page_size
;;

let publish_graph_state context lifecycle =
  Worker.Session_context.emit
    context
    ~topic:graph_state_topic
    (Graph_state_changed (Db.Graph_lifecycle.state lifecycle))
;;

module Managed_coordinator = struct
  type t =
    { client : Api.t
    ; local_store : Api.local_store
    ; mutable engine : Engine.t option
    ; context : push Worker.Session_context.t
    ; graph_lifecycle : Db.Graph_lifecycle.t
    ; engine_dependencies : Engine.dependencies
    ; config : Db.Config.t
    ; post_effect : Api.sync_effect -> unit
    ; lock : Eio.Mutex.t
    ; mutable account_generation : int
    ; mutable graph_generation : int
    ; mutable presentation_generation : int
    ; mutable connection_generation : int
    ; mutable lifecycle_generation : int64
    }

  let publish_state t state =
    let startup = state.Api.snapshot.startup in
    if
      t.account_generation <> startup.account_generation
      || t.graph_generation <> startup.graph_generation
    then t.connection_generation <- 0;
    t.account_generation <- startup.account_generation;
    t.graph_generation <- startup.graph_generation;
    t.presentation_generation <- startup.presentation_generation;
    Worker.Session_context.emit
      t.context
      ~topic:manager_topic
      (Client_state_changed state)
  ;;

  let close_engine t generation =
    match t.engine with
    | None -> ()
    | Some engine ->
      t.engine <- None;
      Db.Graph_lifecycle.begin_close t.graph_lifecycle ~generation;
      publish_graph_state t.context t.graph_lifecycle;
      (match Engine.close engine with
       | Ok () ->
         Db.Graph_lifecycle.closed t.graph_lifecycle ~generation;
         publish_graph_state t.context t.graph_lifecycle
       | Error message ->
         Db.Graph_lifecycle.failed t.graph_lifecycle ~generation ~message;
         publish_graph_state t.context t.graph_lifecycle)
  ;;

  let attach_graph t request =
    let account_generation = Api.graph_open_request_account_generation request in
    let graph_generation = Api.graph_open_request_generation request in
    if account_generation = t.account_generation && graph_generation = t.graph_generation
    then (
      close_engine t graph_generation;
      let graph_id = Some (Api.graph_open_request_graph request).graph_id in
      Db.Graph_lifecycle.begin_open
        t.graph_lifecycle
        ~generation:graph_generation
        ~graph_id;
      publish_graph_state t.context t.graph_lifecycle;
      match config_for_graph t.config request with
      | Error message ->
        Db.Graph_lifecycle.failed t.graph_lifecycle ~generation:graph_generation ~message;
        publish_graph_state t.context t.graph_lifecycle;
        Api.handle
          t.client
          (Graph_attachment_failed { account_generation; graph_generation; message })
        |> List.iter t.post_effect
      | Ok graph_config ->
        (match Engine.open_ ~dependencies:t.engine_dependencies graph_config with
         | Error error ->
           let message = Db.Error.message error in
           Db.Graph_lifecycle.failed
             t.graph_lifecycle
             ~generation:graph_generation
             ~message;
           publish_graph_state t.context t.graph_lifecycle;
           Api.handle
             t.client
             (Graph_attachment_failed { account_generation; graph_generation; message })
           |> List.iter t.post_effect
         | Ok engine ->
           t.engine <- Some engine;
           let restored =
             Result.bind (Engine.sync_checkpoint engine) (fun checkpoint ->
               Result.bind (Engine.managed_outbox_records engine) (fun outbox_records ->
                 Result.bind (Engine.projected_database engine) (fun database ->
                   Result.bind
                     (Api.restore_outbox_projection t.client ~database ~outbox_records)
                     (fun transactions ->
                        Result.map
                          (fun _ -> checkpoint, outbox_records)
                          (Engine.restore_managed_outbox engine transactions)))))
           in
           (match restored with
            | Error message ->
              close_engine t graph_generation;
              Db.Graph_lifecycle.failed
                t.graph_lifecycle
                ~generation:graph_generation
                ~message;
              publish_graph_state t.context t.graph_lifecycle;
              Api.handle
                t.client
                (Graph_attachment_failed { account_generation; graph_generation; message })
              |> List.iter t.post_effect
            | Ok (checkpoint, outbox_records) ->
              Db.Graph_lifecycle.opened t.graph_lifecycle ~generation:graph_generation;
              publish_graph_state t.context t.graph_lifecycle;
              Api.handle
                t.client
                (Graph_attached
                   { account_generation; graph_generation; checkpoint; outbox_records })
              |> List.iter t.post_effect)))
  ;;

  let rec handle_effect_unlocked t = function
    | Api.State_changed state -> publish_state t state
    | Token_requested request ->
      Worker.Session_context.emit t.context ~topic:auth_topic (Need_id_token request)
    | Bootstrap_progressed progress ->
      Worker.Session_context.emit
        t.context
        ~topic:bootstrap_topic
        (Bootstrap_progress progress)
    | Graph_invalidated invalidation ->
      Worker.Session_context.emit
        t.context
        ~topic:invalidation_topic
        (Graph_push (protocol_invalidation invalidation))
    | Attach_graph request -> attach_graph t request
    | Detach_graph { graph_generation } ->
      if graph_generation = t.graph_generation then close_engine t graph_generation
    | Apply_authoritative_batch batch ->
      let ( account_generation
          , graph_generation
          , connection_generation
          , presentation_generation
          , lifecycle_generation )
        =
        Api.authoritative_batch_scope batch
      in
      if
        account_generation = t.account_generation
        && graph_generation = t.graph_generation
        && connection_generation >= t.connection_generation
        && presentation_generation = t.presentation_generation
        && lifecycle_generation = t.lifecycle_generation
      then (
        match t.engine with
        | None -> ()
        | Some engine ->
          t.connection_generation <- connection_generation;
          let planned =
            Result.bind (Engine.sync_checkpoint engine) (fun checkpoint ->
              Result.bind (Engine.authoritative_database engine) (fun database ->
                Result.bind (Engine.managed_outbox_records engine) (fun outbox_records ->
                  Api.plan_authoritative_batch
                    t.client
                    batch
                    ~checkpoint
                    ~database
                    ~outbox_records)))
          in
          (match planned with
           | Error message ->
             handle_event_unlocked
               t
               (Api.Authoritative_batch_failed
                  { account_generation; graph_generation; message })
           | Ok (No_authoritative_commit { checkpoint; outbox_records; activity }) ->
             handle_event_unlocked
               t
               (Api.Authoritative_batch_applied
                  { account_generation
                  ; graph_generation
                  ; checkpoint
                  ; outbox_records
                  ; activity
                  ; invalidation = None
                  })
           | Ok
               (Commit_authoritative
                  { transactions; checkpoint; outbox_records; activity }) ->
             (match
                Result.bind
                  (Engine.apply_authoritative
                     engine
                     transactions
                     ~checkpoint
                     ~outbox_records)
                  (fun (basis_before, _basis_after, changed_uuids, database) ->
                     Result.bind
                       (Api.restore_outbox_projection t.client ~database ~outbox_records)
                       (fun projected_transactions ->
                          Result.map
                            (fun _ ->
                               let basis_after =
                                 Engine.basis engine |> Option.value ~default:basis_before
                               in
                               basis_before, basis_after, changed_uuids, database)
                            (Engine.restore_managed_outbox engine projected_transactions)))
              with
              | Error message ->
                handle_event_unlocked
                  t
                  (Api.Authoritative_batch_failed
                     { account_generation; graph_generation; message })
              | Ok (_basis_before, basis_after, changed_uuids, _database) ->
                let changed_uuids_truncated = List.length changed_uuids > 4096 in
                let changed_uuids = take 4096 changed_uuids in
                handle_event_unlocked
                  t
                  (Api.Authoritative_batch_applied
                     { account_generation
                     ; graph_generation
                     ; checkpoint
                     ; outbox_records
                     ; activity
                     ; invalidation =
                         (if transactions = []
                          then None
                          else
                            Some
                              { basis = basis_after
                              ; changed_uuids
                              ; changed_uuids_truncated
                              })
                     }))))
    | Commit_outbox_transition transition ->
      let ( account_generation
          , graph_generation
          , presentation_generation
          , lifecycle_generation )
        =
        Api.outbox_transition_scope transition
      in
      if
        account_generation = t.account_generation
        && graph_generation = t.graph_generation
        && presentation_generation = t.presentation_generation
        && lifecycle_generation = t.lifecycle_generation
      then (
        match t.engine with
        | None -> ()
        | Some engine ->
          let outbox_records = Api.outbox_transition_records transition in
          let expected = Api.outbox_transition_expected_records transition in
          (match Engine.commit_outbox_transition engine ~expected outbox_records with
           | Error message ->
             let current =
               Engine.managed_outbox_records engine
               |> Result.fold ~ok:Fun.id ~error:(fun _ -> expected)
             in
             handle_event_unlocked
               t
               (Api.Outbox_transition_rejected { outbox_records = current; message })
           | Ok () ->
             handle_event_unlocked
               t
               (Api.Outbox_transition_committed
                  { outbox_records
                  ; pending_payload = Api.outbox_transition_pending_payload transition
                  })))
    | Run_local_operation operation ->
      Api.run_local_operation t.client t.local_store operation
      |> List.iter (handle_effect_unlocked t)
    | Resume completion ->
      Api.resume t.client completion |> List.iter (handle_effect_unlocked t)

  and handle_event_unlocked t event =
    (match event with
     | Api.Foreground_changed false ->
       t.lifecycle_generation <- Int64.succ t.lifecycle_generation
     | Restore_local_account _
     | Account_authenticated _
     | Local_feed_acknowledged
     | Timeline_presented
     | Token_provided _
     | Token_rejected _
     | Graph_selected _
     | Graph_picker_requested
     | Catalog_refresh_requested
     | Online_recovery_requested
     | E2ee_password_submitted _
     | Local_cache_deletion_requested _
     | Foreground_changed true
     | Graph_attached _
     | Graph_attachment_failed _
     | Local_batch_committed _
     | Authoritative_batch_applied _
     | Authoritative_batch_failed _
     | Outbox_transition_committed _
     | Outbox_transition_rejected _
     | Shutdown -> ());
    ignore (t.presentation_generation, t.lifecycle_generation);
    Api.handle t.client event |> List.iter (handle_effect_unlocked t)
  ;;

  let handle t event =
    Eio.Mutex.use_rw ~protect:true t.lock (fun () -> handle_event_unlocked t event)
  ;;

  let dispatch_effect t output =
    Eio.Mutex.use_rw ~protect:true t.lock (fun () -> handle_effect_unlocked t output)
  ;;

  let mutation_failure (request : Protocol.request) engine code message =
    let error = Db.Error.create ~code ~message ~details:[] |> Result.get_ok in
    Protocol.failed
      ~request_id:request.Protocol.request_id
      ~phase:Execute
      ~basis:(Engine.basis engine)
      error
  ;;

  let mutate t engine mutation =
    let mutation_id = (Logseq_db_types.Mutation.context mutation).mutation_id in
    let mutation_fingerprint =
      Logseq_db_types.Mutation.to_yojson mutation |> Yojson.Safe.to_string
    in
    Result.bind (Engine.managed_outbox_records engine) (fun encoded_outbox ->
      Result.bind (Api.decode_outbox_records encoded_outbox) (fun outbox ->
        match
          List.find_opt
            (fun record ->
               Logseq_db_types.Graph_types.Uuid.equal
                 (Api.outbox_record_mutation_id record)
                 mutation_id)
            outbox
        with
        | Some record
          when String.equal (Api.outbox_record_fingerprint record) mutation_fingerprint ->
          Engine.duplicate_managed_mutation engine mutation
        | Some _ ->
          Error "The mutation ID is already used by another durable outbox record."
        | None ->
          Result.bind (Engine.prepare_managed_mutation engine mutation) (fun prepared ->
            let commit records =
              Result.bind (Api.encode_outbox_records records) (fun outbox_records ->
                Result.bind
                  (Engine.commit_managed_mutation engine prepared ~outbox_records)
                  (fun success ->
                     handle_event_unlocked
                       t
                       (Api.Local_batch_committed { outbox_records });
                     Ok success))
            in
            if Engine.prepared_mutation_operations prepared = []
            then commit outbox
            else
              Result.bind
                (Api.prepare_local_batch
                   t.client
                   ~outbox
                   ~mutation_id
                   ~mutation_payload:(Engine.prepared_mutation_payload prepared)
                   ~mutation_fingerprint
                   ~outliner_op:(Engine.prepared_mutation_outliner_op prepared)
                   ~database:(Engine.prepared_mutation_database prepared)
                   ~operations:(Engine.prepared_mutation_operations prepared))
                commit)))
  ;;

  let execute_graph_request_unlocked t request =
    match request.Protocol.command, t.engine with
    | _, None -> graph_failure request "no graph is open"
    | Mutate mutation, Some engine ->
      (match mutate t engine mutation with
       | Ok success ->
         if success.Logseq_db_types.Mutation.status = Applied
         then
           Worker.Session_context.emit
             t.context
             ~topic:invalidation_topic
             (Graph_push (protocol_invalidation (mutation_invalidation success)));
         Succeeded
           { request_id = request.request_id
           ; basis = success.basis_after
           ; success = Mutation_result success
           }
       | Error message ->
         mutation_failure request engine Db.Error.Unsupported_semantics message)
    | Read _, Some engine -> Engine.execute engine request
  ;;

  let execute_graph_request t request =
    Eio.Mutex.use_rw ~protect:true t.lock (fun () ->
      execute_graph_request_unlocked t request)
  ;;
end

type managed = Managed_coordinator.t

type invalidation_dispatcher =
  { wake : Eio.Condition.t
  ; mutable pending : Protocol.push option
  }

type state =
  | Managed of managed
  | Graph_bound of
      { engine : Engine.t option
      ; open_error : Db.Error.t option
      ; invalidations : invalidation_dispatcher
      ; graph_lifecycle : Db.Graph_lifecycle.t
      ; context : push Worker.Session_context.t
      }

let enqueue_invalidation dispatcher push =
  dispatcher.pending <- Some push;
  Eio.Condition.broadcast dispatcher.wake
;;

let rec dispatch_invalidations context dispatcher =
  let push =
    Eio.Condition.loop_no_mutex dispatcher.wake (fun () ->
      match dispatcher.pending with
      | None -> None
      | Some push ->
        dispatcher.pending <- None;
        Some push)
  in
  Worker.Session_context.emit context ~topic:invalidation_topic (Graph_push push);
  dispatch_invalidations context dispatcher
;;

let client_event = function
  | Restore_local_account { user_id } -> Api.Restore_local_account { user_id }
  | Reconcile_authenticated_user { user_id } -> Api.Account_authenticated { user_id }
  | Acknowledge_local_feed -> Api.Local_feed_acknowledged
  | Acknowledge_timeline_presented -> Api.Timeline_presented
  | Provide_token { request; token } -> Api.Token_provided (request, token)
  | Reject_token request -> Api.Token_rejected request
  | Select_graph graph_id -> Api.Graph_selected graph_id
  | Return_to_graph_picker -> Api.Graph_picker_requested
  | Refresh_catalog -> Api.Catalog_refresh_requested
  | Begin_online_recovery -> Api.Online_recovery_requested
  | Submit_e2ee_password password -> Api.E2ee_password_submitted password
  | Delete_local_cache graph_id -> Api.Local_cache_deletion_requested graph_id
  | Set_foreground foreground -> Api.Foreground_changed foreground
;;

let dependency_error_message = function
  | Api.Invalid_dependency message -> message
;;

let config_error_message = function
  | Api.Invalid_config message -> message
;;

let create_error_message = function
  | Api.Invalid_create message -> message
;;

let create ~(dependencies : dependencies) =
  Worker.Service.create
    ~push_topic_count:5
    ~concurrency:Worker.Service.Serial
    ~data_directory:(fun config -> Ok config.Db.Config.application_support_directory)
    ~init:(fun context config ->
      match Worker.Session_context.data_dir context with
      | None -> Error "application-support data directory capability is unavailable"
      | Some _ ->
        (match config.Db.Config.target with
         | Managed_sync { base_url } ->
           let graph_lifecycle = Db.Graph_lifecycle.create () in
           let effects = Eio.Stream.create 256 in
           let environment = Worker.Session_context.environment context in
           let clock = Eio.Stdenv.clock environment in
           let construct =
             Result.bind
               (Api.runtime
                  ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
                  ~sleep:(Eio.Time.sleep clock)
                  ~monotonic_ns:Mtime_clock.elapsed_ns)
               (fun runtime ->
                  Result.bind
                    (Api.transport ~network:(Eio.Stdenv.net environment) ~clock)
                    (fun transport ->
                       Result.bind
                         (Api.local_store
                            ~application_support_directory:
                              config.application_support_directory)
                         (fun local_store ->
                            Result.bind
                              (Api.artifact_store
                                 ~staging_directory:
                                   (Filename.concat
                                      config.application_support_directory
                                      "sync-staging"))
                              (fun artifact_store ->
                                 Result.map
                                   (fun api_dependencies -> local_store, api_dependencies)
                                   (Api.dependencies
                                      ~runtime
                                      ~transport
                                      ~artifact_store
                                      ~secrets:dependencies.secrets
                                      ~crypto:dependencies.crypto
                                      ~on_effect:(Eio.Stream.add effects))))))
           in
           (match construct with
            | Error error -> Error (dependency_error_message error)
            | Ok (local_store, api_dependencies) ->
              (match
                 Api.limits
                   ~maximum_response_bytes:config.response_budget_bytes
                   ~maximum_artifact_bytes:(1024 * 1024 * 1024)
                   ~submission_batch_size:32
               with
               | Error error -> Error (config_error_message error)
               | Ok limits ->
                 (match
                    Api.config ~managed_sync_origin:(Uri.of_string base_url) ~limits
                  with
                  | Error error -> Error (config_error_message error)
                  | Ok api_config ->
                    (match
                       Api.create
                         ~sw:(Worker.Session_context.switch context)
                         api_config
                         api_dependencies
                     with
                     | Error error -> Error (create_error_message error)
                     | Ok client ->
                       let startup = (Api.state client).snapshot.startup in
                       let coordinator =
                         Managed_coordinator.
                           { client
                           ; local_store
                           ; engine = None
                           ; context
                           ; graph_lifecycle
                           ; engine_dependencies = dependencies.engine
                           ; config
                           ; post_effect = Eio.Stream.add effects
                           ; lock = Eio.Mutex.create ()
                           ; account_generation = startup.account_generation
                           ; graph_generation = startup.graph_generation
                           ; presentation_generation = startup.presentation_generation
                           ; connection_generation = 0
                           ; lifecycle_generation = 0L
                           }
                       in
                       Worker.Session_context.fork_daemon
                         context
                         ~name:"managed-sync-effects"
                         (fun () ->
                            let rec loop () =
                              Managed_coordinator.dispatch_effect
                                coordinator
                                (Eio.Stream.take effects);
                              loop ()
                            in
                            loop ());
                       Ok (Managed coordinator)))))
         | Snapshot _ | Import_snapshot _ | Synced_mirror _ | Native_local_graph _ ->
           let invalidations = { wake = Eio.Condition.create (); pending = None } in
           let graph_lifecycle = Db.Graph_lifecycle.create () in
           Db.Graph_lifecycle.begin_open graph_lifecycle ~generation:0 ~graph_id:None;
           Worker.Session_context.fork_daemon
             context
             ~name:"graph-invalidations"
             (fun () -> dispatch_invalidations context invalidations);
           (match Engine.open_ ~dependencies:dependencies.engine config with
            | Ok engine ->
              Db.Graph_lifecycle.opened graph_lifecycle ~generation:0;
              Ok
                (Graph_bound
                   { engine = Some engine
                   ; open_error = None
                   ; invalidations
                   ; graph_lifecycle
                   ; context
                   })
            | Error error ->
              Db.Graph_lifecycle.failed
                graph_lifecycle
                ~generation:0
                ~message:(Db.Error.message error);
              Ok
                (Graph_bound
                   { engine = None
                   ; open_error = Some error
                   ; invalidations
                   ; graph_lifecycle
                   ; context
                   }))))
    ~handle:(fun _context state request ->
      match state with
      | Managed managed ->
        (match request with
         | Get_graph_state ->
           Ok (Graph_state (Db.Graph_lifecycle.state managed.graph_lifecycle))
         | Client_command command ->
           Managed_coordinator.handle managed (client_event command);
           Ok (Client_state (Api.state managed.client))
         | Graph_request request ->
           Ok (Graph_response (Managed_coordinator.execute_graph_request managed request)))
      | Graph_bound { engine; open_error; invalidations; graph_lifecycle; _ } ->
        (match request with
         | Get_graph_state -> Ok (Graph_state (Db.Graph_lifecycle.state graph_lifecycle))
         | Client_command _ ->
           Error "sync client is unavailable for this local graph target"
         | Graph_request request ->
           let response =
             match engine, open_error with
             | Some engine, _ ->
               let response = Engine.execute engine request in
               (match response with
                | Succeeded
                    { success = Mutation_result ({ status = Applied; _ } as success); _ }
                  ->
                  enqueue_invalidation
                    invalidations
                    (protocol_invalidation (mutation_invalidation success))
                | Succeeded _ | Failed _ -> ());
               response
             | None, Some error ->
               Protocol.failed
                 ~request_id:request.request_id
                 ~phase:Open
                 ~basis:None
                 error
             | None, None -> graph_failure request "graph is unavailable"
           in
           Ok (Graph_response response)))
    ~shutdown:(function
      | Managed managed ->
        Managed_coordinator.handle managed Api.Shutdown;
        Managed_coordinator.close_engine managed managed.graph_generation
      | Graph_bound { engine = None; _ } -> ()
      | Graph_bound { engine = Some engine; graph_lifecycle; context; _ } ->
        let generation = (Db.Graph_lifecycle.state graph_lifecycle).generation in
        Db.Graph_lifecycle.begin_close graph_lifecycle ~generation;
        publish_graph_state context graph_lifecycle;
        (match Engine.close engine with
         | Ok () ->
           Db.Graph_lifecycle.closed graph_lifecycle ~generation;
           publish_graph_state context graph_lifecycle
         | Error message ->
           Db.Graph_lifecycle.failed graph_lifecycle ~generation ~message;
           publish_graph_state context graph_lifecycle;
           failwith ("logseq-db-worker close failed: " ^ message)))
    ()
;;

let service = create ~dependencies:(production_dependencies ())
