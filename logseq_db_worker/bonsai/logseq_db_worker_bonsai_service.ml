module Db = Logseq_db_worker
module Core = Logseq_sync_pure_reducer.Core
module Effect_runner = Logseq_sync_effect_runner.Effect_runner
module Engine = Db.Engine
module Mutation = Logseq_db_types.Mutation
module Protocol = Db.Protocol
module ID = Bonsai_flutter_spec.Id

type client_command =
  | Restore_local_account of { user_id : string }
  | Reconcile_authenticated_user of { user_id : string option }
  | Acknowledge_local_feed
  | Acknowledge_timeline_presented
  | Provide_token of
      { request : Core.token_request
      ; token : string
      }
  | Reject_token of Core.token_request
  | Select_graph of Core.graph_id
  | Return_to_graph_picker
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password of string
  | Delete_local_cache of Core.graph_id
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
  | Client_state_changed of Core.state
  | Need_id_token of Core.token_request
  | Bootstrap_progress of Core.bootstrap_progress
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
  ; tls_authenticator : Effect_runner.tls_authenticator
  ; secrets : Effect_runner.secrets
  ; crypto : Effect_runner.crypto
  }

let dependencies ~engine ~tls_authenticator ~secrets ~crypto =
  { engine; tls_authenticator; secrets; crypto }
;;

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
  let secrets = Effect_runner.apple_secrets () |> Result.get_ok in
  let crypto = Effect_runner.apple_crypto () |> Result.get_ok in
  let tls_authenticator = Effect_runner.system_tls_authenticator () |> Result.get_ok in
  { engine; tls_authenticator; secrets; crypto }
;;

let take count values =
  let rec loop remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop count [] values
;;

let protocol_invalidation (invalidation : Core.invalidation) =
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
  Core.
    { basis = success.basis_after
    ; changed_uuids = success.changed_uuids
    ; changed_uuids_truncated = success.changed_uuids_truncated
    }
;;

let graph_failure (request : Protocol.request) message =
  let origin =
    Db.Error.create_cause_or_fallback
      ~component:Db.Error.Worker_service
      ~operation:"executeGraphRequest"
      ~code:(Some "graphUnavailable")
      ~message
      ~fallback_message:"The graph service is unavailable."
  in
  let error =
    Db.Error.create_with_origin
      ~code:Db.Error.Closed_session
      ~message:"The graph service is unavailable."
      ~details:[]
      ~origin
    |> Result.get_ok
  in
  Protocol.failed ~request_id:request.request_id ~phase:Execute ~basis:None error
;;

