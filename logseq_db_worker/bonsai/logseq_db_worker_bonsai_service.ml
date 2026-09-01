module Db = Logseq_db_worker
module Pure = Logseq_db_worker_pure_reducer.Core
module Worker_runner = Logseq_db_worker_effect_runner.Effect_runner
module Sync = Logseq_sync_pure_reducer.Core
module Sync_runner = Logseq_sync_effect_runner.Effect_runner
module Protocol = Db.Protocol
module ID = Bonsai_flutter_spec.Id

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
  | Client_state_changed of Sync.state
  | Need_id_token of Sync.token_request
  | Bootstrap_progress of Sync.bootstrap_progress
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
  { engine : Db.Engine.dependencies
  ; tls_authenticator : Sync_runner.tls_authenticator
  ; secrets : Sync_runner.secrets
  ; crypto : Sync_runner.crypto
  }

let dependencies ~engine ~tls_authenticator ~secrets ~crypto =
  { engine; tls_authenticator; secrets; crypto }
;;

let production_dependencies () =
  let engine =
    Db.Engine.
      { clocks =
          { epoch_ms = (fun () -> Unix.gettimeofday () *. 1_000. |> Int64.of_float)
          ; monotonic_ns = Mtime_clock.elapsed_ns
          }
      ; cursor_authentication_key = random_key ()
      }
  in
  let secrets = Sync_runner.apple_secrets () |> Result.get_ok in
  let crypto = Sync_runner.apple_crypto () |> Result.get_ok in
  let tls_authenticator = Sync_runner.system_tls_authenticator () |> Result.get_ok in
  { engine; tls_authenticator; secrets; crypto }
;;

let take count values =
  let rec loop remaining reversed = function
    | _ when remaining = 0 -> List.rev reversed
    | [] -> List.rev reversed
    | value :: rest -> loop (remaining - 1) (value :: reversed) rest
  in
  loop count [] values
;;

let protocol_invalidation (invalidation : Sync.invalidation) =
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

let publish context = function
  | Pure.Reply _ -> ()
  | Graph_push push ->
    Worker.Session_context.emit context ~topic:invalidation_topic (Graph_push push)
  | Sync_output (State_changed state) ->
    Worker.Session_context.emit context ~topic:manager_topic (Client_state_changed state)
  | Sync_output (Token_requested request) ->
    Worker.Session_context.emit context ~topic:auth_topic (Need_id_token request)
  | Sync_output (Bootstrap_progressed progress) ->
    Worker.Session_context.emit
      context
      ~topic:bootstrap_topic
      (Bootstrap_progress progress)
  | Sync_output (Graph_invalidated invalidation) ->
    Worker.Session_context.emit
      context
      ~topic:invalidation_topic
      (Graph_push (protocol_invalidation invalidation))
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
       ~sleep:(Eio.Time.sleep clock)
       ~monotonic_ns:Mtime_clock.elapsed_ns)
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
      let selected =
        match config.Db.Config.target with
        | Managed_sync { base_url } ->
          (match sync_limits config with
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
                        ( Some sync_config
                        , Worker_runner.sync_runner
                            ~submit:(Sync_runner.submit runner)
                            ~shutdown:(fun () -> Sync_runner.shutdown runner)
                            ~decrypt_protected_value:
                              (Sync_runner.decrypt_protected_value runner)
                            ~encrypt_protected_values:
                              (Sync_runner.encrypt_protected_values runner)
                            () )))))
        | Snapshot _ | Import_snapshot _ | Synced_mirror _ | Native_local_graph _ ->
          Ok
            ( None
            , Worker_runner.sync_runner ~submit:(fun _ -> ()) ~shutdown:(fun () -> ()) ()
            )
      in
      match selected with
      | Error message -> Error message
      | Ok (sync_config, selected_sync_runner) ->
        (match Worker_runner.runtime ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task) with
         | Error error -> Error (worker_dependency_error_message error)
         | Ok runtime ->
           (match Pure.config ~worker:config ~sync:sync_config with
            | Error (Pure.Invalid_config message) -> Error message
            | Ok pure_config ->
              (match
                 Worker_runner.dependencies
                   ~runtime
                   ~config
                   ~engine:dependencies.engine
                   ~sync_runner:selected_sync_runner
                   ~publish:(publish context)
               with
               | Error error -> Error (worker_dependency_error_message error)
               | Ok runner_dependencies ->
                 (match Db.create ~sw ~config:pure_config ~runner_dependencies with
                  | Error (Db.Invalid_create message) -> Error message
                  | Ok worker ->
                    event_sink := Db.post worker;
                    Ok worker)))))
    ~handle:(fun _context worker request ->
      match request with
      | Get_graph_state -> Ok (Graph_state (Db.graph_state worker))
      | Client_command command ->
        if (Db.view worker).target = Pure.Managed
        then (
          Db.post worker (client_event command);
          Ok Client_command_completed)
        else Error "sync client is unavailable for this local graph target"
      | Graph_request request -> Ok (Graph_response (Db.request worker request)))
    ~shutdown:Db.shutdown
    ()
;;

let service = create ~dependencies:(production_dependencies ())
