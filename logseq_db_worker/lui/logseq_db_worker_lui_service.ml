module Db = Logseq_db_worker
module Pure = Logseq_db_worker_pure_reducer.Core
module Worker_runner = Logseq_db_worker_effect_runner.Effect_runner
module Sync = Logseq_sync_pure_reducer.Core
module Sync_runner = Logseq_sync_effect_runner.Effect_runner
module Protocol = Db.Protocol
module Overlay = Logseq_overlay_db.Database
module ID = Journal_worker_ids

type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t

type sync_phase =
  | Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed

type startup_failure_stage =
  | During_authentication
  | During_catalog
  | During_local_restore
  | During_bootstrap
  | During_e2ee

type startup_facts =
  { authenticated : bool
  ; catalog_loading : bool
  ; awaiting_selection : bool
  ; restoring_local : bool
  ; bootstrapping : bool
  ; awaiting_e2ee_password : bool
  ; failure : startup_failure_stage option
  ; account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
  }

type local_deletion_stage = Logseq_sync_pure_reducer.Core.local_deletion_stage =
  | Closing_graph
  | Deleting_mirror
  | Clearing_selection

type local_deletion = Logseq_sync_pure_reducer.Core.local_deletion =
  | Deletion_in_progress of local_deletion_stage
  | Deletion_failed of local_deletion_stage

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; applied_server_t : int option
  ; timeline_presentation_pending : bool
  ; startup : startup_facts
  ; last_error : string option
  ; local_deletion : local_deletion option
  }

type diagnostic_group =
  { title : string
  ; entries : (string * string) list
  }

type diagnostics = { groups : diagnostic_group list }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type token_request = Worker_runner.id_token_request

let token_request_id = Worker_runner.id_token_request_id

type bootstrap_progress =
  { graph_id : graph_id
  ; received_bytes : int64
  ; total_bytes : int64 option
  }

let sync_phase = function
  | Sync.Offline -> Offline
  | Connecting -> Connecting
  | Pulling -> Pulling
  | Submitting -> Submitting
  | Current -> Current
  | Paused -> Paused
  | Failed -> Failed
;;

let failure_stage = function
  | Sync.During_authentication -> During_authentication
  | During_catalog -> During_catalog
  | During_local_restore -> During_local_restore
  | During_bootstrap -> During_bootstrap
  | During_e2ee -> During_e2ee
;;

let startup_facts (facts : Sync.startup_facts) =
  { authenticated = facts.authenticated
  ; catalog_loading = facts.catalog_loading
  ; awaiting_selection = facts.awaiting_selection
  ; restoring_local = facts.restoring_local
  ; bootstrapping = facts.bootstrapping
  ; awaiting_e2ee_password = facts.awaiting_e2ee_password
  ; failure = Option.map failure_stage facts.failure
  ; account_generation = facts.account_generation
  ; graph_generation = facts.graph_generation
  ; presentation_generation = facts.presentation_generation
  }
;;

let snapshot (value : Sync.snapshot) =
  { sync_phase = sync_phase value.sync_phase
  ; catalog = value.catalog
  ; selected_graph = value.selected_graph
  ; applied_server_t = value.applied_server_t
  ; timeline_presentation_pending = value.timeline_presentation_pending
  ; startup = startup_facts value.startup
  ; last_error = value.last_error
  ; local_deletion = value.local_deletion
  }
;;

let diagnostics (value : Sync.diagnostics) =
  { groups =
      List.map
        (fun (group : Sync.diagnostic_group) ->
           { title = group.title; entries = group.entries })
        value.groups
  }
;;

let client_state (value : Sync.state) =
  { snapshot = snapshot value.snapshot; diagnostics = diagnostics value.diagnostics }
;;

let bootstrap_progress (value : Sync.bootstrap_progress) =
  { graph_id = value.graph_id
  ; received_bytes = value.received_bytes
  ; total_bytes = value.total_bytes
  }
;;

