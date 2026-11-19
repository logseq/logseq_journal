module Dsl = Sync_dsl.Core
module Lifecycle = Journal_sync_lifecycle.Core
module Account = Journal_sync_lifecycle.Account
module Sync = Logseq_sync_domain.Core
module Worker = Logseq_db_worker
module Runner = Logseq_db_worker_effect_runner.Effect_runner
module Pure = Logseq_db_worker_pure_reducer.Core
module Uuid = Logseq_db_types.Graph_types.Uuid
module Database = Logseq_overlay_db.Database

let ( let* ) = Result.bind

let error_message = function
  | Dsl.Authentication_failure message -> message
  | error -> Dsl.error_message error
;;

let storage_error message = Dsl.Storage_failure message

type entry =
  { scope : Sync.graph_scope
  ; core : Lifecycle.t
  ; mutable opened : Pure.database_opened option
  ; mutable attachment_error : Dsl.error option
  ; mutable status : Lifecycle.Service.status option
  ; mutable local_key_attempted : bool
  ; mutable retiring : bool
  }

type network_control =
  | Sign_in of Sync.startup_scope
  | Cancel_startup of Sync.startup_scope
  | Refresh_catalog of Sync.startup_scope
  | Recover_online of Sync.timeline_scope

type t =
  { services : Runner.services
  ; validate_control : network_control -> (unit, Dsl.error) result
  ; bind : Worker.t -> unit
  ; post : Pure.event -> unit
  ; lifecycle : Pure.lifecycle_intent -> unit
  ; unlock : Logseq_sync_domain.Core.graph_scope -> string -> (unit, string) result
  ; shutdown : unit -> unit
  }

