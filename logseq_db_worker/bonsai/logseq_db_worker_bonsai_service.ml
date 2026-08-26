module Db = Logseq_db_worker
module Protocol = Db.Protocol
module Engine = Db.Engine
module Manager = Db.Sync_manager
module Network_scope = Db.Sync_network_scope
module ID = Bonsai_flutter_spec.Id

exception Network_cancelled

type local_secrets =
  { load_and_verify_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Db.Graph_types.Uuid.t
      -> (string, Db.Sync_platform_crypto.wrapped_key_load_failure) result
  ; verify_and_save_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Db.Graph_types.Uuid.t
      -> encrypted_graph_key:string
      -> (unit, string) result
  ; delete_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Db.Graph_types.Uuid.t
      -> (unit, string) result
  ; delete_account_secrets :
      managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result
  }

let production_local_secrets =
  { load_and_verify_wrapped_graph_key =
      Db.Sync_platform_crypto.load_and_verify_wrapped_graph_key
  ; verify_and_save_wrapped_graph_key =
      Db.Sync_platform_crypto.verify_and_save_wrapped_graph_key
  ; delete_wrapped_graph_key = Db.Sync_platform_crypto.delete_wrapped_graph_key
  ; delete_account_secrets = Db.Sync_platform_crypto.delete_account_secrets
  }

type request =
  | Manager_command of Manager.command
  | Graph_request of Protocol.request

type response =
  | Manager_snapshot of Manager.snapshot
  | Graph_response of Protocol.response

type push =
  | Graph_push of Protocol.push
  | Manager_state_changed of Manager.snapshot
  | Need_id_token of Db.Sync_auth.challenge
  | Bootstrap_progress of
      { account_generation : int
      ; graph_generation : int
      ; progress : Db.Sync_bootstrap.progress
      }

let invalidation_topic = ID.Worker.Push_topic.of_int 0
let manager_topic = ID.Worker.Push_topic.of_int 1
let auth_topic = ID.Worker.Push_topic.of_int 2
let bootstrap_topic = ID.Worker.Push_topic.of_int 3

let random_key () =
  let channel = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel 32 |> Bytes.of_string)
;;

let production_dependencies () =
  Engine.
    { clocks =
        { epoch_ms = (fun () -> Unix.gettimeofday () *. 1_000. |> Int64.of_float)
        ; monotonic_ns = Mtime_clock.elapsed_ns
        }
    ; cursor_authentication_key = random_key ()
    ; crypto = Db.Sync_platform_crypto.crypto
    ; unlock_graph_key =
        (fun ~managed_sync_origin ~user_id ~encrypted_graph_key ->
          Result.bind
            (Db.Sync_platform_crypto.unlock_graph_key
               ~managed_sync_origin
               ~user_id
               ~encrypted_graph_key)
            Db.Sync_graph_key.of_string)
    }
;;

let take count values =
  let rec loop remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop count [] values
;;

let invalidation (success : Protocol.mutation_success) =
  let rec fit limit =
    let changed_uuids = take limit success.changed_uuids in
    let push =
      Protocol.Graph_invalidated
        { basis = success.basis_after
        ; changed_uuids
        ; changed_uuids_truncated =
            success.changed_uuids_truncated
            || List.length changed_uuids < List.length success.changed_uuids
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
    then failwith "logseq-db-worker invalidation metadata exceeds its protocol budget"
    else fit (limit / 2)
  in
  fit (List.length success.changed_uuids)
;;

type websocket_control =
  | Websocket_send of string
  | Websocket_close

type message =
  | Handle of request * (response, string) result Eio.Promise.u
  | Internal of Manager.event
  | Network_finished of Network_scope.operation_id
  | Catalog_flush_finished of Db.Sync_catalog.cache * (unit, string) result

type managed =
  { context : push Worker.Session_context.t
  ; config : Db.Config.t
  ; base_url : Uri.t
  ; dependencies : Engine.dependencies
  ; manager : Manager.t
  ; messages : message Eio.Stream.t
  ; mutable engine : Engine.t option
  ; mutable websocket : websocket_control Eio.Stream.t option
  ; mutable catalog_cache : Db.Sync_catalog.cache option
  ; mutable catalog_dirty : bool
  ; mutable catalog_flush_in_flight : bool
  ; network_scope : Network_scope.t
  ; mutable request_sequence : int
  ; local_secrets : local_secrets
  }

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
      }

let emit runtime ~topic payload =
  Worker.Session_context.emit runtime.context ~topic payload
;;

let publish_manager runtime =
  emit
    runtime
    ~topic:manager_topic
    (Manager_state_changed (Manager.snapshot runtime.manager))
;;

let enqueue runtime event = Eio.Stream.add runtime.messages (Internal event)

let request_id runtime =
  runtime.request_sequence <- runtime.request_sequence + 1;
  Printf.sprintf "f0000000-0000-4000-8000-%012x" (runtime.request_sequence land 0xFFFFFF)
  |> Db.Graph_types.Uuid.of_string
  |> Result.get_ok
;;

let internal_request runtime command =
  Protocol.{ api_version; request_id = request_id runtime; command }
;;

let emit_invalidation runtime success =
  emit runtime ~topic:invalidation_topic (Graph_push (invalidation success))
;;

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

let graph_failure (request : Protocol.request) message =
  let error =
    Db.Error.create ~code:Db.Error.Closed_session ~message ~details:[] |> Result.get_ok
  in
  Protocol.failed ~request_id:request.Protocol.request_id ~phase:Execute ~basis:None error
;;

let status_ok status = status >= 200 && status < 300

let network_error
      runtime
      ~account_generation
      ?graph_generation
      ?connection_generation
      message
  =
  enqueue
    runtime
    (Manager.Network_failed
       { account_generation; graph_generation; connection_generation; message })