type client_command =
  | Restore_local_account of { user_id : string }
  | Reconcile_authenticated_user of { user_id : string option }
  | Acknowledge_local_feed
  | Acknowledge_timeline_presented
  | Provide_token of
      { request : token_request
      ; token : string
      }
  | Reject_token of token_request
  | Select_graph of Sync.graph_id
  | Return_to_graph_picker
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password of string
  | Delete_local_cache of Sync.graph_id
  | Set_foreground of bool

module Asset = struct
  type priority = Logseq_sync_pure_reducer.Asset_transfer.priority =
    | Foreground
    | Background

  type failure = Logseq_sync_pure_reducer.Asset_transfer.failure =
    | Network
    | Not_found
    | Checksum_mismatch
    | Authentication
    | Locked
    | Storage_full
    | Invalid_content of string

  type availability = Logseq_sync_pure_reducer.Asset_transfer.availability =
    | Queued
    | Downloading
    | Ready of string
    | Waiting_remote
    | Waiting_network
    | Waiting_unlock
    | Failed of
        { failure : failure
        ; attempts : int
        ; retry_scheduled : bool
        }
end

type asset_scope = Logseq_sync_pure_reducer.Core.graph_scope

type asset_notice = Logseq_db_worker_pure_reducer.Core.asset_notice =
  | Asset_availability of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; availability : Logseq_sync_pure_reducer.Asset_transfer.availability
      }
  | Asset_demand_accepted of string
  | Asset_backpressure of string
  | Asset_capacity_available
  | Upload_status of
      { operation : Logseq_db_types.Graph_types.Uuid.t
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; target : Logseq_db_types.Graph_types.Uuid.t
      ; title : string
      ; status : Logseq_db_worker_pure_reducer.Asset_upload.status
      }

type asset_command =
  | Replace_asset_demand of
      { consumer : string
      ; priority : Logseq_sync_pure_reducer.Asset_transfer.priority
      ; assets : Logseq_db_types.Asset_descriptor.t list
      }
  | Release_asset_demand of string
  | Retry_asset of Logseq_db_types.Graph_types.Uuid.t
  | Retry_upload of Logseq_db_types.Graph_types.Uuid.t

type request =
  | Import_asset of
      { graph_generation : int
      ; source : Logseq_db_types.Asset_import.t
      }
  | Client_command of client_command
  | Graph_request of Protocol.request
  | Get_graph_state
  | Asset_command of
      { graph_generation : int
      ; command : asset_command
      }
  | Acquire_imported_file of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; operation : Logseq_db_types.Graph_types.Uuid.t
      }
  | Acquire_asset_file of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; handle : string
      }
  | Release_asset_file of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; handle : string
      }

type response =
  | Asset_imported of (Logseq_db_worker.import_receipt, string) result
  | Client_command_completed
  | Asset_file of (string * string) option
  | Graph_response of Protocol.response
  | Graph_state of Db.graph_state

type push =
  | Graph_push of Protocol.push
  | Client_state_changed of state
  | Need_id_token of token_request
  | Bootstrap_progress of bootstrap_progress
  | Graph_state_changed of Db.graph_state
  | Asset_notice of
      Logseq_sync_pure_reducer.Core.graph_scope
      * Logseq_db_worker_pure_reducer.Core.asset_notice

let invalidation_topic = ID.Worker.Push_topic.of_int 0
let manager_topic = ID.Worker.Push_topic.of_int 1
let auth_topic = ID.Worker.Push_topic.of_int 2
let bootstrap_topic = ID.Worker.Push_topic.of_int 3
let graph_state_topic = ID.Worker.Push_topic.of_int 4
let asset_topic = ID.Worker.Push_topic.of_int 5

type dependencies =
  { overlay : Overlay.dependencies
  ; tls_authenticator : Sync_runner.tls_authenticator
  ; secrets : Sync_runner.secrets
  ; crypto : Sync_runner.crypto
  }

let dependencies ~overlay ~tls_authenticator ~secrets ~crypto =
  { overlay; tls_authenticator; secrets; crypto }
;;

