module Db = Logseq_db_worker
module Pure = Logseq_db_worker_pure_reducer.Core
module Worker_runner = Logseq_db_worker_effect_runner.Effect_runner
module Sync = Logseq_sync_pure_reducer.Core
module Sync_runner = Logseq_sync_effect_runner.Effect_runner
module Protocol = Db.Protocol
module Overlay = Logseq_overlay_db.Database
module ID = Bonsai_flutter_spec.Id

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

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; applied_server_t : int option
  ; timeline_presentation_pending : bool
  ; startup : startup_facts
  ; last_error : string option
  }

type diagnostic_group =
  { title : string
  ; entries : (string * string) list
  }

type diagnostics =
  { groups : diagnostic_group list
  ; history : string list
  }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type token_purpose =
  | Catalog_discovery
  | Snapshot_bootstrap
  | E2ee_key_access
  | Websocket_connect

type token_request = Sync.token_request

let token_request_id = Sync.token_request_id

let token_request_purpose request =
  match Sync.token_request_purpose request with
  | Sync.Catalog_discovery -> Catalog_discovery
  | Snapshot_bootstrap -> Snapshot_bootstrap
  | E2ee_key_access -> E2ee_key_access
  | Websocket_connect -> Websocket_connect
;;

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
  }
;;

let diagnostics (value : Sync.diagnostics) =
  { groups =
      List.map
        (fun (group : Sync.diagnostic_group) ->
           { title = group.title; entries = group.entries })
        value.groups
  ; history = value.history
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
      { request : Sync.token_request
      ; token : string
      }
  | Reject_token of Sync.token_request
  | Select_graph of Sync.graph_id
  | Return_to_graph_picker
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password of string
  | Delete_local_cache of Sync.graph_id
  | Set_foreground of bool

type request =
  | Client_command of client_command
  | Graph_request of Protocol.request
  | Get_graph_state

type response =
  | Client_command_completed
  | Graph_response of Protocol.response
  | Graph_state of Db.graph_state

type push =
  | Graph_push of Protocol.push
  | Client_state_changed of state
  | Need_id_token of token_request
  | Bootstrap_progress of bootstrap_progress
  | Graph_state_changed of Db.graph_state

let invalidation_topic = ID.Worker.Push_topic.of_int 0
let manager_topic = ID.Worker.Push_topic.of_int 1
let auth_topic = ID.Worker.Push_topic.of_int 2
let bootstrap_topic = ID.Worker.Push_topic.of_int 3
let graph_state_topic = ID.Worker.Push_topic.of_int 4

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
  | Pure.Reply _ -> ()
  | Graph_push push ->
    Worker.Session_context.emit context ~topic:invalidation_topic (Graph_push push)
  | Sync_output output ->
    (match output with
     | State_changed state ->
       Worker.Session_context.emit
         context
         ~topic:manager_topic
         (Client_state_changed (client_state state))
     | Token_requested request ->
       Worker.Session_context.emit context ~topic:auth_topic (Need_id_token request)
     | Bootstrap_progressed progress ->
       Worker.Session_context.emit
         context
         ~topic:bootstrap_topic
         (Bootstrap_progress (bootstrap_progress progress)))
  | Graph_state_changed state ->
    Worker.Session_context.emit
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

let sync_dependencies dependencies context config =
  let environment = Worker.Session_context.environment context in
  let clock = Eio.Stdenv.clock environment in
  Result.bind
    (Sync_runner.runtime
       ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
       ~sleep:(Eio.Time.sleep clock))
    (fun runtime ->
       Result.bind
         (Sync_runner.transport
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
                        ~crypto:dependencies.crypto))))
;;

let client_event = function
  | Restore_local_account { user_id } ->
    Pure.Sync_event (Sync.Restore_local_account { user_id })
  | Reconcile_authenticated_user { user_id } ->
    Pure.Sync_event (Sync.Account_authenticated { user_id })
  | Acknowledge_local_feed -> Pure.Sync_event Sync.Local_feed_acknowledged
  | Acknowledge_timeline_presented -> Pure.Sync_event Sync.Timeline_presented
  | Provide_token { request; token } ->
    Pure.Sync_event (Sync.Token_provided (request, token))
  | Reject_token request -> Pure.Sync_event (Sync.Token_rejected request)
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
  Worker.Service.create
    ~push_topic_count:5
    ~concurrency:(Worker.Service.Concurrent { max_in_flight = 2 })
    ~data_directory:(fun config -> Ok config.Db.Config.application_support_directory)
    ~init:(fun context config ->
      let sw = Worker.Session_context.switch context in
      let event_sink = ref (fun (_ : Pure.event) -> ()) in
      let (Managed_sync { base_url }) = config.Db.Config.target in
      let selected =
        match sync_limits config with
        | Error error -> Error (error_message error)
        | Ok limits ->
          (match Sync.config ~managed_sync_origin:(Uri.of_string base_url) ~limits with
           | Error error -> Error (error_message error)
           | Ok sync_config ->
             (match sync_dependencies dependencies context config with
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
        (match Worker_runner.runtime ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task) with
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
                 Ok worker))))
    ~handle:(fun _context worker request ->
      match request with
      | Get_graph_state -> Ok (Graph_state (Db.graph_state worker))
      | Client_command command ->
        Db.post worker (client_event command);
        Ok Client_command_completed
      | Graph_request request -> Ok (Graph_response (Db.request worker request)))
    ~shutdown:Db.shutdown
    ()
;;

let service = create ~dependencies:(production_dependencies ())