;;

let fork_network
      runtime
      ~name
      ~account_generation
      ?graph_generation
      ?connection_generation
      operation
  =
  let cancelled, cancel = Eio.Promise.create () in
  let operation_id =
    Network_scope.register
      runtime.network_scope
      ~account_generation
      ~graph_generation
      ~cancel:(fun () -> ignore (Eio.Promise.try_resolve cancel () : bool))
  in
  Worker.Session_context.fork_daemon runtime.context ~name (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Stream.add runtime.messages (Network_finished operation_id))
      (fun () ->
         try
           Eio.Fiber.first
             (fun () -> Eio.Switch.run operation)
             (fun () ->
                Eio.Promise.await cancelled;
                raise Network_cancelled)
         with
         | Network_cancelled | Eio.Cancel.Cancelled Network_cancelled -> ()
         | exception_ ->
           network_error
             runtime
             ~account_generation
             ?graph_generation
             ?connection_generation
             (Printexc.to_string exception_)))
;;

let cancel_obsolete_network runtime =
  let snapshot = Manager.snapshot runtime.manager in
  Network_scope.cancel_obsolete
    runtime.network_scope
    ~account_generation:snapshot.account_generation
    ~graph_generation:snapshot.graph_generation
;;

let perform_http
      runtime
      ~name
      request
      on_success
      ~account_generation
      ?graph_generation
      ?connection_generation
      ()
  =
  fork_network
    runtime
    ~name
    ~account_generation
    ?graph_generation
    ?connection_generation
    (fun sw ->
       match
         Db.Sync_http_eio.perform
           ~sw
           ~environment:(Worker.Session_context.environment runtime.context)
           request
       with
       | Ok response when status_ok response.status -> on_success response
       | Ok response ->
         network_error
           runtime
           ~account_generation
           ?graph_generation
           ?connection_generation
           (Printf.sprintf "sync HTTP request failed with status %d" response.status)
       | Error message ->
         network_error
           runtime
           ~account_generation
           ?graph_generation
           ?connection_generation
           message)
;;

let ensure_private_directory path =
  if Sys.file_exists path
  then
    if (Unix.stat path).st_kind = Unix.S_DIR
    then Ok ()
    else Error "staging path is not a directory"
  else (
    try
      Unix.mkdir path 0o700;
      Ok ()
    with
    | exception_ -> Error (Printexc.to_string exception_))
;;

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let snapshot_paths runtime graph_generation graph_id =
  let root =
    Filename.concat runtime.config.application_support_directory "sync-staging"
  in
  let directory =
    Filename.concat
      root
      (Printf.sprintf "%s-%d" (Db.Graph_types.Uuid.to_string graph_id) graph_generation)
  in
  Result.bind (ensure_private_directory root) (fun () ->
    Result.map
      (fun () ->
         ( Filename.concat directory "artifact.part"
         , Filename.concat directory "snapshot.transit"
         , [ Filename.concat directory "gzip-1.part"
           ; Filename.concat directory "gzip-2.part"
           ] ))
      (ensure_private_directory directory))
;;

let close_websocket runtime =
  match runtime.websocket with
  | None -> ()
  | Some controls ->
    runtime.websocket <- None;
    Eio.Stream.add controls Websocket_close
;;

let close_engine runtime =
  match runtime.engine with
  | None -> ()
  | Some engine ->
    runtime.engine <- None;
    (match Engine.close engine with
     | Ok () -> ()
     | Error message -> failwith ("logseq-db-worker close failed: " ^ message))
;;

let config_for_graph runtime graph encrypted_graph_key =
  let e2ee =
    match encrypted_graph_key, (Manager.snapshot runtime.manager).user_id with
    | Some encrypted_graph_key, Some user_id ->
      Some
        Db.Config.
          { managed_sync_origin = runtime.base_url; user_id; encrypted_graph_key }
    | Some _, None | None, _ -> None
  in
  Db.Config.create
    ~application_support_directory:runtime.config.application_support_directory
    ~target:
      (Synced_graph
         { graph_id = graph.Db.Sync_catalog.graph_id
         ; graph_name = graph.name
         ; e2ee
         ; bootstrap = None
         })
    ~compatibility_profile:runtime.config.compatibility_profile
    ~response_budget_bytes:runtime.config.response_budget_bytes
    ~default_page_size:runtime.config.default_page_size
;;

let uuid_exn value = Db.Graph_types.Uuid.of_string value |> Result.get_ok

let catalog_graph (graph : Db.Sync_action.graph) =
  Db.Sync_catalog.
    { graph_id = uuid_exn graph.graph_id
    ; name = graph.name
    ; schema =
        { major = graph.schema_major
        ; minor = graph.schema_minor
        ; exact = graph.schema_exact
        }
    ; encrypted = graph.encrypted
    }
;;

let challenge_from_scoped (challenge : Db.Sync_action.scoped_challenge) =
  let account, graph_generation, connection_generation =
    match challenge.scope with
    | Account_scope account -> account, None, None
    | Graph_scope graph -> graph.account, Some graph.graph_generation, None
    | Connection_scope connection ->
      ( connection.graph.account
      , Some connection.graph.graph_generation
      , Some connection.connection_generation )
  in
  let purpose =
    match challenge.purpose with
    | Catalog_discovery_name -> Db.Sync_auth.Catalog_discovery
    | Snapshot_bootstrap_name -> Snapshot_bootstrap
    | E2ee_key_access_name -> E2ee_key_access
    | Http_pull_name -> Http_pull
    | Transaction_submission_name -> Transaction_submission
    | Websocket_connect_name -> Websocket_connect
  in
  Db.Sync_auth.
    { challenge_id = challenge.challenge_id
    ; purpose
    ; user_id = account.user_id
    ; account_generation = account.account_generation
    ; graph_generation
    ; connection_generation
    }