let production_dependencies () =
  let limits =
    Logseq_overlay_db.Types.
      { response_budget_bytes = Protocol.maximum_response_bytes
      ; outbox_max_records = 4_096
      ; outbox_max_bytes = 8 * 1024 * 1024
      ; change_max_items = Protocol.maximum_changed_uuids
      ; change_max_bytes = Protocol.maximum_push_bytes
      ; dispatcher_capacity = 256
      ; wire_batch_max_bytes = Protocol.maximum_response_bytes
      }
  in
  let overlay =
    Overlay.dependencies
      ~epoch_ms:(fun () -> Unix.gettimeofday () *. 1_000. |> Int64.of_float)
      ~monotonic_ns:Mtime_clock.elapsed_ns
      ~limits
    |> Result.get_ok
  in
  let secrets = Sync_runner.apple_secrets () |> Result.get_ok in
  let crypto = Sync_runner.apple_crypto () |> Result.get_ok in
  let tls_authenticator = Sync_runner.system_tls_authenticator () |> Result.get_ok in
  { overlay; tls_authenticator; secrets; crypto }
;;

let publish context = function
  | Pure.Asset_notice (scope, notice) ->
    Journal_worker.Session_context.emit
      context
      ~topic:asset_topic
      (Asset_notice (scope, notice))
  | Pure.Reply _ -> ()
  | Graph_push push ->
    Journal_worker.Session_context.emit
      context
      ~topic:invalidation_topic
      (Graph_push push)
  | Sync_output output ->
    (match output with
     | State_changed state ->
       Journal_worker.Session_context.emit
         context
         ~topic:manager_topic
         (Client_state_changed (client_state state))
     | Bootstrap_progressed progress ->
       Journal_worker.Session_context.emit
         context
         ~topic:bootstrap_topic
         (Bootstrap_progress (bootstrap_progress progress)))
  | Graph_state_changed state ->
    Journal_worker.Session_context.emit
      context
      ~topic:graph_state_topic
      (Graph_state_changed state)
  | Diagnostic _ -> ()
;;

let sync_limits config =
  Sync.limits
    ~maximum_response_bytes:config.Db.Config.response_budget_bytes
    ~maximum_artifact_bytes:(1024 * 1024 * 1024)
    ~submission_batch_size:32
;;

let sync_dependencies dependencies context config id_token_provider =
  let environment = Journal_worker.Session_context.environment context in
  let clock = Eio.Stdenv.clock environment in
  Result.bind
    (Sync_runner.runtime
       ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
       ~sleep:(Eio.Time.sleep clock))
    (fun runtime ->
       Result.bind
         (Sync_runner.transport
            ~websocket_liveness:
              (Sync_runner.Ping_pong { interval_seconds = 30.; timeout_seconds = 10. })
            ~tls_authenticator:dependencies.tls_authenticator
            ~network:(Eio.Stdenv.net environment)
            ~clock)
         (fun transport ->
            Result.bind
              (Sync_runner.local_store
                 ~application_support_directory:
                   config.Db.Config.application_support_directory)
              (fun local_store ->
                 Result.bind
                   (Sync_runner.artifact_store
                      ~staging_directory:
                        (Filename.concat
                           config.application_support_directory
                           "sync-staging"))
                   (fun artifact_store ->
                      Sync_runner.dependencies
                        ~runtime
                        ~transport
                        ~local_store
                        ~artifact_store
                        ~secrets:dependencies.secrets
                        ~crypto:dependencies.crypto
                        ~id_token_provider))))
;;

let client_event = function
  | Restore_local_account { user_id } ->
    Pure.Sync_event (Sync.Restore_local_account { user_id })
  | Reconcile_authenticated_user { user_id } ->
    Pure.Sync_event (Sync.Account_authenticated { user_id })
  | Acknowledge_local_feed -> Pure.Sync_event Sync.Local_feed_acknowledged
  | Acknowledge_timeline_presented -> Pure.Sync_event Sync.Timeline_presented
  | Provide_token _ | Reject_token _ ->
    invalid_arg "token commands are handled by the service"
  | Select_graph graph_id -> Pure.Sync_event (Sync.Graph_selected graph_id)
  | Return_to_graph_picker -> Pure.Sync_event Sync.Graph_picker_requested
  | Refresh_catalog -> Pure.Sync_event Sync.Catalog_refresh_requested
  | Begin_online_recovery -> Pure.Sync_event Sync.Online_recovery_requested
  | Submit_e2ee_password password ->
    Pure.Sync_event (Sync.E2ee_password_submitted password)
  | Delete_local_cache graph_id ->
    Pure.Sync_event (Sync.Local_cache_deletion_requested graph_id)
  | Set_foreground foreground -> Pure.Set_foreground foreground