let create ~sw ~clock ~network ~authenticator ~config ~overlay ~token () =
  let (Worker.Config.Managed_sync { base_url }) = config.Worker.Config.target in
  let root = config.application_support_directory in
  let deadlines : Execute.Core.network_deadlines =
    { setup_seconds = 30.
    ; tls_handshake_seconds = 30.
    ; http_response_seconds = 60.
    ; download_seconds = 600.
    }
  in
  let* limits =
    Dsl.limits
      ~maximum_items:256
      ~maximum_bytes:config.response_budget_bytes
      ~maximum_pending:64
      ~maximum_resources:128
      ~steps_per_turn:256
      ~maximum_tasks:32
      ~maximum_messages:64
      ~maximum_message_bytes:config.response_budget_bytes
      ~maximum_demands:256
      ~maximum_active_assets:8
      ~foreground_reserve:2
      ~foreground_demand_reserve:16
      ~foreground_descriptor_reserve_bytes:(min 16384 config.response_budget_bytes)
      ~asset_cache_budget_bytes:536870912L
      ~asset_maximum_file_bytes:104857600
      ~asset_pending_budget_bytes:536870912L
      ~snapshot_maximum_artifact_bytes:1073741824L
      ~snapshot_staging_budget_bytes:2147483648L
      ~snapshot_scratch_budget_bytes:2147483648L
  in
  let* retry =
    Dsl.retry_policy
      ~initial_seconds:1.
      ~maximum_seconds:30.
      ~multiplier:2.
      ~maximum_attempts:5
  in
  let* policy =
    Dsl.policy_config ~sync_retry:retry ~asset_retry:retry ~no_progress_seconds:30.
  in
  let worker = ref None in
  let controller = ref None in
  let entries = ref [] in
  let user = ref None in
  let authenticated = ref false in
  let account_generation = ref 0
  and presentation = ref 0 in
  let gate = ref Dsl.Closed in
  let network_epoch = ref 0L in
  let network_authorized = ref false in
  let timeline_permission = ref true in
  let foreground = ref true in
  let network_phase = ref Sync.Local_only in
  let failure = ref None in
  let restore_diagnostic = ref false in
  let presented = ref [] in
  let resident_mode = ref false in
  let baseline = ref None in
  let stopped = ref false in
  let account_lock = Eio.Mutex.create () in
  let with_account action = Eio.Mutex.use_rw ~protect:true account_lock action in
  let updates = Eio.Condition.create () in
  let dirty = ref false in
  let notify () =
    dirty := true;
    Eio.Condition.broadcast updates
  in
  let find scope =
    List.find_opt (fun entry -> entry.scope = scope && not entry.retiring) !entries
  in
  let owner ~scope =
    match find scope with
    | None -> Error "The Sync graph owner is retired."
    | Some entry -> Ok (Lifecycle.identity entry.core, Lifecycle.worker_owner entry.core)
  in
  let install_key entry wrapped =
    let* input = Dsl.unlock_input ~wrapped_graph_key:wrapped in
    let* ingress = Lifecycle.ingress entry.core in
    ingress.submit_unlock ~identity:(Lifecycle.identity entry.core) ~valid_for:30. input
    |> Result.map (fun _ -> ())
  in
  let restore_key entry =
    if
      (not entry.local_key_attempted)
      && Option.fold
           ~none:false
           ~some:(fun status ->
             status.Lifecycle.Service.observation.state.keys = Dsl.Key_locked)
           entry.status
    then (
      entry.local_key_attempted <- true;
      match
        Logseq_sync_native_crypto.Platform_crypto.load_wrapped_graph_key
          ~managed_sync_origin:entry.scope.account.managed_sync_origin
          ~user_id:entry.scope.account.user_id
          ~graph_id:entry.scope.graph_id
      with
      | Error _ -> ()
      | Ok wrapped -> ignore (install_key entry wrapped))
  in
  let publish () =
    match !worker, !baseline, !controller with
    | Some worker, Some (initial : Sync.state), Some account ->
      let entries = ref (List.filter (fun entry -> not entry.retiring) !entries) in
      List.iter restore_key !entries;
      List.iter
        (fun entry ->
           match entry.opened with
           | Some _ -> ()
           | None ->
             let owner = Lifecycle.database_owner entry.core in
             let attached =
               let* database = Execute.Core.database_if_open owner in
               match database with
               | None -> Ok None
               | Some _ when entry.retiring -> Ok None
               | Some _ ->
                 Worker.attach_database_owner worker ~scope:entry.scope owner
                 |> Result.map Option.some
                 |> Result.map_error storage_error
             in
             (match attached with
              | Ok (Some _) when entry.retiring || !stopped ->
                (match Worker.detach_database_owner worker ~scope:entry.scope with
                 | Ok () -> ()
                 | Error message ->
                   failure := Some (storage_error message);
                   notify ())
              | Ok opened ->
                entry.opened <- opened;
                entry.attachment_error <- None
              | Error error -> entry.attachment_error <- Some error))
        !entries;
      entries := List.filter (fun entry -> (not entry.retiring) && not !stopped) !entries;
      let selected_id = Account.selected account in
      let selected =
        List.find_opt (fun entry -> Some entry.scope.graph_id = selected_id) !entries
      in
      let state_for entry =
        let observed =
          Option.map (fun status -> status.Lifecycle.Service.observation) entry.status
        in
        let last_error =
          Option.bind observed (fun observed ->
            match observed.Execute.Core.status with
            | Dsl.Service_blocked error -> Some error
            | _ -> observed.state.last_failure)
        in
        let last_error =
          match entry.attachment_error, last_error, !failure with
          | Some error, _, _ -> Some error
          | None, Some _, _ -> last_error
          | None, None, failure -> failure
        in
        let phase =
          match observed with
          | None -> Sync.Connecting
          | Some observed ->
            (match observed.status with
             | Dsl.Service_waiting_network -> Sync.Offline
             | Service_waiting_unlock -> Paused
             | Service_blocked _ -> Failed
             | Service_backoff _ -> Connecting
             | Service_connecting -> Connecting
             | Service_idle -> Paused
             | Service_pulling -> Pulling
             | Service_submitting -> Submitting
             | Service_online ->
               if observed.state.pending_submissions > 0 then Submitting else Current)
        in
        let phase =
          if Option.is_some entry.attachment_error || Option.is_some !failure
          then Sync.Failed
          else phase
        in
        let startup =
          { Sync.authenticated = !authenticated
          ; account_generation = entry.scope.account.account_generation
          ; graph_generation = entry.scope.graph_generation
          ; presentation_generation = !presentation
          ; local_access =
              (if Option.is_some entry.opened then Sync.Local_available else Local_pending)
          ; network_phase = !network_phase
          ; catalog_loading = false
          ; awaiting_selection = false
          ; restoring_local = false
          ; bootstrapping =
              Option.is_none entry.opened && Option.is_none entry.attachment_error
          ; failure =
              (if Option.is_some entry.attachment_error
               then Some Sync.During_bootstrap
               else initial.snapshot.startup.failure)
          ; awaiting_e2ee_password =
              Option.fold
                ~none:false
                ~some:(fun observed -> observed.Execute.Core.state.keys = Dsl.Key_locked)
                observed
          }
        in
        { Sync.diagnostics =
            (match entry.attachment_error with
             | None -> initial.diagnostics
             | Some error ->
               { groups =
                   initial.diagnostics.groups
                   @ [ { Sync.title = "Worker errors"
                       ; entries = [ "attachDatabaseOwner", error_message error ]
                       }
                     ]
               })
        ; snapshot =
            { initial.snapshot with
              sync_phase = phase
            ; catalog = Account.catalog account
            ; timeline_presentation_pending =
                Option.is_some entry.opened && not (List.mem entry.scope !presented)
            ; selected_graph = Some entry.scope.graph_id
            ; resident_graphs = List.map (fun entry -> entry.scope.graph_id) !entries
            ; applied_server_t =
                Option.bind observed (fun observed ->
                  observed.Execute.Core.state.checkpoint)
            ; startup
            ; last_error = Option.map error_message last_error
            ; last_error_attention =
                Option.map (fun _ -> Sync.Requires_attention) last_error
            }
        }
      in
      let residents = List.map (fun entry -> entry.scope, state_for entry) !entries in
      let sync =
        match selected with
        | Some entry -> state_for entry
        | None ->
          { initial with
            snapshot =
              { initial.snapshot with
                catalog = Account.catalog account
              ; selected_graph = None
              ; resident_graphs = List.map (fun entry -> entry.scope.graph_id) !entries
              ; startup =
                  { initial.snapshot.startup with
                    authenticated = !authenticated
                  ; account_generation = !account_generation
                  ; network_phase = !network_phase
                  ; catalog_loading = false
                  ; restoring_local = false
                  ; bootstrapping = false
                  ; presentation_generation = !presentation
                  ; awaiting_selection = !user <> None
                  }
              ; last_error = Option.map error_message !failure
              ; last_error_attention =
                  Option.map (fun _ -> Sync.Requires_attention) !failure
              }
          }
      in
      let sync =
        if not !restore_diagnostic
        then sync
        else
          { sync with
            diagnostics =
              { groups =
                  [ { Sync.title = "Worker errors"
                    ; entries =
                        [ ( "inspectMirror"
                          , "Local graph restoration failed. Reopen Journal or retry \
                             local recovery." )
                        ]
                    }
                  ]
              }
          }
      in
      let account_scope =
        Option.map
          (fun user_id ->
             { Sync.managed_sync_origin = Uri.of_string base_url
             ; user_id
             ; account_generation = !account_generation
             ; presentation_generation = !presentation
             ; lifecycle_generation = 0L
             })
          !user
      in
      let coordination : Sync.coordination_state =
        { account = account_scope
        ; desired_residents = List.map (fun entry -> entry.scope.graph_id) !entries
        ; residents
        ; selected =
            Option.map
              (fun entry ->
                 { Sync.startup =
                     { account_generation = entry.scope.account.account_generation
                     ; presentation_generation = !presentation
                     }
                 ; graph_id = entry.scope.graph_id
                 ; graph_generation = entry.scope.graph_generation
                 })
              selected
        ; deletion = None
        }
      in
      Worker.post
        worker
        (Pure.Lifecycle_snapshot
           ( sync
           , coordination
           , List.filter_map
               (fun entry -> Option.map (fun opened -> entry.scope, opened) entry.opened)
               !entries ))
    | _ -> ()
  in
  let catalog =
    Account.native_catalog
      ~sw
      ~clock
      ~network
      ~authenticator
      ~deadlines
      ~token:(fun ~account ~epoch ~refresh ->
        token
          ~user:account.Account.account
          ~account_generation:!account_generation
          ~epoch
          ~refresh)
  in
  let* account =
    Account.create
      ~maximum_services:16
      ~catalog
      ~start:
        (fun
          ~account
          ~account_generation:generation
          ~graph_generation
          ~graph
          ~upload_store
          ~network:gate
          ~on_change ->
        let* identity =
          Dsl.identity
            ~origin:account.Account.origin
            ~account:account.account
            ~graph:(Uuid.to_string graph.Logseq_db_types.Managed_graph.graph_id)
            ~account_generation:generation
            ~graph_generation
        in
        if generation > Int64.of_int max_int || graph_generation > Int64.of_int max_int
        then Error (Dsl.Capacity_exceeded "Graph generation")
        else (
          let scope : Sync.graph_scope =
            { account =
                { managed_sync_origin = Uri.of_string account.origin
                ; user_id = account.account
                ; account_generation = Int64.to_int generation
                ; presentation_generation = !presentation
                ; lifecycle_generation = 0L
                }
            ; graph_id = graph.graph_id
            ; graph_generation = Int64.to_int graph_generation
            }
          in
          account_generation := Int64.to_int generation;
          let graph_root = root in
          let pending = ref None
          and admitted = ref None in
          let* core =
            Lifecycle.start_owned_native
              ~sw
              ~clock
              ~network
              ~authenticator
              ~config:{ identity; limits; network = gate; policy }
              ~deadlines
              ~liveness:
                (Execute.Core.Ping_pong { interval_seconds = 30.; timeout_seconds = 10. })
              ~cleanup_seconds:30.
              ~root:graph_root
              ~dependencies:overlay
              ~graph_name:graph.name
              ~upload_store
              ~namespace:
                (Logseq_db_worker_contract.Worker_pure_mutation.namespace_for_owner
                   ~origin:scope.account.managed_sync_origin
                   ~user:scope.account.user_id
                   ~graph:scope.graph_id)
              ~encrypted:graph.encrypted
              ~token:
                (token
                   ~user:account.account
                   ~account_generation:scope.account.account_generation)
              ~on_change:(fun status ->
                pending := Some status;
                Option.iter
                  (fun entry -> if not entry.retiring then entry.status <- Some status)
                  !admitted;
                on_change status;
                notify ())
              ~on_error:(fun error ->
                failure := Some error;
                notify ())
          in
          let entry =
            { scope
            ; core
            ; opened = None
            ; attachment_error = None
            ; status = !pending
            ; local_key_attempted = false
            ; retiring = false
            }
          in
          admitted := Some entry;
          entries := !entries @ [ entry ];
          notify ();
          Ok
            (Account.service ~set_network:(Lifecycle.set_network core) ~close:(fun () ->
               entry.retiring <- true;
               notify ();
               let* () = Lifecycle.set_network core Dsl.Closed in
               let* () =
                 Logseq_sync_worker_owner.Core.fence
                   (Lifecycle.worker_owner core)
                   ~identity:(Lifecycle.identity core)
               in
               let* () =
                 match !worker, entry.opened with
                 | Some worker, Some _ ->
                   Worker.detach_database_owner worker ~scope
                   |> Result.map_error storage_error
                 | _ -> Ok ()
               in
               let result =
                 try
                   Lifecycle.close core;
                   Ok ()
                 with
                 | Lifecycle.Service.Close_failed { error = Some error; _ } -> Error error
                 | error -> Error (Dsl.Unexpected_failure (Printexc.to_string error))
               in
               let* () = result in
               entries := List.filter (fun current -> current != entry) !entries;
               notify ();
               Ok ()))))
      ~delete_local:(fun ~account:_ ~graph ->
        let bytes = Mirage_crypto_rng.generate 16 in
        let hex =
          String.concat
            ""
            (List.init 16 (fun index -> Printf.sprintf "%02x" (Char.code bytes.[index])))
        in
        let retirement = Database.retirement_id_of_string hex in
        let* retirement = retirement |> Result.map_error storage_error in
        let* prepared, _ =
          Database.prepare_mirror_deletion
            ~application_support_directory:root
            ~graph_id:graph.graph_id
            ~retirement
          |> Result.map_error (fun _ ->
            storage_error "Unable to prepare local mirror deletion")
        in
        let committed =
          Database.commit_mirror_deletion prepared
          |> Result.map (fun _ -> ())
          |> Result.map_error (fun _ -> storage_error "Unable to delete local mirror")
        in
        let released =
          Database.cancel_mirror_deletion_checked prepared
          |> Result.map_error storage_error
        in
        let* () = released in
        committed)
      ~on_change:(fun _ _ -> notify ())
  in
  controller := Some account;
  let cache_path user_id =
    let identity = user_id ^ "\000" ^ base_url in
    let name = Digestif.SHA256.digest_string identity |> Digestif.SHA256.to_hex in
    Filename.concat
      (Filename.concat root "logseq-db-worker/sync-catalogs")
      (name ^ ".json")
  in
  let restore_local user_id =
    let path = cache_path user_id in
    if not (Sys.file_exists path)
    then Ok ()
    else (
      try
        let channel = open_in_bin path in
        let source =
          Fun.protect
            ~finally:(fun () -> close_in_noerr channel)
            (fun () ->
               let length = in_channel_length channel in
               if length > 16777216 then raise Exit;
               really_input_string channel length)
        in
        let* cache =
          Sync.decode_catalog_cache source
          |> Result.map_error (fun _ -> storage_error "Invalid local graph catalog")
        in
        if Sync.catalog_cache_user_id cache <> user_id
        then Error Dsl.Stale_context
        else
          let* () = Account.restore_catalog account (Sync.catalog_cache_graphs cache) in
          let selected = Sync.catalog_cache_selected_graph cache in
          let residents = Sync.catalog_cache_resident_graphs cache in
          let* () =
            List.fold_left
              (fun result id ->
                 let* () = result in
                 Account.select account id)
              (Ok ())
              residents
          in
          match selected with
          | Some id -> Account.select account id
          | None -> Account.deselect account
      with
      | Sys_error _ | Exit ->
        Error (storage_error "Unable to restore local graph catalog"))
  in
  let persist_local () =
    match !user with
    | None -> Ok ()
    | Some user_id ->
      let cache =
        Sync.catalog_cache
          ~user_id
          ~graphs:(Account.catalog account)
          ~selected_graph:(Account.selected account)
      in
      let cache =
        { cache with
          Logseq_db_types.Sync_account.cache_resident_graphs =
            Some
              (List.filter_map
                 (fun entry -> if entry.retiring then None else Some entry.scope.graph_id)
                 !entries)
        }
      in
      let path = cache_path user_id in
      let temporary = path ^ ".pending" in
      (try
         List.iter
           (fun directory ->
              if not (Sys.file_exists directory) then Unix.mkdir directory 0o700)
           [ Filename.concat root "logseq-db-worker"; Filename.dirname path ];
         Fun.protect
           ~finally:(fun () -> if Sys.file_exists temporary then Sys.remove temporary)
           (fun () ->
              let channel = open_out_bin temporary in
              Fun.protect
                ~finally:(fun () -> close_out_noerr channel)
                (fun () ->
                   output_string channel (Sync.encode_catalog_cache cache);
                   close_out channel);
              Sys.rename temporary path);
         Ok ()
       with
       | Sys_error _ | Unix.Unix_error _ ->
         Error (storage_error "Unable to save local graph catalog"))
  in
  let checked action =
    with_account (fun () ->
      let result = action () in
      (match result with
       | Error Dsl.Stale_context -> ()
       | Ok _ ->
         failure := None;
         notify ()
       | Error error ->
         failure := Some error;
         notify ());
      result)
  in
  let replace ?(restore = false) user_id =
    if (not restore) && !user = Some user_id
    then Ok ()
    else
      let* () = Account.replace account { origin = base_url; account = user_id; root } in
      user := Some user_id;
      incr account_generation;
      incr presentation;
      gate := Dsl.Closed;
      network_authorized := false;
      timeline_permission := true;
      network_phase := Sync.Local_only;
      authenticated := false;
      restore_diagnostic := false;
      let result = restore_local user_id in
      (match result with
       | Ok () -> ()
       | Error _ -> restore_diagnostic := true);
      result
  in
  let apply_network () =
    if !user = None
    then Ok ()
    else
      let* next =
        if (not !authenticated) || (not !network_authorized) || not !foreground
        then Ok Dsl.Closed
        else (
          match !gate with
          | Dsl.Open _ -> Ok !gate
          | Dsl.Closed ->
            if !network_epoch = Int64.max_int
            then Error (Dsl.Capacity_exceeded "Network authorization epoch")
            else (
              network_epoch := Int64.succ !network_epoch;
              Ok (Dsl.Open { authorization_epoch = !network_epoch })))
      in
      if next = !gate
      then Ok ()
      else (
        gate := next;
        match Account.set_network account next with
        | Ok () -> Ok ()
        | Error error ->
          gate := Dsl.Closed;
          network_authorized := false;
          (match Account.set_network account Dsl.Closed with
           | Ok () -> Error error
           | Error retirement -> Error retirement))
  in
  let current_presentation (scope : Sync.startup_scope) =
    if
      (not !stopped)
      && scope.account_generation = !account_generation
      && scope.presentation_generation = !presentation
    then Ok ()
    else Error Dsl.Stale_context
  in
  let current_startup scope =
    let* () = current_presentation scope in
    if !user <> None then Ok () else Error Dsl.Stale_context
  in
  let current_timeline (scope : Sync.timeline_scope) =
    let* () = current_startup scope.startup in
    if
      Account.selected account = Some scope.graph_id
      && List.exists
           (fun entry ->
              (not entry.retiring)
              && entry.scope.graph_id = scope.graph_id
              && entry.scope.graph_generation = scope.graph_generation
              && entry.scope.account.account_generation = scope.startup.account_generation
              && Some entry.scope.account.user_id = !user)
           !entries
    then Ok ()
    else Error Dsl.Stale_context
  in
  let refresh () =
    let* () = apply_network () in
    let* _ = Account.refresh account in
    persist_local ()
  in
  let select id =
    let* () = Account.select account id in
    incr presentation;
    persist_local ()
  in
  let event = function
    | Pure.Sync_event (Sync.Restore_local_account { user_id }) ->
      checked (fun () -> replace ~restore:true user_id)
    | Sync_event (Account_authenticated { user_id = None }) ->
      checked (fun () ->
        authenticated := false;
        user := None;
        incr account_generation;
        incr presentation;
        network_authorized := false;
        gate := Dsl.Closed;
        Account.logout account)
    | Sync_event (Account_authenticated { user_id = Some user_id }) ->
      checked (fun () ->
        let authorized = !network_authorized in
        let* () = replace user_id in
        authenticated := true;
        network_authorized := authorized;
        let* () = apply_network () in
        let generation = !account_generation
        and epoch = !network_epoch in
        if !foreground
        then
          Eio.Fiber.fork ~sw (fun () ->
            if
              generation = !account_generation
              && !user = Some user_id
              && epoch = !network_epoch
              && !gate <> Dsl.Closed
              && not !stopped
            then (
              let result = refresh () in
              if
                generation = !account_generation
                && !user = Some user_id
                && epoch = !network_epoch
                && !gate <> Dsl.Closed
                && not !stopped
              then ignore (checked (fun () -> result))));
        Ok ())
    | Sync_event Sync.Shutdown -> checked (fun () -> Account.logout account)
    | Sync_event (Local_cache_deletion_requested id) ->
      checked (fun () ->
        let* () = Account.delete_local account id in
        persist_local ())
    | Sync_event (Graph_selected id | Visible_graph_changed id) ->
      checked (fun () -> select id)
    | Sync_event (Resident_graphs_changed ids) ->
      resident_mode := true;
      checked (fun () ->
        List.fold_left
          (fun result id ->
             let* () = result in
             Account.select account id)
          (Ok ())
          ids)
    | Sync_event Graph_picker_requested ->
      incr presentation;
      checked (fun () ->
        let* () =
          match !resident_mode, Account.selected account with
          | false, Some id -> Account.release_graph account id
          | true, _ | false, None -> Ok ()
        in
        let* () = Account.deselect account in
        persist_local ())
    | Sync_event (Sign_in_requested scope) ->
      checked (fun () ->
        let* () = current_presentation scope in
        network_phase := Sync.Online_by_user;
        timeline_permission := true;
        network_authorized := true;
        apply_network ())
    | Sync_event (Catalog_refresh_requested scope) ->
      checked (fun () ->
        let* () = current_startup scope in
        refresh ())
    | Sync_event (Online_recovery_requested scope) ->
      checked (fun () ->
        let* () = current_timeline scope in
        let selected_failure =
          Option.bind
            (List.find_opt
               (fun entry ->
                  (not entry.retiring)
                  && entry.scope.graph_id = scope.graph_id
                  && entry.scope.graph_generation = scope.graph_generation)
               !entries)
            (fun entry ->
               match entry.attachment_error, entry.status with
               | Some error, _ -> Some error
               | None, Some status ->
                 let observed = status.Lifecycle.Service.observation in
                 (match observed.status with
                  | Dsl.Service_blocked error -> Some error
                  | _ -> observed.state.last_failure)
               | None, None -> None)
        in
        let* retry =
          match selected_failure, !failure with
          | _, Some error
            when match error with
                 | Dsl.Network_closed | Network_failure _ -> false
                 | _ -> true -> Error error
          | Some (Dsl.Network_closed | Network_failure _), _
          | None, (None | Some (Dsl.Network_closed | Network_failure _)) -> Ok true
          | Some _, _ -> Ok false
          | None, Some error -> Error error
        in
        if not retry
        then Ok ()
        else
          let* () =
            if !authenticated && !network_authorized && !foreground
            then (
              gate := Dsl.Closed;
              Account.set_network account Dsl.Closed)
            else Ok ()
          in
          refresh ())
    | Sync_event (Online_cancelled scope) ->
      checked (fun () ->
        let* () = current_presentation scope in
        timeline_permission := false;
        network_phase := Sync.Local_only;
        network_authorized := false;
        apply_network ())
    | Pure.Set_foreground value ->
      checked (fun () ->
        foreground := value;
        if !user = None then Ok () else apply_network ())
    | Sync_event (Local_graph_outbox_changed scope) ->
      checked (fun () ->
        match find scope with
        | Some entry -> Lifecycle.projection_changed entry.core
        | None -> Error Dsl.Stale_context)
    | Sync_event Local_outbox_changed ->
      checked (fun () ->
        List.fold_left
          (fun result entry ->
             let* () = result in
             Lifecycle.projection_changed entry.core)
          (Ok ())
          !entries)
    | Sync_event (Timeline_presented scope) ->
      checked (fun () ->
        let* () = current_timeline scope in
        let* () = if !timeline_permission then Ok () else Error Dsl.Stale_context in
        match
          List.find_opt
            (fun entry ->
               (not entry.retiring)
               && entry.scope.graph_id = scope.graph_id
               && entry.scope.graph_generation = scope.graph_generation
               && Option.is_some entry.opened)
            !entries
        with
        | Some entry when not (List.mem entry.scope !presented) ->
          presented := entry.scope :: !presented;
          network_phase := Sync.Online_after_timeline;
          network_authorized := true;
          apply_network ()
        | Some _ -> Ok ()
        | None -> Error Dsl.Stale_context)
    | Sync_event (Local_feed_acknowledged | Local_account_unavailable _) -> Ok ()
    | event ->
      Option.iter (fun worker -> Worker.post worker event) !worker;
      Ok ()
  in
  let unlock scope password =
    checked (fun () ->
      match find scope with
      | None -> Error Dsl.Stale_context
      | Some entry ->
        let check_current () =
          if
            !stopped
            || (not
                  (Option.fold
                     ~none:false
                     ~some:(fun current -> current == entry)
                     (find scope)))
            || !user <> Some scope.account.user_id
            || not !authenticated
          then Error Dsl.Stale_context
          else Ok ()
        in
        let admit_network () =
          let* () = check_current () in
          match !gate with
          | Dsl.Closed -> Error Dsl.Network_closed
          | Open _ -> Ok ()
        in
        let* () = admit_network () in
        let epoch =
          match !gate with
          | Dsl.Open { authorization_epoch } -> authorization_epoch
          | Closed -> 0L
        in
        let client =
          Logseq_sync_transport.Http_client.create
            ~backend:
              (Logseq_sync_transport.Http_client.native_backend
                 ~sw
                 ~clock
                 ~network
                 ~authenticator
                 ~deadlines)
            ~token:
              (token
                 ~user:scope.account.user_id
                 ~account_generation:scope.account.account_generation)
        in
        let perform make =
          Logseq_sync_transport.Http_client.perform
            client
            ~scope:{ check_current; admit_network }
            ~epoch
            ~authenticated:true
            (fun token -> make (Option.value token ~default:""))
        in
        let* keys =
          perform (fun token ->
            Logseq_sync_native_transport.Http.e2ee_user_keys
              ~base_url:scope.account.managed_sync_origin
              ~token)
        in
        let* package =
          Logseq_sync_native_crypto.E2ee.user_keys_response keys.body
          |> Result.map_error (fun message -> Dsl.Protocol_failure message)
        in
        let* () = check_current () in
        let* () =
          Logseq_sync_native_crypto.Platform_crypto.unlock_private_key
            ~managed_sync_origin:scope.account.managed_sync_origin
            ~user_id:scope.account.user_id
            ~password
            ~private_key_package:package
          |> Result.map_error (fun message -> Dsl.Crypto_failure message)
        in
        let* graph =
          perform (fun token ->
            Logseq_sync_native_transport.Http.e2ee_graph_key
              ~base_url:scope.account.managed_sync_origin
              ~graph_id:scope.graph_id
              ~token)
        in
        let* wrapped =
          Logseq_sync_native_crypto.E2ee.graph_key_response graph.body
          |> Result.map_error (fun message -> Dsl.Protocol_failure message)
        in
        let* () = check_current () in
        let* () =
          Logseq_sync_native_crypto.Platform_crypto.verify_and_save_wrapped_graph_key
            ~managed_sync_origin:scope.account.managed_sync_origin
            ~user_id:scope.account.user_id
            ~graph_id:scope.graph_id
            ~encrypted_graph_key:wrapped
          |> Result.map_error (fun message -> Dsl.Crypto_failure message)
        in
        install_key entry wrapped)
    |> Result.map_error error_message
  in
  let await_io ~(scope : Sync.effect_scope) =
    List.fold_left
      (fun result entry ->
         let* () = result in
         if
           Option.fold
             ~none:true
             ~some:(( = ) entry.scope.account.account_generation)
             scope.Sync.account_generation
           && Option.fold
                ~none:true
                ~some:(( = ) entry.scope.graph_generation)
                scope.graph_generation
         then
           let* () =
             Lifecycle.set_network entry.core Dsl.Closed |> Result.map_error error_message
           in
           let* () =
             Logseq_sync_worker_owner.Core.fence
               (Lifecycle.worker_owner entry.core)
               ~identity:(Lifecycle.identity entry.core)
             |> Result.map_error error_message
           in
           Logseq_sync_worker_owner.Core.await_io
             (Lifecycle.worker_owner entry.core)
             ~identity:(Lifecycle.identity entry.core)
           |> Result.map_error error_message
         else Ok ())
      (Ok ())
      !entries
  in
  let shutdown () =
    with_account (fun () ->
      if not !stopped
      then (
        stopped := true;
        Eio.Condition.broadcast updates;
        try
          match Account.logout account with
          | Error error -> raise (Failure (error_message error))
          | Ok () -> ()
        with
        | error ->
          stopped := false;
          raise error))
  in
  let asset_scope (scope : Sync.graph_scope) : Logseq_sync_assets.Namespace.graph_scope =
    { account =
        { managed_sync_origin = scope.account.managed_sync_origin
        ; user_id = scope.account.user_id
        }
    ; graph_id = scope.graph_id
    }
  in
  let asset_error = function
    | Logseq_sync_assets.Cache.Invalid message | Io message ->
      Sync.Asset_invalid_content message
    | Full -> Sync.Asset_invalid_content "Asset retirement storage is full."
    | Stale -> Sync.Asset_cancelled
    | Checksum_mismatch ->
      Sync.Asset_invalid_content "Asset retirement checksum mismatch."
  in
  let asset_root = Filename.concat root "logseq-db-worker/assets" in
  let finish deletion commit =
    let scope = asset_scope (Sync.asset_deletion_scope deletion) in
    let retirement = Sync.asset_deletion_retirement deletion in
    let deletion =
      Logseq_sync_assets.Namespace.asset_deletion_reference ~scope ~retirement
    in
    Logseq_sync_assets.Cache.finish_graph_deletion ~root:asset_root ~deletion ~commit
    |> Result.map (fun () -> Sync.Asset_unit)
    |> Result.map_error asset_error
  in
  let asset (request : Sync.asset_request) =
    match request.action with
    | Sync.Prepare_graph_asset_deletion retirement ->
      Logseq_sync_assets.Cache.prepare_graph_deletion
        ~root:asset_root
        ~scope:(asset_scope request.scope)
        ~retirement
      |> Result.map (fun () ->
        Sync.Asset_deletion_prepared
          (Sync.asset_deletion_reference ~scope:request.scope ~retirement))
      |> Result.map_error asset_error
    | Commit_graph_asset_deletion deletion -> finish deletion true
    | Cancel_graph_asset_deletion deletion -> finish deletion false
    | Sync.Cancel_asset_operation _ | Await_asset_operations -> Ok Sync.Asset_unit
    | Close_asset_scope ->
      with_account (fun () ->
        if not (List.exists (fun entry -> entry.scope = request.scope) !entries)
        then Ok Sync.Asset_unit
        else
          (let* () = Account.release_graph account request.scope.graph_id in
           let* () =
             match Account.selected account, !entries with
             | None, entry :: _ -> Account.select account entry.scope.graph_id
             | Some _, _ | None, [] -> Ok ()
           in
           notify ();
           Ok Sync.Asset_unit)
          |> Result.map_error (fun _ -> Sync.Asset_cancelled))
    | _ -> Error (Sync.Asset_invalid_content "Asset request requires a graph owner")
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Condition.loop_no_mutex updates (fun () ->
        if !dirty || !stopped then Some () else None);
      if not !stopped
      then (
        dirty := false;
        publish ();
        loop ())
    in
    loop ());
  let intents = Eio.Stream.create 256 in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      let intent = Eio.Stream.take intents in
      (match intent with
       | Pure.Sync_intent (Sync.E2ee_password_submitted (challenge, password)) ->
         ignore (unlock (Sync.unlock_challenge_scope challenge) password)
       | Sync_intent value -> ignore (event (Pure.Sync_event value))
       | Foreground_intent foreground -> ignore (event (Pure.Set_foreground foreground))
       | Stop_intent -> shutdown ());
      notify ();
      if not !stopped then loop ()
    in
    loop ());
  let lifecycle intent =
    if not !stopped
    then
      if Eio.Stream.length intents >= 256
      then (
        failure := Some (Dsl.Capacity_exceeded "The account command queue is full.");
        notify ())
      else Eio.Stream.add intents intent
  in
  let services : Runner.services =
    { post = lifecycle
    ; owner
    ; asset
    ; await_io
    ; shutdown
    ; retire_account =
        (fun ~account:_ -> Account.logout account |> Result.map_error error_message)
    }
  in
  let validate_control control =
    with_account (fun () ->
      match control with
      | Sign_in scope | Cancel_startup scope -> current_presentation scope
      | Refresh_catalog scope -> current_startup scope
      | Recover_online scope -> current_timeline scope)
  in
  Ok
    { services
    ; validate_control
    ; bind =
        (fun value ->
          worker := Some value;
          baseline := Some (Worker.view value).sync;
          notify ())
    ; post = (fun value -> Option.iter (fun worker -> Worker.post worker value) !worker)
    ; lifecycle
    ; unlock
    ; shutdown
    }
;;