;;

let pending_payload runtime =
  match runtime.engine with
  | None -> None
  | Some engine ->
    (match Engine.execute engine (internal_request runtime (Read Sync_pending)) with
     | Succeeded { success = Sync_pending_result pending; _ } -> pending.payload
     | Succeeded _ | Failed _ -> None)
;;

let catalog_base_url runtime = Uri.to_string runtime.base_url

let persist_catalog_cache_now runtime =
  match runtime.catalog_cache with
  | None -> ()
  | Some cache ->
    ignore
      (Db.Sync_catalog_store.save
         ~application_support_directory:runtime.config.application_support_directory
         cache
       : (unit, string) result)
;;

let load_catalog_cache runtime user_id =
  runtime.catalog_cache
  <- (match
        Db.Sync_catalog_store.load
          ~application_support_directory:runtime.config.application_support_directory
          ~user_id
          ~base_url:(catalog_base_url runtime)
      with
      | Ok cache -> cache
      | Error _ -> None);
  runtime.catalog_dirty <- false
;;

let replace_catalog_cache runtime cache =
  if runtime.catalog_cache = cache
  then ()
  else (
    runtime.catalog_cache <- cache;
    runtime.catalog_dirty <- true)
;;

let cache_catalog runtime graphs =
  let snapshot = Manager.snapshot runtime.manager in
  replace_catalog_cache
    runtime
    (match runtime.catalog_cache, snapshot.user_id with
     | Some cache, _ -> Some (Db.Sync_catalog.merge cache graphs)
     | None, Some user_id ->
       Some
         (Db.Sync_catalog.create_cache
            ~user_id
            ~base_url:(catalog_base_url runtime)
            ~graphs
            ~selected_graph:snapshot.selected_graph)
     | None, None -> None)
;;

let cache_selection runtime graph_id =
  replace_catalog_cache
    runtime
    (Option.bind runtime.catalog_cache (fun cache ->
       match Db.Sync_catalog.select cache graph_id with
       | Ok cache -> Some cache
       | Error _ -> Some cache))
;;

let cache_mirror_status runtime graph_id status =
  replace_catalog_cache
    runtime
    (Option.map
       (fun cache -> Db.Sync_catalog.set_mirror_status cache graph_id status)
       runtime.catalog_cache)
;;

let schedule_catalog_flush runtime =
  let snapshot = Manager.snapshot runtime.manager in
  let presentation_allows_flush =
    match snapshot.startup_presentation with
    | Manager.Timeline_presented | Reconciled -> true
    | Restoring_local | Local_feed_ready -> false
  in
  match
    ( runtime.catalog_dirty
    , runtime.catalog_flush_in_flight
    , presentation_allows_flush
    , runtime.catalog_cache )
  with
  | true, false, true, Some cache ->
    runtime.catalog_flush_in_flight <- true;
    Worker.Session_context.fork_daemon
      runtime.context
      ~name:"sync-catalog-flush"
      (fun () ->
         let result =
           try
             Db.Sync_catalog_store.save
               ~application_support_directory:runtime.config.application_support_directory
               cache
           with
           | exception_ -> Error (Printexc.to_string exception_)
         in
         Eio.Stream.add runtime.messages (Catalog_flush_finished (cache, result)))
  | false, _, _, _ | true, true, _, _ | true, false, false, _ | true, false, true, None ->
    ()
;;

let rec dispatch_event runtime event =
  let cached_selection =
    match event, runtime.catalog_cache with
    | (Manager.Catalog_loaded _ | Cached_catalog_loaded _), Some cache ->
      Db.Sync_catalog.selected_graph cache
    | _ -> None
  in
  let effects = Manager.handle_event runtime.manager event in
  cancel_obsolete_network runtime;
  (match event with
   | Catalog_loaded { graphs; _ } -> cache_catalog runtime graphs
   | Cached_catalog_loaded _ -> ()
   | Wrapped_graph_key_loaded _
   | Wrapped_graph_key_load_failed _
   | Wrapped_graph_key_saved _
   | Local_secret_cleanup_finished _ -> ()
   | Mirror_ready { graph_id; _ } ->
     cache_mirror_status runtime graph_id Db.Sync_catalog.Ready
   | Mirror_missing { graph_id; _ } ->
     cache_mirror_status runtime graph_id Db.Sync_catalog.Downloading
   | Local_cache_deleted _
   | Catalog_failed _
   | Snapshot_baseline_loaded _
   | Snapshot_metadata_loaded _
   | Snapshot_artifact_ready _
   | E2ee_graph_key_loaded _
   | E2ee_user_keys_loaded _
   | Graph_opened _
   | Websocket_opened _
   | Websocket_frame _
   | Websocket_closed _
   | Reconnect_timer_elapsed _
   | Foreground_probe_timed_out _
   | Pending_batch _
   | Http_pull_loaded _
   | Http_transaction_loaded _
   | Sync_applied _
   | Network_failed _ -> ());
  let effects =
    match event, cached_selection, (Manager.snapshot runtime.manager).selected_graph with
    | (Catalog_loaded _ | Cached_catalog_loaded _), Some graph_id, None ->
      effects @ Manager.handle_command runtime.manager (Select_graph graph_id)
    | _ -> effects
  in
  publish_manager runtime;
  process_effects runtime effects;
  schedule_catalog_flush runtime