;;

let error_message = function
  | Sync.Invalid_config message -> message
;;

let sync_create_error_message = function
  | Sync_runner.Invalid_create message -> message
;;

let sync_dependency_error_message = function
  | Sync_runner.Invalid_dependency message -> message
;;

let worker_dependency_error_message = function
  | Worker_runner.Invalid_dependency message -> message
;;

let create ~(dependencies : dependencies) =
  let module Session = struct
    type t =
      { worker : Db.t
      ; token_cache : Worker_runner.id_token_cache
      }
  end
  in
  Journal_worker.Service.create
    ~push_topic_count:6
    ~concurrency:(Journal_worker.Service.Concurrent { max_in_flight = 2 })
    ~data_directory:(fun config -> Ok config.Db.Config.application_support_directory)
    ~init:(fun context config ->
      let sw = Journal_worker.Session_context.switch context in
      let event_sink = ref (fun (_ : Pure.event) -> ()) in
      let token_cache =
        Worker_runner.id_token_cache
          ~wall_clock_s:Unix.gettimeofday
          ~monotonic_ns:Mtime_clock.elapsed_ns
          ~request:(fun request ->
            Journal_worker.Session_context.emit
              context
              ~topic:auth_topic
              (Need_id_token request))
      in
      let id_token_provider =
        Sync_runner.id_token_provider
          ~acquire:(fun account -> Worker_runner.acquire_id_token token_cache ~account)
          ~invalidate:(fun account ~token ->
            Worker_runner.invalidate_id_token token_cache ~account ~token)
      in
      let (Managed_sync { base_url }) = config.Db.Config.target in
      let selected =
        match sync_limits config with
        | Error error -> Error (error_message error)
        | Ok limits ->
          (match Sync.config ~managed_sync_origin:(Uri.of_string base_url) ~limits with
           | Error error -> Error (error_message error)
           | Ok sync_config ->
             (match sync_dependencies dependencies context config id_token_provider with
              | Error error -> Error (sync_dependency_error_message error)
              | Ok runner_dependencies ->
                (match
                   Sync_runner.create ~sw runner_dependencies ~post:(fun event ->
                     !event_sink (Pure.Sync_event event))
                 with
                 | Error error -> Error (sync_create_error_message error)
                 | Ok runner ->
                   Ok
                     ( sync_config
                     , Worker_runner.sync_runner
                         ~stage_asset:(Sync_runner.stage_asset runner)
                         ~release_staging:(Sync_runner.release_staged_asset runner)
                         ~prune_staging:(Sync_runner.prune_staged_assets runner)
                         ~put_upload:(fun ~context intent ~current ->
                           match
                             Sync_runner.staged_asset_path
                               runner
                               ~scope:context.scope
                               ~file:
                                 intent.Logseq_db_types.Asset_upload_intent.staged_file
                           with
                           | None ->
                             Error
                               Logseq_db_worker_pure_reducer.Asset_upload.Missing_source
                           | Some source_file ->
                             Sync_runner.upload_asset
                               runner
                               ~context
                               ~asset:intent.asset
                               ~version:intent.version
                               ~source_file
                               ~maximum_plaintext_bytes:(8 * 1024 * 1024)
                               ~current
                             |> Result.map_error (function
                               | Sync_runner.Upload_network ->
                                 Logseq_db_worker_pure_reducer.Asset_upload.Network
                               | Upload_authentication | Upload_locked -> Authentication
                               | Upload_missing_source -> Missing_source
                               | Upload_size_rejected -> Size_rejected
                               | Upload_revoked_access -> Revoked_access
                               | Upload_invalid_content | Upload_cancelled ->
                                 Invalid_content))
                         ~submit_asset:(Sync_runner.run_scoped_asset runner)
                         ~delete_assets:(Sync_runner.delete_graph_assets runner)
                         ~close_assets:(Sync_runner.close_asset_scope runner)
                         ~retain_staged_file:(Sync_runner.retain_staged_file runner)
                         ~retain_asset_file:(Sync_runner.retain_asset_file runner)
                         ~release_asset_file:(Sync_runner.release_asset_file runner)
                         ~submit:(Sync_runner.submit runner)
                         ~shutdown:(fun () -> Sync_runner.shutdown runner)
                         ~decrypt_protected_value:
                           (Sync_runner.decrypt_protected_value runner)
                         ~encrypt_protected_values:
                           (Sync_runner.encrypt_protected_values runner)
                         () ))))
      in
      match selected with
      | Error message -> Error message
      | Ok (sync_config, selected_sync_runner) ->
        (match
           Worker_runner.runtime
             ~sleep:
               (Eio.Time.sleep
                  (Eio.Stdenv.clock (Journal_worker.Session_context.environment context)))
             ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
         with
         | Error error -> Error (worker_dependency_error_message error)
         | Ok runtime ->
           let pure_config = Pure.config ~worker:config ~sync:sync_config in
           (match
              Worker_runner.dependencies
                ~runtime
                ~config
                ~overlay:dependencies.overlay
                ~sync_runner:selected_sync_runner
                ~publish:(publish context)
            with
            | Error error -> Error (worker_dependency_error_message error)
            | Ok runner_dependencies ->
              (match Db.create ~sw ~config:pure_config ~runner_dependencies with
               | Error (Db.Invalid_create message) -> Error message
               | Ok worker ->
                 event_sink := Db.post worker;
                 Ok Session.{ worker; token_cache }))))
    ~handle:(fun _context session request ->
      match request with
      | Import_asset { graph_generation; source } ->
        Ok (Asset_imported (Db.import_asset session.worker ~graph_generation source))
      | Get_graph_state -> Ok (Graph_state (Db.graph_state session.worker))
      | Asset_command { graph_generation; command } ->
        let event =
          match command with
          | Retry_upload operation ->
            Pure.Upload_requested
              { graph_generation
              ; operation
              ; event = Logseq_db_worker_pure_reducer.Asset_upload.Retry
              }
          | Replace_asset_demand { consumer; priority; assets } ->
            Pure.Asset_requested
              { graph_generation
              ; event =
                  Logseq_sync_pure_reducer.Asset_transfer.Replace
                    { consumer; priority; assets }
              }
          | Release_asset_demand consumer ->
            Pure.Asset_requested { graph_generation; event = Release consumer }
          | Retry_asset asset ->
            Pure.Asset_requested { graph_generation; event = Retry asset }
        in
        Db.post session.worker event;
        Ok Client_command_completed
      | Acquire_imported_file { scope; operation } ->
        Ok (Asset_file (Db.retain_imported_file session.worker ~scope ~operation))
      | Acquire_asset_file { scope; handle } ->
        Ok (Asset_file (Db.retain_asset_file session.worker ~scope ~handle))
      | Release_asset_file { scope; handle } ->
        Db.release_asset_file session.worker ~scope ~handle;
        Ok Client_command_completed
      | Client_command (Provide_token { request; token }) ->
        Worker_runner.provide_id_token session.token_cache request token;
        Ok Client_command_completed
      | Client_command (Reject_token request) ->
        Worker_runner.reject_id_token session.token_cache request "host rejected request";
        Ok Client_command_completed
      | Client_command (Reconcile_authenticated_user { user_id }) ->
        Worker_runner.reconcile_authenticated_user session.token_cache ~user_id;
        Db.post session.worker (client_event (Reconcile_authenticated_user { user_id }));
        Ok Client_command_completed
      | Client_command command ->
        Db.post session.worker (client_event command);
        Ok Client_command_completed
      | Graph_request request -> Ok (Graph_response (Db.request session.worker request)))
    ~shutdown:(fun session ->
      Worker_runner.shutdown_id_token_cache session.token_cache;
      Db.shutdown session.worker)
    ()
;;

let service = create ~dependencies:(production_dependencies ())