let config_for_graph config (request : Core.graph_open_request) =
  Db.Config.create
    ~application_support_directory:config.Db.Config.application_support_directory
    ~target:
      (Synced_mirror
         { graph_id = request.graph.graph_id
         ; graph_name = request.graph.name
         ; graph_dir = request.graph_directory
         ; database_path = request.database_path
         ; checkpoint = request.checkpoint
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

let service_error ~operation ~code ~public_message lower_message =
  let origin =
    Db.Error.create_cause_or_fallback
      ~component:Db.Error.Worker_service
      ~operation
      ~code:(Some "serviceFailure")
      ~message:lower_message
      ~fallback_message:"Worker service reported a display-unsafe failure."
  in
  Db.Error.create_with_origin ~code ~message:public_message ~details:[] ~origin
  |> Result.get_ok
;;

let contextualize_error ~operation error =
  let code = Db.Error.code error in
  let message = Db.Error.message error in
  let context =
    Db.Error.create_cause
      ~component:Db.Error.Worker_service
      ~operation
      ~code:(Some (Db.Error.code_string code))
      ~message
    |> Result.get_ok
  in
  Db.Error.wrap ~code ~message ~details:(Db.Error.details error) ~context error
  |> Result.get_ok
;;

module Managed_coordinator = struct
  type pending_mutation =
    { prepared : Engine.prepared_managed_mutation
    ; scope : Core.graph_scope
    ; engine : Engine.t
    ; admission_id : string
    ; result :
        (Logseq_db_types.Mutation.success, Core.local_batch_failure_kind * string) result
          Eio.Promise.u
    }

  type t =
    { mutable core : Core.t
    ; runner : Effect_runner.t
    ; mutable engine : Engine.t option
    ; context : push Worker.Session_context.t
    ; graph_lifecycle : Db.Graph_lifecycle.t
    ; engine_dependencies : Engine.dependencies
    ; config : Db.Config.t
    ; lock : Eio.Mutex.t
    ; graph_request_lock : Eio.Mutex.t
    ; mutable lifecycle_generation : int64
    ; mutable next_mutation_admission : int64
    ; mutable attached_scope : Core.graph_scope option
    ; pending_mutations : (string, pending_mutation) Hashtbl.t
    }

  let current_graph_generation t = (Core.state t.core).snapshot.startup.graph_generation

  let publish_state t state =
    Worker.Session_context.emit
      t.context
      ~topic:manager_topic
      (Client_state_changed state)
  ;;

  let resolve_pending pending outcome = Eio.Promise.resolve pending.result outcome

  let retire_pending_where t predicate kind message =
    Hashtbl.to_seq t.pending_mutations
    |> List.of_seq
    |> List.iter (fun (operation_id, pending) ->
      if predicate pending
      then (
        Hashtbl.remove t.pending_mutations operation_id;
        resolve_pending pending (Error (kind, message))))
  ;;

  let close_engine t generation kind message =
    match t.engine with
    | None -> retire_pending_where t (fun _ -> true) kind message
    | Some engine ->
      t.engine <- None;
      t.attached_scope <- None;
      retire_pending_where t (fun pending -> pending.engine == engine) kind message;
      Db.Graph_lifecycle.begin_close t.graph_lifecycle ~generation;
      publish_graph_state t.context t.graph_lifecycle;
      (match Engine.close engine with
       | Ok () ->
         Db.Graph_lifecycle.closed t.graph_lifecycle ~generation;
         publish_graph_state t.context t.graph_lifecycle
       | Error message ->
         let error =
           service_error
             ~operation:"closeGraph"
             ~code:Db.Error.Closed_session
             ~public_message:"The graph storage session could not close."
             message
         in
         Db.Graph_lifecycle.failed t.graph_lifecycle ~generation ~error;
         publish_graph_state t.context t.graph_lifecycle)
  ;;

  let scope_error scope message =
    Core.Graph_attachment_failed { scope = Core.effect_scope_of_graph scope; message }
  ;;

  let close_attached_engine t kind message =
    match t.attached_scope with
    | Some scope -> close_engine t scope.graph_generation kind message
    | None ->
      (match t.engine with
       | Some _ -> close_engine t (current_graph_generation t) kind message
       | None -> ())
  ;;

  let rec attach_graph t (request : Core.graph_open_request) =
    let scope = request.scope in
    if scope.graph_generation = current_graph_generation t
    then (
      close_attached_engine t Scope_closed "managed graph attachment was replaced";
      Db.Graph_lifecycle.begin_open
        t.graph_lifecycle
        ~generation:scope.graph_generation
        ~graph_id:(Some request.graph.graph_id);
      publish_graph_state t.context t.graph_lifecycle;
      match config_for_graph t.config request with
      | Error message ->
        let error =
          service_error
            ~operation:"configureGraph"
            ~code:Db.Error.Invalid_request
            ~public_message:"The managed graph configuration is invalid."
            message
        in
        Db.Graph_lifecycle.failed
          t.graph_lifecycle
          ~generation:scope.graph_generation
          ~error;
        publish_graph_state t.context t.graph_lifecycle;
        handle_event_unlocked t (scope_error scope message)
      | Ok graph_config ->
        (match Engine.open_ ~dependencies:t.engine_dependencies graph_config with
         | Error error ->
           let message = Db.Error.message error in
           let error = contextualize_error ~operation:"openManagedGraph" error in
           Db.Graph_lifecycle.failed
             t.graph_lifecycle
             ~generation:scope.graph_generation
             ~error;
           publish_graph_state t.context t.graph_lifecycle;
           handle_event_unlocked t (scope_error scope message)
         | Ok engine ->
           t.engine <- Some engine;
           t.attached_scope <- Some scope;
           let restored =
             Result.bind (Engine.sync_checkpoint engine) (fun checkpoint ->
               Result.map
                 (fun outbox_records -> checkpoint, outbox_records)
                 (Engine.managed_outbox_records engine))
           in
           (match restored with
            | Error message ->
              close_engine
                t
                scope.graph_generation
                Engine_unavailable
                "managed graph restoration failed";
              handle_event_unlocked t (scope_error scope message)
            | Ok (checkpoint, outbox_records) ->
              Db.Graph_lifecycle.opened
                t.graph_lifecycle
                ~generation:scope.graph_generation;
              publish_graph_state t.context t.graph_lifecycle;
              handle_event_unlocked
                t
                (Core.Graph_attached { scope; checkpoint; outbox_records }))))

  and inspect_mirror t (request : Core.mirror_request) =
    let graph_id = request.graph.graph_id in
    match
      Db.Synced_mirror.resolve
        ~application_support_directory:t.config.application_support_directory
        ~graph_id
    with
    | Error Db.Synced_mirror.Mirror_missing ->
      handle_event_unlocked t (Core.Mirror_inspected (Mirror_absent request.scope))
    | Error error ->
      handle_event_unlocked
        t
        (Core.Graph_attachment_failed
           { scope = Core.effect_scope_of_graph request.scope
           ; message = Db.Synced_mirror.error_message error
           })
    | Ok resolved ->
      handle_event_unlocked
        t
        (Core.Mirror_inspected
           (Mirror_available
              { graph = request.graph
              ; graph_directory = resolved.graph_dir
              ; database_path = resolved.database_path
              ; checkpoint = resolved.metadata
              ; scope = request.scope
              }))

  and activate_snapshot t (request : Core.snapshot_activation_request) =
    if request.scope.graph_generation = current_graph_generation t
    then (
      let decrypt_protected =
        Option.map
          (fun key -> Effect_runner.decrypt_protected_value t.runner key)
          request.key
      in
      match
        Db.Synced_mirror.bootstrap
          ~application_support_directory:t.config.application_support_directory
          ~graph_id:request.scope.graph_id
          ~applied_server_t:request.applied_server_t
          ~expected_rows:(Core.staged_artifact_expected_rows request.artifact)
          ~snapshot_path:(Core.staged_artifact_path request.artifact)
          ?decrypt_protected
          ()
      with
      | Ok _ ->
        handle_event_unlocked t (Core.Snapshot_activated { scope = request.scope })
      | Error error ->
        handle_event_unlocked
          t
          (Core.Snapshot_activation_failed
             { scope = Core.effect_scope_of_graph request.scope
             ; message = Db.Synced_mirror.error_message error
             }))

  and delete_mirror t (request : Core.mirror_deletion) =
    (match t.attached_scope with
     | Some scope
       when Logseq_db_types.Graph_types.Uuid.equal scope.graph_id request.graph_id ->
       close_attached_engine t Scope_closed "managed local cache was removed"
     | Some _ | None -> ());
    ignore
      (Db.Synced_mirror.delete
         ~application_support_directory:t.config.application_support_directory
         ~graph_id:request.graph_id)

  and decode_replan_mutation record =
    let payload = Core.outbox_record_mutation_payload record in
    let mutation =
      try Mutation.of_yojson (Yojson.Safe.from_string payload) with
      | Yojson.Json_error _ -> Error "The durable mutation payload is corrupt."
    in
    Result.bind mutation (fun mutation ->
      let identity = Mutation.identify mutation in
      let context = Mutation.context mutation in
      if
        not
          (Logseq_db_types.Graph_types.Uuid.equal
             context.mutation_id
             (Core.outbox_record_mutation_id record))
      then Error "The durable mutation ID does not match its semantic payload."
      else if
        not
          (String.equal
             (Mutation.identity_payload identity)
             (Core.outbox_record_mutation_payload record))
      then Error "The durable mutation payload is not canonical."
      else if
        not
          (String.equal
             (Mutation.identity_fingerprint identity)
             (Core.outbox_record_fingerprint record))
      then Error "The durable mutation fingerprint does not match its payload."
      else Ok mutation)

  and encode_replanned_record
        t
        (request : Core.authoritative_commit_request)
        database
        record
        (replan : Engine.managed_replan)
    =
    if
      not (String.equal replan.Engine.outliner_op (Core.outbox_record_outliner_op record))
    then Error "The durable outliner operation does not match its semantic payload."
    else
      Result.bind
        (Core.local_batch_input
           ~scope:request.scope
           ~admission_id:
             ("replan-"
              ^ Logseq_db_types.Graph_types.Uuid.to_string
                  (Core.outbox_record_mutation_id record))
           ~key:request.key
           ~outbox_records:[]
           ~mutation_id:(Core.outbox_record_mutation_id record)
           ~mutation_payload:(Core.outbox_record_mutation_payload record)
           ~mutation_fingerprint:(Core.outbox_record_fingerprint record)
           ~outliner_op:(Core.outbox_record_outliner_op record)
           ~database
           ~operations:replan.operations)
        (fun input ->
           Result.bind (Core.begin_local_batch input) (fun plan ->
             let encrypted =
               match Core.local_batch_crypto_request plan with
               | None -> Ok None
               | Some crypto_request ->
                 Result.map
                   Option.some
                   (Effect_runner.encrypt_protected_values
                      t.runner
                      crypto_request.key
                      crypto_request.plaintexts)
             in
             Result.bind encrypted (fun encrypted ->
               Core.finish_local_batch plan encrypted)))

  and replan_authoritative_outbox t engine (request : Core.authoritative_commit_request) =
    let current_precondition = Engine.authoritative_precondition engine in
    match current_precondition with
    | Error message -> Error (`Failed message)
    | Ok current when not (String.equal current request.precondition) -> Error `Conflict
    | Ok _ ->
      (match Engine.authoritative_database engine with
       | Error message -> Error (`Failed message)
       | Ok authoritative_before ->
         let authoritative_after =
           try
             Ok
               (List.fold_left
                  (fun database operations -> Datascript.db_with operations database)
                  authoritative_before
                  request.transactions)
           with
           | _ -> Error "The authoritative transactions cannot be staged."
         in
         Result.bind authoritative_after (fun authoritative_after ->
           Result.bind (Core.decode_outbox_records request.outbox_records) (fun records ->
             let rec block_suffix blocked = function
               | [] -> List.rev blocked
               | record :: rest ->
                 block_suffix
                   (Core.block_outbox_record
                      record
                      "Blocked by an earlier durable intent."
                    :: blocked)
                   rest
             in
             let rec loop database encoded projection = function
               | [] ->
                 Result.map
                   (fun outbox_records ->
                      List.rev projection, outbox_records, request.activity)
                   (Core.encode_outbox_records (List.rev encoded))
               | record :: rest ->
                 let retry_state =
                   match Core.outbox_record_state record with
                   | Core.Accepted server_t -> Core.Accepted server_t
                   | Queued | Submitted | Blocked _ -> Queued
                 in
                 let replanned =
                   Result.bind (decode_replan_mutation record) (fun mutation ->
                     Result.map
                       (fun replan -> mutation, replan)
                       (Engine.replan_managed_mutation engine ~database mutation))
                 in
                 (match replanned with
                  | Error _message ->
                    let blocked =
                      List.rev encoded
                      @ (Core.block_outbox_record
                           record
                           "The durable intent could not be replanned."
                         :: block_suffix [] rest)
                    in
                    Result.map
                      (fun outbox_records ->
                         ( List.rev projection
                         , outbox_records
                         , Logseq_db_types.Sync_status.Sync_submission_blocked ))
                      (Core.encode_outbox_records blocked)
                  | Ok (_mutation, replan)
                    when replan.status = Logseq_db_types.Mutation.No_change
                         || replan.status = Already_applied ->
                    (match retry_state with
                     | Core.Accepted _ ->
                       loop
                         database
                         (Core.clear_outbox_transport record retry_state :: encoded)
                         projection
                         rest
                     | Queued | Submitted | Blocked _ ->
                       loop database encoded projection rest)
                  | Ok (_mutation, replan) ->
                    (match encode_replanned_record t request database record replan with
                     | Error _message ->
                       let blocked =
                         List.rev encoded
                         @ (Core.block_outbox_record
                              record
                              "The durable intent could not be encoded."
                            :: block_suffix [] rest)
                       in
                       Result.map
                         (fun outbox_records ->
                            ( List.rev projection
                            , outbox_records
                            , Logseq_db_types.Sync_status.Sync_submission_blocked ))
                         (Core.encode_outbox_records blocked)
                     | Ok replanned_record ->
                       loop
                         replan.projected_database
                         (Core.outbox_record_with_state replanned_record retry_state
                          :: encoded)
                         (replan.operations :: projection)
                         rest))
             in
             loop authoritative_after [] [] records))
         |> Result.map_error (fun message -> `Failed message))

  and handle_worker_effect t = function
    | Core.Inspect_mirror request -> inspect_mirror t request
    | Activate_snapshot request -> activate_snapshot t request
    | Delete_mirror request -> delete_mirror t request
    | Attach_graph request -> attach_graph t request
    | Detach_graph detached_scope ->
      (match t.attached_scope with
       | Some scope when scope = detached_scope ->
         close_attached_engine t Scope_closed "managed graph was detached"
       | Some _ | None -> ())
    | Reset_managed_account account ->
      (match t.attached_scope with
       | Some scope when scope.account = account ->
         close_attached_engine t Scope_closed "managed account was reset"
       | Some _ | None ->
         retire_pending_where
           t
           (fun pending -> pending.scope.account = account)
           Scope_closed
           "managed account was reset")
    | Complete_local_batch request ->
      let operation_id =
        Logseq_db_types.Graph_types.Uuid.to_string request.operation_id
      in
      (match Hashtbl.find_opt t.pending_mutations operation_id with
       | Some pending
         when pending.scope <> request.scope
              || not (String.equal pending.admission_id request.admission_id) -> ()
       | Some pending ->
         Hashtbl.remove t.pending_mutations operation_id;
         (match request.action with
          | Reject { kind; message } -> resolve_pending pending (Error (kind, message))
          | Commit { outbox_records } ->
            (match t.engine, t.attached_scope with
             | Some engine, Some scope
               when engine == pending.engine && scope = pending.scope ->
               let committed =
                 Engine.commit_managed_mutation engine pending.prepared ~outbox_records
               in
               (match committed with
                | Error message ->
                  resolve_pending pending (Error (Persistence_failed, message))
                | Ok success ->
                  resolve_pending pending (Ok success);
                  handle_event_unlocked
                    t
                    (Core.Local_batch_committed { scope = request.scope; outbox_records }))
             | Some _, Some _ | Some _, None | None, Some _ | None, None ->
               resolve_pending
                 pending
                 (Error (Engine_unavailable, "managed graph is unavailable"))))
       | None -> ())
    | Commit_outbox_transition transition ->
      (match t.engine with
       | None -> ()
       | Some engine ->
         (match
            Engine.commit_outbox_transition
              engine
              ~expected:transition.expected_outbox_records
              transition.outbox_records
          with
          | Ok () ->
            handle_event_unlocked
              t
              (Core.Outbox_transition_committed
                 { scope = transition.scope
                 ; outbox_records = transition.outbox_records
                 ; pending_message = transition.pending_message
                 })
          | Error message ->
            let outbox_records =
              Engine.managed_outbox_records engine
              |> Result.fold ~ok:Fun.id ~error:(fun _ ->
                transition.expected_outbox_records)
            in
            handle_event_unlocked
              t
              (Core.Outbox_transition_rejected
                 { scope = transition.scope; outbox_records; message })))
    | Inspect_authoritative_batch batch ->
      (match t.engine, t.attached_scope with
       | Some engine, Some scope when scope = batch.scope.graph ->
         let context =
           Result.bind (Engine.authoritative_precondition engine) (fun precondition ->
             Result.bind (Engine.sync_checkpoint engine) (fun checkpoint ->
               Result.bind (Engine.authoritative_database engine) (fun database ->
                 Result.map
                   (fun outbox_records ->
                      Core.{ batch; precondition; checkpoint; database; outbox_records })
                   (Engine.managed_outbox_records engine))))
         in
         (match context with
          | Ok context ->
            handle_event_unlocked t (Core.Authoritative_batch_inspected context)
          | Error message ->
            handle_event_unlocked
              t
              (Core.Authoritative_batch_failed
                 { scope = Core.effect_scope_of_graph scope; message }))
       | Some _, Some _ | Some _, None | None, Some _ | None, None -> ())
    | Apply_authoritative_batch request ->
      (match t.engine, t.attached_scope with
       | Some engine, Some scope when scope = request.scope ->
         (match replan_authoritative_outbox t engine request with
          | Error `Conflict ->
            handle_event_unlocked t (Core.Authoritative_batch_conflicted request.batch)
          | Error (`Failed message) ->
            handle_event_unlocked
              t
              (Core.Authoritative_batch_failed
                 { scope = Core.effect_scope_of_graph scope; message })
          | Ok (projection_transactions, outbox_records, activity) ->
            (match
               Engine.apply_authoritative
                 engine
                 ~expected_precondition:request.precondition
                 request.transactions
                 ~projection_transactions
                 ~checkpoint:request.checkpoint
                 ~outbox_records
             with
             | Error Engine.Authoritative_conflict ->
               handle_event_unlocked t (Core.Authoritative_batch_conflicted request.batch)
             | Error (Engine.Authoritative_apply_failed message) ->
               handle_event_unlocked
                 t
                 (Core.Authoritative_batch_failed
                    { scope = Core.effect_scope_of_graph scope; message })
             | Ok (_basis_before, basis_after, changed_uuids, _database) ->
               let changed_uuids_truncated = List.length changed_uuids > 4096 in
               let changed_uuids = take 4096 changed_uuids in
               let invalidation =
                 if request.transactions = []
                 then None
                 else
                   Some
                     Core.{ basis = basis_after; changed_uuids; changed_uuids_truncated }
               in
               handle_event_unlocked
                 t
                 (Core.Authoritative_batch_applied
                    { scope
                    ; checkpoint = request.checkpoint
                    ; outbox_records
                    ; activity
                    ; invalidation
                    })))
       | Some _, Some _ | Some _, None | None, Some _ | None, None -> ())

  and handle_output t = function
    | Core.State_changed state -> publish_state t state
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

  and handle_effect_unlocked t = function
    | Core.Publish output -> handle_output t output
    | Run instruction -> Effect_runner.submit t.runner instruction
    | Delegate instruction -> handle_worker_effect t instruction

  and handle_event_unlocked t event =
    let transition = Core.step t.core event in
    t.core <- transition.next;
    List.iter (handle_effect_unlocked t) transition.effects
  ;;

  let handle t event =
    Eio.Mutex.use_rw ~protect:true t.lock (fun () -> handle_event_unlocked t event)
  ;;

  let handle_command t = function
    | Restore_local_account { user_id } ->
      handle t (Core.Restore_local_account { user_id })
    | Reconcile_authenticated_user { user_id } ->
      handle t (Core.Account_authenticated { user_id })
    | Acknowledge_local_feed -> handle t Core.Local_feed_acknowledged
    | Acknowledge_timeline_presented -> handle t Core.Timeline_presented
    | Provide_token { request; token } -> handle t (Core.Token_provided (request, token))
    | Reject_token request -> handle t (Core.Token_rejected request)
    | Select_graph graph_id -> handle t (Core.Graph_selected graph_id)
    | Return_to_graph_picker -> handle t Core.Graph_picker_requested
    | Refresh_catalog -> handle t Core.Catalog_refresh_requested
    | Begin_online_recovery -> handle t Core.Online_recovery_requested
    | Submit_e2ee_password password -> handle t (Core.E2ee_password_submitted password)
    | Delete_local_cache graph_id ->
      handle t (Core.Local_cache_deletion_requested graph_id)
    | Set_foreground foreground ->
      t.lifecycle_generation <- Int64.succ t.lifecycle_generation;
      handle
        t
        (Core.Foreground_changed
           { foreground; lifecycle_generation = t.lifecycle_generation })
  ;;

  type graph_execution =
    | Immediate of Protocol.response
    | Await_mutation of
        (Logseq_db_types.Mutation.success, Core.local_batch_failure_kind * string) result
          Eio.Promise.t
        * Protocol.request
        * Engine.t

  let mutation_failure
        (request : Protocol.request)
        engine
        (kind : Core.local_batch_failure_kind)
        lower_message
    =
    let code, message =
      match kind with
      | Scope_closed | Engine_unavailable ->
        ( Db.Error.Closed_session
        , "The managed graph session closed before the mutation committed." )
      | Persistence_failed ->
        Storage_busy, "The mutation could not be committed to local storage."
      | Planning_failed ->
        Unsupported_semantics, "The mutation could not be planned for this graph."
      | Encryption_failed -> Unsupported_semantics, "The mutation could not be encrypted."
      | Encoding_failed ->
        Unsupported_semantics, "The mutation could not be encoded for synchronization."
    in
    let origin_code =
      match kind with
      | Scope_closed -> "scopeClosed"
      | Engine_unavailable -> "engineUnavailable"
      | Persistence_failed -> "persistenceFailed"
      | Planning_failed -> "planningFailed"
      | Encryption_failed -> "encryptionFailed"
      | Encoding_failed -> "encodingFailed"
    in
    let origin =
      Db.Error.create_cause_or_fallback
        ~component:Db.Error.Managed_sync
        ~operation:"commitManagedMutation"
        ~code:(Some origin_code)
        ~message:lower_message
        ~fallback_message:"Managed sync reported a display-unsafe failure."
    in
    let error =
      Db.Error.create_with_origin ~code ~message ~details:[] ~origin |> Result.get_ok
    in
    Protocol.failed
      ~request_id:request.request_id
      ~phase:Execute
      ~basis:(Engine.basis engine)
      error
  ;;

  let mutation_response (request : Protocol.request) success =
    Protocol.Succeeded
      { request_id = request.request_id
      ; basis = success.Logseq_db_types.Mutation.basis_after
      ; success = Mutation_result success
      }
  ;;

  let begin_mutation t request engine mutation =
    let mutation_id = (Mutation.context mutation).mutation_id in
    let identity = Mutation.identify mutation in
    let mutation_fingerprint = Mutation.identity_fingerprint identity in
    match Engine.managed_outbox_records engine with
    | Error message ->
      Immediate (mutation_failure request engine Persistence_failed message)
    | Ok encoded_outbox ->
      (match Core.decode_outbox_records encoded_outbox with
       | Error message ->
         Immediate (mutation_failure request engine Encoding_failed message)
       | Ok outbox ->
         (match
            List.find_opt
              (fun record ->
                 Logseq_db_types.Graph_types.Uuid.equal
                   (Core.outbox_record_mutation_id record)
                   mutation_id)
              outbox
          with
          | Some record
            when String.equal (Core.outbox_record_fingerprint record) mutation_fingerprint
            ->
            (match Engine.duplicate_managed_mutation engine mutation with
             | Ok success -> Immediate (mutation_response request success)
             | Error message ->
               Immediate (mutation_failure request engine Planning_failed message))
          | Some _ ->
            Immediate
              (mutation_failure
                 request
                 engine
                 Planning_failed
                 "The mutation ID is already used by another durable outbox record.")
          | None ->
            (match t.attached_scope with
             | None ->
               Immediate
                 (mutation_failure
                    request
                    engine
                    Scope_closed
                    "managed graph scope is absent")
             | Some scope ->
               let admission_id = Int64.to_string t.next_mutation_admission in
               t.next_mutation_admission <- Int64.succ t.next_mutation_admission;
               (match Engine.prepare_managed_mutation engine ~identity mutation with
                | Error message ->
                  Immediate (mutation_failure request engine Planning_failed message)
                | Ok prepared ->
                  (match
                     Core.local_batch_input
                       ~scope
                       ~admission_id
                       ~key:None
                       ~outbox_records:encoded_outbox
                       ~mutation_id
                       ~mutation_payload:(Engine.prepared_mutation_payload prepared)
                       ~mutation_fingerprint
                       ~outliner_op:(Engine.prepared_mutation_outliner_op prepared)
                       ~database:(Engine.prepared_mutation_database prepared)
                       ~operations:(Engine.prepared_mutation_operations prepared)
                   with
                   | Error message ->
                     Immediate (mutation_failure request engine Planning_failed message)
                   | Ok input ->
                     let result, resolve = Eio.Promise.create () in
                     Hashtbl.add
                       t.pending_mutations
                       (Logseq_db_types.Graph_types.Uuid.to_string mutation_id)
                       { prepared; scope; engine; admission_id; result = resolve };
                     handle_event_unlocked t (Core.Local_batch_prepared input);
                     Await_mutation (result, request, engine))))))
  ;;

  let execute_graph_request_unlocked t request =
    match t.engine, t.attached_scope, Core.admitted_graph_scope t.core with
    | Some engine, Some attached, Some admitted when attached = admitted ->
      (match request.Protocol.command with
       | Read _ -> Immediate (Engine.execute engine request)
       | Mutate mutation -> begin_mutation t request engine mutation)
    | Some _, Some _, Some _ | Some _, Some _, None | Some _, None, _ | None, _, _ ->
      Immediate (graph_failure request "no admitted managed graph is open")
  ;;

  let execute_graph_request t request =
    Eio.Mutex.use_rw ~protect:true t.graph_request_lock (fun () ->
      match
        Eio.Mutex.use_rw ~protect:true t.lock (fun () ->
          execute_graph_request_unlocked t request)
      with
      | Immediate response -> response
      | Await_mutation (result, request, engine) ->
        (match Eio.Promise.await result with
         | Error (kind, message) -> mutation_failure request engine kind message
         | Ok success ->
           if success.Logseq_db_types.Mutation.status = Applied
           then
             Worker.Session_context.emit
               t.context
               ~topic:invalidation_topic
               (Graph_push (protocol_invalidation (mutation_invalidation success)));
           mutation_response request success))
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

let dependency_error_message = function
  | Effect_runner.Invalid_dependency message -> message
;;

let config_error_message = function
  | Core.Invalid_config message -> message
;;

let core_create_error_message = function
  | Core.Invalid_create message -> message
;;

let runner_create_error_message = function
  | Effect_runner.Invalid_create message -> message
;;

let create ~(dependencies : dependencies) =
  Worker.Service.create
    ~push_topic_count:5
    ~concurrency:(Worker.Service.Concurrent { max_in_flight = 2 })
    ~data_directory:(fun config -> Ok config.Db.Config.application_support_directory)
    ~init:(fun context config ->
      match Worker.Session_context.data_dir context with
      | None -> Error "application-support data directory capability is unavailable"
      | Some _ ->
        (match config.Db.Config.target with
         | Managed_sync { base_url } ->
           let environment = Worker.Session_context.environment context in
           let clock = Eio.Stdenv.clock environment in
           let sw = Worker.Session_context.switch context in
           let events = Eio.Stream.create 256 in
           let construct =
             Result.bind
               (Effect_runner.runtime
                  ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
                  ~sleep:(Eio.Time.sleep clock)
                  ~monotonic_ns:Mtime_clock.elapsed_ns)
               (fun runtime ->
                  Result.bind
                    (Effect_runner.transport
                       ~tls_authenticator:dependencies.tls_authenticator
                       ~network:(Eio.Stdenv.net environment)
                       ~clock)
                    (fun transport ->
                       Result.bind
                         (Effect_runner.local_store
                            ~application_support_directory:
                              config.application_support_directory)
                         (fun local_store ->
                            Result.bind
                              (Effect_runner.artifact_store
                                 ~staging_directory:
                                   (Filename.concat
                                      config.application_support_directory
                                      "sync-staging"))
                              (fun artifact_store ->
                                 Effect_runner.dependencies
                                   ~runtime
                                   ~transport
                                   ~local_store
                                   ~artifact_store
                                   ~secrets:dependencies.secrets
                                   ~crypto:dependencies.crypto))))
           in
           (match construct with
            | Error error -> Error (dependency_error_message error)
            | Ok runner_dependencies ->
              (match
                 Core.limits
                   ~maximum_response_bytes:config.response_budget_bytes
                   ~maximum_artifact_bytes:(1024 * 1024 * 1024)
                   ~submission_batch_size:32
               with
               | Error error -> Error (config_error_message error)
               | Ok limits ->
                 (match
                    Core.config ~managed_sync_origin:(Uri.of_string base_url) ~limits
                  with
                  | Error error -> Error (config_error_message error)
                  | Ok core_config ->
                    (match Core.initial core_config with
                     | Error error -> Error (core_create_error_message error)
                     | Ok core ->
                       (match
                          Effect_runner.create
                            ~sw
                            runner_dependencies
                            ~post:(Eio.Stream.add events)
                        with
                        | Error error -> Error (runner_create_error_message error)
                        | Ok runner ->
                          let graph_lifecycle = Db.Graph_lifecycle.create () in
                          let coordinator =
                            Managed_coordinator.
                              { core
                              ; runner
                              ; engine = None
                              ; context
                              ; graph_lifecycle
                              ; engine_dependencies = dependencies.engine
                              ; config
                              ; lock = Eio.Mutex.create ()
                              ; graph_request_lock = Eio.Mutex.create ()
                              ; lifecycle_generation = 0L
                              ; next_mutation_admission = 0L
                              ; attached_scope = None
                              ; pending_mutations = Hashtbl.create 32
                              }
                          in
                          Worker.Session_context.fork_daemon
                            context
                            ~name:"managed-sync-completions"
                            (fun () ->
                               let rec loop () =
                                 Managed_coordinator.handle
                                   coordinator
                                   (Eio.Stream.take events);
                                 loop ()
                               in
                               loop ());
                          Ok (Managed coordinator))))))
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
              let error = contextualize_error ~operation:"openGraph" error in
              Db.Graph_lifecycle.failed graph_lifecycle ~generation:0 ~error;
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
           Managed_coordinator.handle_command managed command;
           Ok Client_command_completed
         | Graph_request request ->
           (try
              Ok
                (Graph_response
                   (Managed_coordinator.execute_graph_request managed request))
            with
            | Engine.Fatal_storage_error error ->
              let generation =
                (Db.Graph_lifecycle.state managed.graph_lifecycle).generation
              in
              Db.Graph_lifecycle.failed managed.graph_lifecycle ~generation ~error;
              publish_graph_state managed.context managed.graph_lifecycle;
              Ok
                (Graph_response
                   (Protocol.failed
                      ~request_id:request.request_id
                      ~phase:Execute
                      ~basis:None
                      error))))
      | Graph_bound { engine; open_error; invalidations; graph_lifecycle; context } ->
        (match request with
         | Get_graph_state -> Ok (Graph_state (Db.Graph_lifecycle.state graph_lifecycle))
         | Client_command _ ->
           Error "sync client is unavailable for this local graph target"
         | Graph_request request ->
           let response =
             match engine, open_error with
             | Some engine, _ ->
               let response =
                 try Engine.execute engine request with
                 | Engine.Fatal_storage_error error ->
                   let generation =
                     (Db.Graph_lifecycle.state graph_lifecycle).generation
                   in
                   Db.Graph_lifecycle.failed graph_lifecycle ~generation ~error;
                   publish_graph_state context graph_lifecycle;
                   Protocol.failed
                     ~request_id:request.request_id
                     ~phase:Execute
                     ~basis:(Engine.basis engine)
                     error
               in
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
        Managed_coordinator.handle managed Core.Shutdown;
        Effect_runner.shutdown managed.runner;
        Managed_coordinator.close_engine
          managed
          (Managed_coordinator.current_graph_generation managed)
          Core.Scope_closed
          "managed service shut down"
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
           let error =
             service_error
               ~operation:"closeGraph"
               ~code:Db.Error.Closed_session
               ~public_message:"The graph storage session could not close."
               message
           in
           Db.Graph_lifecycle.failed graph_lifecycle ~generation ~error;
           publish_graph_state context graph_lifecycle;
           failwith ("logseq-db-worker close failed: " ^ message)))
    ()
;;

let service = create ~dependencies:(production_dependencies ())