and process_sync_frame runtime payload =
  match runtime.engine with
  | None -> ()
  | Some engine ->
    let response =
      Engine.execute
        engine
        (internal_request runtime (Sync_receive { transport = Websocket; payload }))
    in
    (match response with
     | Succeeded { success = Sync_result result; _ } ->
       Option.iter (emit_invalidation runtime) result.mutation;
       let snapshot = Manager.snapshot runtime.manager in
       dispatch_event
         runtime
         (Sync_applied
            { account_generation = snapshot.account_generation
            ; graph_generation = snapshot.graph_generation
            ; applied_server_t = result.applied_server_t
            ; activity = result.activity
            ; pending_payload = pending_payload runtime
            })
     | Failed failure ->
       let snapshot = Manager.snapshot runtime.manager in
       network_error
         runtime
         ~account_generation:snapshot.account_generation
         ~graph_generation:snapshot.graph_generation
         ~connection_generation:snapshot.connection_generation
         (Db.Error.message failure.error)
     | Succeeded _ -> ())

and process_effects runtime = function
  | [] -> ()
  | next_effect :: rest ->
    process_effect runtime next_effect;
    process_effects runtime rest

and process_effect runtime action =
  match Db.Sync_action.classify action with
  | Local_action action -> interpret_local_action runtime action
  | Network_action action -> interpret_network_action runtime action

and interpret_local_action runtime : Db.Sync_action.local Db.Sync_action.t -> unit =
  function
  | Inspect_mirror { request; graph } ->
    let scope =
      Db.Sync_startup_phase.local_request_graph_scope request
      |> Db.Sync_startup_phase.graph_scope_view
    in
    let graph = catalog_graph graph in
    (match
       Db.Sync_mirror.resolve
         ~application_support_directory:runtime.config.application_support_directory
         ~graph_id:graph.graph_id
     with
     | Ok _ ->
       dispatch_event
         runtime
         (Mirror_ready
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id = graph.graph_id
            })
     | Error _ ->
       let receipt =
         Db.Sync_startup_phase.Local_completion.mirror_failed
           request
           ~diagnostic:"mirror missing"
       in
       dispatch_event
         runtime
         (Mirror_missing
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id = graph.graph_id
            ; receipt
            }))
  | Load_and_verify_wrapped_graph_key { wrapped_key_request; private_key_request } ->
    let scope =
      Db.Sync_startup_phase.local_request_graph_scope wrapped_key_request
      |> Db.Sync_startup_phase.graph_scope_view
    in
    let graph_id = uuid_exn scope.graph_id in
    (match
       runtime.local_secrets.load_and_verify_wrapped_graph_key
         ~managed_sync_origin:scope.account.managed_sync_origin
         ~user_id:scope.account.user_id
         ~graph_id
     with
     | Ok encrypted_graph_key ->
       dispatch_event
         runtime
         (Wrapped_graph_key_loaded
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id
            ; encrypted_graph_key
            })
     | Error failure ->
       let diagnostic, receipt =
         match failure with
         | Db.Sync_platform_crypto.Wrapped_graph_key_unavailable diagnostic ->
           ( diagnostic
           , Manager.Wrapped_key_failure_receipt
               (Db.Sync_startup_phase.Local_completion.wrapped_graph_key_failed
                  wrapped_key_request
                  ~diagnostic) )
         | Local_private_key_unavailable diagnostic ->
           ( diagnostic
           , Manager.Private_key_failure_receipt
               (Db.Sync_startup_phase.Local_completion.local_private_key_failed
                  private_key_request
                  ~diagnostic) )
       in
       dispatch_event
         runtime
         (Wrapped_graph_key_load_failed
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id
            ; diagnostic
            ; receipt
            }))
  | Verify_and_save_wrapped_graph_key { scope; encrypted_graph_key } ->
    let graph_id = uuid_exn scope.graph_id in
    let result =
      runtime.local_secrets.verify_and_save_wrapped_graph_key
        ~managed_sync_origin:scope.account.managed_sync_origin
        ~user_id:scope.account.user_id
        ~graph_id
        ~encrypted_graph_key:
          (Db.Sync_action.wrapped_graph_key_to_string encrypted_graph_key)
    in
    dispatch_event
      runtime
      (Wrapped_graph_key_saved
         { account_generation = scope.account.account_generation
         ; graph_generation = scope.graph_generation
         ; graph_id
         ; diagnostic = Result.fold ~ok:(fun () -> None) ~error:(fun message -> Some message) result
         })
  | Delete_wrapped_graph_key { scope } ->
    let graph_id = uuid_exn scope.graph_id in
    let result =
      runtime.local_secrets.delete_wrapped_graph_key
        ~managed_sync_origin:scope.account.managed_sync_origin
        ~user_id:scope.account.user_id
        ~graph_id
    in
    dispatch_event
      runtime
      (Local_secret_cleanup_finished
         { account_generation = scope.account.account_generation
         ; diagnostic = Result.fold ~ok:(fun () -> None) ~error:(fun message -> Some message) result
         })
  | Delete_account_secrets { scope } ->
    let result =
      runtime.local_secrets.delete_account_secrets
        ~managed_sync_origin:scope.managed_sync_origin
        ~user_id:scope.user_id
    in
    dispatch_event
      runtime
      (Local_secret_cleanup_finished
         { account_generation = scope.account_generation
         ; diagnostic = Result.fold ~ok:(fun () -> None) ~error:(fun message -> Some message) result
         })
  | Open_graph { request; graph; encrypted_graph_key } ->
    let scope =
      Db.Sync_startup_phase.local_request_graph_scope request
      |> Db.Sync_startup_phase.graph_scope_view
    in
    let graph = catalog_graph graph in
    let encrypted_graph_key =
      Option.map Db.Sync_action.wrapped_graph_key_to_string encrypted_graph_key
    in
    close_engine runtime;
    (match config_for_graph runtime graph encrypted_graph_key with
     | Error message ->
       dispatch_event
         runtime
         (Network_failed
            { account_generation = scope.account.account_generation
            ; graph_generation = Some scope.graph_generation
            ; connection_generation = None
            ; message
            })
     | Ok config ->
       (match Engine.open_ ~dependencies:runtime.dependencies config with
        | Error error ->
          dispatch_event
            runtime
            (Network_failed
               { account_generation = scope.account.account_generation
               ; graph_generation = Some scope.graph_generation
               ; connection_generation = None
               ; message = Db.Error.message error
               })
        | Ok engine ->
          runtime.engine <- Some engine;
          (match Engine.execute engine (internal_request runtime (Read Sync_status)) with
           | Succeeded { success = Sync_status_result status; _ } ->
             dispatch_event
               runtime
               (Graph_opened
                  { account_generation = scope.account.account_generation
                  ; graph_generation = scope.graph_generation
                  ; graph_id = graph.graph_id
                  ; applied_server_t = status.applied_server_t
                  })
           | Succeeded _ | Failed _ ->
             close_engine runtime;
             dispatch_event
               runtime
               (Network_failed
                  { account_generation = scope.account.account_generation
                  ; graph_generation = Some scope.graph_generation
                  ; connection_generation = None
                  ; message = "opened sync mirror has no durable sync status"
                  }))))
  | Close_graph -> close_engine runtime
  | Delete_mirror { scope } ->
    let graph_id = uuid_exn scope.graph_id in
    (match
       Db.Sync_mirror.delete
         ~application_support_directory:runtime.config.application_support_directory
         ~graph_id
     with
     | Ok () ->
       cache_mirror_status runtime graph_id Db.Sync_catalog.Missing;
       dispatch_event
         runtime
         (Local_cache_deleted
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id
            })
     | Error error ->
       dispatch_event
         runtime
         (Network_failed
            { account_generation = scope.account.account_generation
            ; graph_generation = None
            ; connection_generation = None
            ; message = Db.Sync_mirror.error_message error
            }))
  | _ -> invalid_arg "network action reached the local interpreter"

and interpret_network_action runtime : Db.Sync_action.network Db.Sync_action.t -> unit =
  function
  | Need_id_token challenge ->
    emit runtime ~topic:auth_topic (Need_id_token (challenge_from_scoped challenge))
  | Fetch_catalog { scope; token } ->
    let account_generation = scope.account_generation in
    perform_http
      runtime
      ~name:"sync-catalog"
      (Db.Sync_http.catalog ~base_url:scope.managed_sync_origin ~token)
      (fun response ->
         match Db.Sync_catalog.decode response.body with
         | Ok graphs -> enqueue runtime (Catalog_loaded { account_generation; graphs })
         | Error message ->
           enqueue runtime (Catalog_failed { account_generation; message }))
      ~account_generation
      ()
  | Fetch_snapshot_baseline { scope; graph; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    perform_http
      runtime
      ~name:"sync-snapshot-baseline"
      (Db.Sync_http.pull
         ~base_url:runtime.base_url
         ~graph_id:graph.graph_id
         ~since:None
         ~token)
      (fun response ->
         match Db.Sync_bootstrap.decode_baseline response.body with
         | Ok baseline ->
           enqueue
             runtime
             (Snapshot_baseline_loaded
                { account_generation
                ; graph_generation
                ; graph_id = graph.graph_id
                ; baseline
                })
         | Error message ->
           network_error runtime ~account_generation ~graph_generation message)
      ~account_generation
      ~graph_generation
      ()
  | Fetch_snapshot_metadata { scope; graph; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    perform_http
      runtime
      ~name:"sync-snapshot-metadata"
      (Db.Sync_http.snapshot_metadata
         ~base_url:runtime.base_url
         ~graph_id:graph.graph_id
         ~token)
      (fun response ->
         match Db.Sync_bootstrap.decode_snapshot_metadata response.body with
         | Ok metadata ->
           enqueue
             runtime
             (Snapshot_metadata_loaded
                { account_generation
                ; graph_generation
                ; graph_id = graph.graph_id
                ; metadata
                })
         | Error message ->
           network_error runtime ~account_generation ~graph_generation message)
      ~account_generation
      ~graph_generation
      ()
  | Download_snapshot_artifact
      { scope; graph; baseline = _; metadata; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    fork_network
      runtime
      ~name:"sync-snapshot-artifact"
      ~account_generation
      ~graph_generation
      (fun sw ->
         match snapshot_paths runtime graph_generation graph.graph_id with
         | Error message ->
           network_error runtime ~account_generation ~graph_generation message
         | Ok (artifact, snapshot, temporary_paths) ->
           Db.Sync_bootstrap.cleanup (artifact :: snapshot :: temporary_paths);
           (match
              Db.Sync_http_eio.download
                ~sw
                ~environment:(Worker.Session_context.environment runtime.context)
                ~request:(Db.Sync_http.artifact ~uri:metadata.url ~token)
                ~destination:artifact
                ~maximum_bytes:(1024 * 1024 * 1024)
                ~on_progress:(fun progress ->
                  emit
                    runtime
                    ~topic:bootstrap_topic
                    (Bootstrap_progress { account_generation; graph_generation; progress }))
            with
            | Ok response when status_ok response.status ->
              (match Db.Sync_bootstrap.artifact_row_count response.headers with
               | Error message ->
                 Db.Sync_bootstrap.cleanup (artifact :: snapshot :: temporary_paths);
                 network_error runtime ~account_generation ~graph_generation message
               | Ok expected_rows ->
                 (match
                    Db.Sync_bootstrap.peel_gzip_layers
                      ~maximum_bytes:(1024 * 1024 * 1024)
                      ~source:artifact
                      ~destination:snapshot
                      ~temporary_paths
                  with
                  | Error message ->
                    Db.Sync_bootstrap.cleanup (artifact :: snapshot :: temporary_paths);
                    network_error runtime ~account_generation ~graph_generation message
                  | Ok () ->
                    remove_if_exists artifact;
                    emit
                      runtime
                      ~topic:bootstrap_topic
                      (Bootstrap_progress
                         { account_generation
                         ; graph_generation
                         ; progress =
                             { received_bytes = (Unix.stat snapshot).st_size
                             ; total_bytes = None
                             ; datom_count = Some expected_rows
                             }
                         });
                    enqueue
                      runtime
                      (Snapshot_artifact_ready
                         { account_generation
                         ; graph_generation
                         ; graph_id = graph.graph_id
                         ; snapshot_path = snapshot
                         ; expected_rows
                         })))
            | Ok response ->
              Db.Sync_bootstrap.cleanup (artifact :: snapshot :: temporary_paths);
              network_error
                runtime
                ~account_generation
                ~graph_generation
                (Printf.sprintf "snapshot artifact failed with status %d" response.status)
            | Error message ->
              Db.Sync_bootstrap.cleanup (artifact :: snapshot :: temporary_paths);
              network_error runtime ~account_generation ~graph_generation message))
  | Activate_snapshot
      { scope
      ; graph
      ; server_t
      ; snapshot_path
      ; expected_rows
      ; encrypted_graph_key
      } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    let graph_key =
      Option.map
        (fun encrypted_graph_key ->
           Result.bind
             (Db.Sync_platform_crypto.unlock_graph_key
                ~managed_sync_origin:scope.account.managed_sync_origin
                ~user_id:scope.account.user_id
                ~encrypted_graph_key:
                  (Db.Sync_action.wrapped_graph_key_to_string encrypted_graph_key))
             Db.Sync_graph_key.of_string
           |> Result.get_ok)
        encrypted_graph_key
    in
    let decrypt_protected =
      Option.map
        (fun graph_key ciphertext ->
           Result.bind
             (Db.Sync_graph_key.decrypt_value
                ~crypto:runtime.dependencies.crypto
                graph_key
                ciphertext)
             (function
             | Transit_core.Json.String plaintext -> Ok plaintext
             | _ -> Error "decrypted protected value must be a string"))
        graph_key
    in
    let result =
      Fun.protect
        ~finally:(fun () ->
          Option.iter Db.Sync_graph_key.clear graph_key;
          remove_if_exists snapshot_path)
        (fun () ->
           Db.Sync_mirror.bootstrap
             ~application_support_directory:runtime.config.application_support_directory
             ~graph_id:graph.graph_id
             ~applied_server_t:server_t
             ~expected_rows
             ~snapshot_path
             ?decrypt_protected
             ())
    in
    (match result with
     | Ok _ ->
       dispatch_event
         runtime
         (Mirror_ready { account_generation; graph_generation; graph_id = graph.graph_id })
     | Error error ->
       dispatch_event
         runtime
         (Network_failed
            { account_generation
            ; graph_generation = Some graph_generation
            ; connection_generation = None
            ; message = Db.Sync_mirror.error_message error
            }))
  | Fetch_e2ee_graph_key { scope; graph; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    let request =
      Db.Sync_http.e2ee_graph_key
        ~base_url:runtime.base_url
        ~graph_id:graph.graph_id
        ~token
    in
    perform_http
      runtime
      ~name:"sync-e2ee-graph-key"
      request
      (fun response ->
         enqueue
           runtime
           (E2ee_graph_key_loaded
              { account_generation
              ; graph_generation
              ; graph_id = graph.graph_id
              ; response = response.body
              }))
      ~account_generation
      ~graph_generation
      ()
  | Fetch_e2ee_user_keys { scope; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph_id = uuid_exn scope.graph_id in
    let request = Db.Sync_http.e2ee_user_keys ~base_url:runtime.base_url ~token in
    perform_http
      runtime
      ~name:"sync-e2ee-user-keys"
      request
      (fun response ->
         enqueue
           runtime
           (E2ee_user_keys_loaded
              { account_generation; graph_generation; graph_id; response = response.body }))
      ~account_generation
      ~graph_generation
      ()
  | Connect_websocket { scope; token } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    let graph_id = uuid_exn scope.graph.graph_id in
    close_websocket runtime;
    let controls = Eio.Stream.create 64 in
    runtime.websocket <- Some controls;
    fork_network
      runtime
      ~name:"sync-websocket"
      ~account_generation
      ~graph_generation
      ~connection_generation
      (fun sw ->
         match Db.Sync_http.websocket_uri ~base_url:runtime.base_url ~graph_id with
         | Error message ->
           network_error
             runtime
             ~account_generation
             ~graph_generation
             ~connection_generation
             message
         | Ok uri ->
           (match
              Db.Sync_websocket_eio.connect
                ~sw
                ~environment:(Worker.Session_context.environment runtime.context)
                ~uri
                ~token
                ~maximum_frame_bytes:Protocol.maximum_response_bytes
                ~on_message:(fun payload ->
                  enqueue
                    runtime
                    (Websocket_frame
                       { account_generation
                       ; graph_generation
                       ; connection_generation
                       ; payload
                       }))
                ~on_close:(fun message ->
                  enqueue
                    runtime
                    (Websocket_closed
                       { account_generation
                       ; graph_generation
                       ; connection_generation
                       ; message = Option.value message ~default:"WebSocket closed"
                       }))
            with
            | Error message ->
              enqueue
                runtime
                (Websocket_closed
                   { account_generation
                   ; graph_generation
                   ; connection_generation
                   ; message
                   })
            | Ok socket ->
              enqueue
                runtime
                (Websocket_opened
                   { account_generation; graph_generation; connection_generation });
              let rec control_loop () =
                match Eio.Stream.take controls with
                | Websocket_close -> Db.Sync_websocket_eio.close socket
                | Websocket_send payload ->
                  (match Db.Sync_websocket_eio.send socket payload with
                   | Ok () -> control_loop ()
                   | Error message ->
                     Db.Sync_websocket_eio.close socket;
                     enqueue
                       runtime
                       (Websocket_closed
                          { account_generation
                          ; graph_generation
                          ; connection_generation
                          ; message
                          }))
              in
              control_loop ()))
  | Close_websocket -> close_websocket runtime
  | Send_websocket { payload; _ } ->
    Option.iter
      (fun controls -> Eio.Stream.add controls (Websocket_send payload))
      runtime.websocket
  | Schedule_reconnect
      { scope; delay_seconds } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    close_websocket runtime;
    Network_scope.cancel_graph runtime.network_scope ~account_generation ~graph_generation;
    fork_network
      runtime
      ~name:"sync-reconnect-timer"
      ~account_generation
      ~graph_generation
      (fun _sw ->
         Eio.Time.Mono.sleep (Worker.Session_context.clock runtime.context) delay_seconds;
         enqueue
           runtime
           (Reconnect_timer_elapsed
              { account_generation; graph_generation; connection_generation }))
  | Schedule_foreground_probe
      { scope; delay_seconds } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    let lifecycle_generation = scope.lifecycle_generation in
    fork_network
      runtime
      ~name:"sync-foreground-probe-timer"
      ~account_generation
      ~graph_generation
      (fun _sw ->
         Eio.Time.Mono.sleep (Worker.Session_context.clock runtime.context) delay_seconds;
         enqueue
           runtime
           (Foreground_probe_timed_out
              { account_generation
              ; graph_generation
              ; connection_generation
              ; lifecycle_generation
              }))
  | Apply_sync_frame { frame; _ } -> process_sync_frame runtime frame
  | Recover_submitted { transaction_ids; _ } ->
    let mutation_ids = List.map uuid_exn transaction_ids in
    (match runtime.engine with
     | None -> ()
     | Some engine ->
       (match Engine.requeue_submitted engine ~mutation_ids with
        | Error message ->
          let snapshot = Manager.snapshot runtime.manager in
          network_error
            runtime
            ~account_generation:snapshot.account_generation
            ~graph_generation:snapshot.graph_generation
            ~connection_generation:snapshot.connection_generation
            message
        | Ok () ->
          Option.iter
            (fun payload -> dispatch_event runtime (Pending_batch payload))
            (pending_payload runtime)))
  | Fetch_http_pull
      { scope; since; token } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    let graph_id = uuid_exn scope.graph.graph_id in
    perform_http
      runtime
      ~name:"sync-http-pull"
      (Db.Sync_http.pull ~base_url:runtime.base_url ~graph_id ~since:(Some since) ~token)
      (fun response ->
         enqueue
           runtime
           (Http_pull_loaded
              { account_generation
              ; graph_generation
              ; connection_generation
              ; payload = response.body
              }))
      ~account_generation
      ~graph_generation
      ~connection_generation
      ()
  | Submit_http_transaction
      { scope; payload; token } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    let graph_id = uuid_exn scope.graph.graph_id in
    perform_http
      runtime
      ~name:"sync-http-transaction"
      (Db.Sync_http.transaction_batch
         ~base_url:runtime.base_url
         ~graph_id
         ~token
         ~body:payload)
      (fun response ->
         enqueue
           runtime
           (Http_transaction_loaded
              { account_generation
              ; graph_generation
              ; connection_generation
              ; payload = response.body
              }))
      ~account_generation
      ~graph_generation
      ~connection_generation
      ()
  | _ -> invalid_arg "local action reached the network interpreter"
;;

let execute_graph_request runtime request =
  match request.Protocol.command, runtime.engine with
  | Sync_receive _, _ ->
    Graph_response
      (graph_failure
         request
         "transport frames are accepted only from the worker-owned connection")
  | _, None -> Graph_response (graph_failure request "no graph is open")
  | _, Some engine ->
    let response = Engine.execute engine request in
    (match response with
     | Succeeded { success = Mutation_result ({ status = Applied; _ } as success); _ } ->
       emit_invalidation runtime success;
       Option.iter
         (fun payload -> dispatch_event runtime (Pending_batch payload))
         (pending_payload runtime)
     | Succeeded { success = Sync_result { mutation = Some success; _ }; _ } ->
       emit_invalidation runtime success
     | Succeeded _ | Failed _ -> ());
    Graph_response response
;;

let rec manager_loop runtime =
  match Eio.Stream.take runtime.messages with
  | Internal event ->
    dispatch_event runtime event;
    manager_loop runtime
  | Network_finished operation_id ->
    Network_scope.complete runtime.network_scope operation_id;
    manager_loop runtime
  | Catalog_flush_finished (saved, result) ->
    runtime.catalog_flush_in_flight <- false;
    (match result with
     | Ok () when runtime.catalog_cache = Some saved -> runtime.catalog_dirty <- false
     | Ok () | Error _ -> ());
    schedule_catalog_flush runtime;
    manager_loop runtime
  | Handle (Manager_command command, resolve) ->
    let effects = Manager.handle_command runtime.manager command in
    cancel_obsolete_network runtime;
    let actions =
      match command with
      | Manager.Restore_local_account { user_id; _ } ->
        load_catalog_cache runtime user_id;
        Option.iter
          (fun cache ->
             dispatch_event
               runtime
               (Cached_catalog_loaded
                  { account_generation =
                      (Manager.snapshot runtime.manager).account_generation
                  ; graphs = Db.Sync_catalog.graphs cache
                  }))
          runtime.catalog_cache;
        []
      | Reconcile_authenticated_user { user_id = Some user_id; _ } ->
        load_catalog_cache runtime user_id;
        Option.iter
          (fun cache ->
             dispatch_event
               runtime
               (Cached_catalog_loaded
                  { account_generation =
                      (Manager.snapshot runtime.manager).account_generation
                  ; graphs = Db.Sync_catalog.graphs cache
                  }))
          runtime.catalog_cache;
        effects
      | Reconcile_authenticated_user { user_id = None; _ }
      | Local_feed_ready _ | Timeline_presented _ -> effects
      | Manager.Authenticated_user { user_id } ->
        load_catalog_cache runtime user_id;
        Option.iter
          (fun cache ->
             dispatch_event
               runtime
               (Cached_catalog_loaded
                  { account_generation =
                      (Manager.snapshot runtime.manager).account_generation
                  ; graphs = Db.Sync_catalog.graphs cache
                  }))
          runtime.catalog_cache;
        []
      | Select_graph graph_id ->
        cache_selection runtime graph_id;
        effects
      | Return_to_graph_picker -> effects
      | Delete_local_cache graph_id ->
        cache_mirror_status runtime graph_id Db.Sync_catalog.Missing;
        effects
      | Signed_out_command
      | Provide_id_token _
      | Token_failed _
      | Refresh_catalog
      | Begin_online_recovery
      | Backgrounded _
      | Foreground_resumed _
      | Submit_e2ee_password _ -> effects
    in
    publish_manager runtime;
    process_effects runtime actions;
    schedule_catalog_flush runtime;
    Eio.Promise.resolve resolve (Ok (Manager_snapshot (Manager.snapshot runtime.manager)));
    manager_loop runtime
  | Handle (Graph_request request, resolve) ->
    Eio.Promise.resolve resolve (Ok (execute_graph_request runtime request));
    manager_loop runtime
;;

let create_with_dependencies dependencies local_secrets =
  Worker.Service.create
    ~push_topic_count:4
    ~concurrency:Worker.Service.Serial
    ~data_directory:(fun config -> Ok config.Db.Config.application_support_directory)
    ~init:(fun context config ->
      match Worker.Session_context.data_dir context with
      | None -> Error "application-support data directory capability is unavailable"
      | Some _ ->
        let dependencies = dependencies () in
        (match config.Db.Config.target with
         | Managed_sync { base_url } ->
           let base_url = Uri.of_string base_url in
           let manager =
             Manager.create
               ~next_challenge_id:
                 (let sequence = ref 0 in
                  fun () ->
                    incr sequence;
                    Printf.sprintf "token-challenge-%d" !sequence)
               ~base_url
           in
           let runtime =
             { context
             ; config
             ; base_url
             ; dependencies
             ; manager
             ; messages = Eio.Stream.create 256
             ; engine = None
             ; websocket = None
             ; catalog_cache = None
             ; catalog_dirty = false
             ; catalog_flush_in_flight = false
             ; network_scope = Network_scope.create ()
             ; request_sequence = 0
             ; local_secrets
             }
           in
           Worker.Session_context.fork_daemon context ~name:"sync-manager" (fun () ->
             manager_loop runtime);
           Ok (Managed runtime)
         | Snapshot _ | Import_snapshot _ | Synced_graph _ | Native_local_graph _ ->
           let invalidations = { wake = Eio.Condition.create (); pending = None } in
           Worker.Session_context.fork_daemon
             context
             ~name:"graph-invalidations"
             (fun () -> dispatch_invalidations context invalidations);
           (match Engine.open_ ~dependencies config with
            | Ok engine ->
              Ok (Graph_bound { engine = Some engine; open_error = None; invalidations })
            | Error error ->
              Ok (Graph_bound { engine = None; open_error = Some error; invalidations }))))
    ~handle:(fun _context state request ->
      match state with
      | Managed runtime ->
        let result, resolve = Eio.Promise.create () in
        Eio.Stream.add runtime.messages (Handle (request, resolve));
        Eio.Promise.await result
      | Graph_bound { engine; open_error; invalidations } ->
        (match request with
         | Manager_command _ ->
           Error "account manager is unavailable for this local graph target"
         | Graph_request request ->
           let response =
             match engine, open_error with
             | Some engine, _ ->
               let response = Engine.execute engine request in
               (match response with
                | Succeeded
                    { success = Mutation_result ({ status = Applied; _ } as success); _ }
                  -> enqueue_invalidation invalidations (invalidation success)
                | Succeeded { success = Sync_result { mutation = Some success; _ }; _ } ->
                  enqueue_invalidation invalidations (invalidation success)
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
      | Managed runtime ->
        Network_scope.cancel_all runtime.network_scope;
        close_websocket runtime;
        close_engine runtime;
        runtime.catalog_flush_in_flight <- false;
        if runtime.catalog_dirty then persist_catalog_cache_now runtime
      | Graph_bound { engine = None; _ } -> ()
      | Graph_bound { engine = Some engine; _ } ->
        (match Engine.close engine with
         | Ok () -> ()
         | Error message -> failwith ("logseq-db-worker close failed: " ^ message)))
    ()
;;

let create ~dependencies =
  create_with_dependencies (fun () -> dependencies) production_local_secrets
;;

let create_with_local_secrets ~dependencies ~local_secrets =
  create_with_dependencies (fun () -> dependencies) local_secrets
;;

let service = create_with_dependencies production_dependencies production_local_secrets
