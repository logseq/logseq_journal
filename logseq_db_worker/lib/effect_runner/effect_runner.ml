module Core = Logseq_db_worker_pure_reducer.Core
module Sync = Logseq_sync_pure_reducer.Core

type runtime = { fork : sw:Eio.Switch.t -> (unit -> unit) -> unit }

type sync_runner =
  { submit : Logseq_sync_pure_reducer.Core.runner_effect -> unit
  ; shutdown : unit -> unit
  ; decrypt_protected_value :
      Logseq_sync_pure_reducer.Core.graph_key_handle -> string -> (string, string) result
  ; encrypt_protected_values :
      Logseq_sync_pure_reducer.Core.graph_key_handle
      -> string list
      -> ((string * string) list, string) result
  }

type dependencies =
  { runtime : runtime
  ; config : Logseq_db_worker_contract.Config.t
  ; engine : Logseq_db_worker_engine.Engine.dependencies
  ; sync_runner : sync_runner
  ; publish : Core.output -> unit
  }

type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string

type waiter =
  { request : Logseq_db_worker_contract.Protocol.request
  ; resolve : Logseq_db_worker_contract.Protocol.response Eio.Promise.u
  }

type prepared_mutation =
  { prepared : Logseq_db_worker_engine.Engine.prepared_managed_mutation
  ; engine_id : string
  ; scope : Logseq_sync_pure_reducer.Core.graph_scope
  }

type t =
  { sw : Eio.Switch.t
  ; dependencies : dependencies
  ; post : Core.event -> unit
  ; engines : (string, Logseq_db_worker_engine.Engine.t) Hashtbl.t
  ; waiters : (int64, waiter) Hashtbl.t
  ; waiter_lock : Eio.Mutex.t
  ; prepared_mutations : (string, prepared_mutation) Hashtbl.t
  ; mutable attached : (string * Logseq_sync_pure_reducer.Core.graph_scope) option
  ; mutable next_engine_id : int64
  ; mutable stopped : bool
  }

let runtime ~fork = Ok { fork }

let sync_runner
      ?(decrypt_protected_value = fun _ _ -> Error "sync decryption is unavailable")
      ?(encrypt_protected_values = fun _ _ -> Error "sync encryption is unavailable")
      ~submit
      ~shutdown
      ()
  =
  { submit; shutdown; decrypt_protected_value; encrypt_protected_values }
;;

let dependencies ~runtime ~config ~engine ~sync_runner ~publish =
  Ok { runtime; config; engine; sync_runner; publish }
;;

let create ~sw dependencies ~post =
  Ok
    { sw
    ; dependencies
    ; post
    ; engines = Hashtbl.create 4
    ; waiters = Hashtbl.create 32
    ; waiter_lock = Eio.Mutex.create ()
    ; prepared_mutations = Hashtbl.create 32
    ; attached = None
    ; next_engine_id = 0L
    ; stopped = false
    }
;;

let runner_error ~code ~public_message lower_message =
  let origin =
    Logseq_db_worker_contract.Error.create_cause_or_fallback
      ~component:Logseq_db_worker_contract.Error.Worker_service
      ~operation:"runWorkerEffect"
      ~code:(Some "runnerFailure")
      ~message:lower_message
      ~fallback_message:"The worker runner reported a display-unsafe failure."
  in
  Logseq_db_worker_contract.Error.create_with_origin
    ~code
    ~message:public_message
    ~details:[]
    ~origin
  |> Result.get_ok
;;

let effect_error message =
  runner_error
    ~code:Logseq_db_worker_contract.Error.Storage_busy
    ~public_message:"The worker operation failed."
    message
;;

let take count values =
  let rec loop remaining reversed = function
    | _ when remaining = 0 -> List.rev reversed
    | [] -> List.rev reversed
    | value :: rest -> loop (remaining - 1) (value :: reversed) rest
  in
  loop count [] values
;;

let sync_result ?event ?(lifecycle = Core.Lifecycle_unchanged) ?mutation_success () =
  Core.{ event; lifecycle; mutation_success }
;;

let close_engine_by_id t engine_id =
  match Hashtbl.find_opt t.engines engine_id with
  | None -> Ok ()
  | Some engine ->
    let result = Logseq_db_worker_engine.Engine.close engine in
    Hashtbl.remove t.engines engine_id;
    result
;;

let close_attached t =
  match t.attached with
  | None -> Ok ()
  | Some (engine_id, scope) ->
    t.attached <- None;
    Hashtbl.filter_map_inplace
      (fun _ pending -> if pending.scope = scope then None else Some pending)
      t.prepared_mutations;
    close_engine_by_id t engine_id
;;

let config_for_graph
      (config : Logseq_db_worker_contract.Config.t)
      (request : Logseq_sync_pure_reducer.Core.graph_open_request)
  =
  Logseq_db_worker_contract.Config.create
    ~application_support_directory:config.application_support_directory
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

let managed_response (request : Logseq_db_worker_contract.Protocol.request) success =
  Logseq_db_worker_contract.Protocol.Succeeded
    { request_id = request.Logseq_db_worker_contract.Protocol.request_id
    ; basis = success.Logseq_db_types.Mutation.basis_after
    ; success = Mutation_result success
    }
;;

let managed_failure
      (request : Logseq_db_worker_contract.Protocol.request)
      code
      lower_message
  =
  Logseq_db_worker_contract.Protocol.failed
    ~request_id:request.Logseq_db_worker_contract.Protocol.request_id
    ~phase:Execute
    ~basis:None
    (runner_error ~code ~public_message:"The managed graph request failed." lower_message)
;;

let prepare_managed_mutation
      t
      ~engine
      ~scope
      ~admission_id
      (request : Logseq_db_worker_contract.Protocol.request)
  =
  let engine_id = Core.engine_handle_id engine in
  match Hashtbl.find_opt t.engines engine_id with
  | None ->
    Ok
      (Core.Managed_immediate
         (managed_failure
            request
            Closed_session
            "The managed graph session is unavailable."))
  | Some engine ->
    (match request.Logseq_db_worker_contract.Protocol.command with
     | Read _ ->
       Ok (Core.Managed_immediate (Logseq_db_worker_engine.Engine.execute engine request))
     | Mutate mutation ->
       let module Mutation = Logseq_db_types.Mutation in
       let mutation_id = (Mutation.context mutation).mutation_id in
       let identity = Mutation.identify mutation in
       let fingerprint = Mutation.identity_fingerprint identity in
       (match Logseq_db_worker_engine.Engine.managed_outbox_records engine with
        | Error message ->
          Ok (Core.Managed_immediate (managed_failure request Storage_busy message))
        | Ok encoded_outbox ->
          (match Logseq_sync_pure_reducer.Core.decode_outbox_records encoded_outbox with
           | Error message ->
             Ok (Core.Managed_immediate (managed_failure request Corrupt_storage message))
           | Ok outbox ->
             (match
                List.find_opt
                  (fun record ->
                     Logseq_db_types.Graph_types.Uuid.equal
                       (Logseq_sync_pure_reducer.Core.outbox_record_mutation_id record)
                       mutation_id)
                  outbox
              with
              | Some record
                when String.equal
                       (Logseq_sync_pure_reducer.Core.outbox_record_fingerprint record)
                       fingerprint ->
                (match
                   Logseq_db_worker_engine.Engine.duplicate_managed_mutation
                     engine
                     mutation
                 with
                 | Ok success ->
                   Ok (Core.Managed_immediate (managed_response request success))
                 | Error message ->
                   Ok (Core.Managed_immediate (managed_failure request Conflict message)))
              | Some _ ->
                Ok
                  (Core.Managed_immediate
                     (managed_failure
                        request
                        Conflict
                        "The mutation ID is already used by another durable intent."))
              | None ->
                (match
                   Logseq_db_worker_engine.Engine.prepare_managed_mutation
                     engine
                     ~identity
                     mutation
                 with
                 | Error message ->
                   Ok
                     (Core.Managed_immediate
                        (managed_failure request Unsupported_semantics message))
                 | Ok prepared ->
                   (match
                      Logseq_sync_pure_reducer.Core.local_batch_input
                        ~scope
                        ~admission_id
                        ~key:None
                        ~outbox_records:encoded_outbox
                        ~mutation_id
                        ~mutation_payload:
                          (Logseq_db_worker_engine.Engine.prepared_mutation_payload
                             prepared)
                        ~mutation_fingerprint:fingerprint
                        ~outliner_op:
                          (Logseq_db_worker_engine.Engine.prepared_mutation_outliner_op
                             prepared)
                        ~database:
                          (Logseq_db_worker_engine.Engine.prepared_mutation_database
                             prepared)
                        ~operations:
                          (Logseq_db_worker_engine.Engine.prepared_mutation_operations
                             prepared)
                    with
                    | Error message ->
                      Ok
                        (Core.Managed_immediate
                           (managed_failure request Unsupported_semantics message))
                    | Ok input ->
                      Hashtbl.replace
                        t.prepared_mutations
                        admission_id
                        { prepared; engine_id; scope };
                      Ok (Core.Managed_prepared { admission_id; input })))))))
;;

let decode_replan_mutation record =
  let payload = Sync.outbox_record_mutation_payload record in
  let mutation =
    try Logseq_db_types.Mutation.of_yojson (Yojson.Safe.from_string payload) with
    | Yojson.Json_error _ -> Error "The durable mutation payload is corrupt."
  in
  Result.bind mutation (fun mutation ->
    let identity = Logseq_db_types.Mutation.identify mutation in
    let context = Logseq_db_types.Mutation.context mutation in
    if
      not
        (Logseq_db_types.Graph_types.Uuid.equal
           context.mutation_id
           (Sync.outbox_record_mutation_id record))
    then Error "The durable mutation ID does not match its semantic payload."
    else if
      not
        (String.equal
           (Logseq_db_types.Mutation.identity_payload identity)
           (Sync.outbox_record_mutation_payload record))
    then Error "The durable mutation payload is not canonical."
    else if
      not
        (String.equal
           (Logseq_db_types.Mutation.identity_fingerprint identity)
           (Sync.outbox_record_fingerprint record))
    then Error "The durable mutation fingerprint does not match its payload."
    else Ok mutation)
;;

let encode_replanned_record
      t
      (request : Sync.authoritative_commit_request)
      database
      record
      (replan : Logseq_db_worker_engine.Engine.managed_replan)
  =
  if not (String.equal replan.outliner_op (Sync.outbox_record_outliner_op record))
  then Error "The durable outliner operation does not match its semantic payload."
  else
    Result.bind
      (Sync.local_batch_input
         ~scope:request.scope
         ~admission_id:
           ("replan-"
            ^ Logseq_db_types.Graph_types.Uuid.to_string
                (Sync.outbox_record_mutation_id record))
         ~key:request.key
         ~outbox_records:[]
         ~mutation_id:(Sync.outbox_record_mutation_id record)
         ~mutation_payload:(Sync.outbox_record_mutation_payload record)
         ~mutation_fingerprint:(Sync.outbox_record_fingerprint record)
         ~outliner_op:(Sync.outbox_record_outliner_op record)
         ~database
         ~operations:replan.operations)
      (fun input ->
         Result.bind (Sync.begin_local_batch input) (fun plan ->
           let encrypted =
             match Sync.local_batch_crypto_request plan with
             | None -> Ok None
             | Some crypto_request ->
               Result.map
                 Option.some
                 (t.dependencies.sync_runner.encrypt_protected_values
                    crypto_request.key
                    crypto_request.plaintexts)
           in
           Result.bind encrypted (Sync.finish_local_batch plan)))
;;

let replan_authoritative_outbox t engine (request : Sync.authoritative_commit_request) =
  match Logseq_db_worker_engine.Engine.authoritative_precondition engine with
  | Error message -> Error (`Failed message)
  | Ok current when not (String.equal current request.precondition) -> Error `Conflict
  | Ok _ ->
    (match Logseq_db_worker_engine.Engine.authoritative_database engine with
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
         Result.bind (Sync.decode_outbox_records request.outbox_records) (fun records ->
           let rec block_suffix blocked = function
             | [] -> List.rev blocked
             | record :: rest ->
               block_suffix
                 (Sync.block_outbox_record record "Blocked by an earlier durable intent."
                  :: blocked)
                 rest
           in
           let rec loop database encoded projection = function
             | [] ->
               Result.map
                 (fun outbox_records ->
                    List.rev projection, outbox_records, request.activity)
                 (Sync.encode_outbox_records (List.rev encoded))
             | record :: rest ->
               let retry_state =
                 match Sync.outbox_record_state record with
                 | Sync.Accepted server_t -> Sync.Accepted server_t
                 | Queued | Submitted | Blocked _ -> Queued
               in
               let replanned =
                 Result.bind (decode_replan_mutation record) (fun mutation ->
                   Result.map
                     (fun replan -> mutation, replan)
                     (Logseq_db_worker_engine.Engine.replan_managed_mutation
                        engine
                        ~database
                        mutation))
               in
               (match replanned with
                | Error _ ->
                  let blocked =
                    List.rev encoded
                    @ (Sync.block_outbox_record
                         record
                         "The durable intent could not be replanned."
                       :: block_suffix [] rest)
                  in
                  Result.map
                    (fun outbox_records ->
                       ( List.rev projection
                       , outbox_records
                       , Logseq_db_types.Sync_status.Sync_submission_blocked ))
                    (Sync.encode_outbox_records blocked)
                | Ok (_, replan)
                  when replan.status = Logseq_db_types.Mutation.No_change
                       || replan.status = Already_applied ->
                  (match retry_state with
                   | Sync.Accepted _ ->
                     loop
                       database
                       (Sync.clear_outbox_transport record retry_state :: encoded)
                       projection
                       rest
                   | Queued | Submitted | Blocked _ ->
                     loop database encoded projection rest)
                | Ok (_, replan) ->
                  (match encode_replanned_record t request database record replan with
                   | Error _ ->
                     let blocked =
                       List.rev encoded
                       @ (Sync.block_outbox_record
                            record
                            "The durable intent could not be encoded."
                          :: block_suffix [] rest)
                     in
                     Result.map
                       (fun outbox_records ->
                          ( List.rev projection
                          , outbox_records
                          , Logseq_db_types.Sync_status.Sync_submission_blocked ))
                       (Sync.encode_outbox_records blocked)
                   | Ok replanned_record ->
                     loop
                       replan.projected_database
                       (Sync.outbox_record_with_state replanned_record retry_state
                        :: encoded)
                       (replan.operations :: projection)
                       rest))
           in
           loop authoritative_after [] [] records))
       |> Result.map_error (fun message -> `Failed message))
;;

let handle_sync_worker_effect t runner_effect =
  match runner_effect with
  | Sync.Inspect_mirror request ->
    (match
       Logseq_db_worker_engine.Synced_mirror.resolve
         ~application_support_directory:
           t.dependencies.config.application_support_directory
         ~graph_id:request.graph.graph_id
     with
     | Error Mirror_missing ->
       Ok (sync_result ~event:(Sync.Mirror_inspected (Mirror_absent request.scope)) ())
     | Error error ->
       Ok
         (sync_result
            ~event:
              (Sync.Graph_attachment_failed
                 { scope = Sync.effect_scope_of_graph request.scope
                 ; message = Logseq_db_worker_engine.Synced_mirror.error_message error
                 })
            ())
     | Ok resolved ->
       Ok
         (sync_result
            ~event:
              (Sync.Mirror_inspected
                 (Mirror_available
                    { graph = request.graph
                    ; graph_directory = resolved.graph_dir
                    ; database_path = resolved.database_path
                    ; checkpoint = resolved.metadata
                    ; scope = request.scope
                    }))
            ()))
  | Activate_snapshot request ->
    let decrypt_protected =
      Option.map
        (fun key -> t.dependencies.sync_runner.decrypt_protected_value key)
        request.key
    in
    (match
       Logseq_db_worker_engine.Synced_mirror.bootstrap
         ~application_support_directory:
           t.dependencies.config.application_support_directory
         ~graph_id:request.scope.graph_id
         ~applied_server_t:request.applied_server_t
         ~expected_rows:(Sync.staged_artifact_expected_rows request.artifact)
         ~snapshot_path:(Sync.staged_artifact_path request.artifact)
         ?decrypt_protected
         ()
     with
     | Ok _ ->
       Ok (sync_result ~event:(Sync.Snapshot_activated { scope = request.scope }) ())
     | Error error ->
       Ok
         (sync_result
            ~event:
              (Sync.Snapshot_activation_failed
                 { scope = Sync.effect_scope_of_graph request.scope
                 ; message = Logseq_db_worker_engine.Synced_mirror.error_message error
                 })
            ()))
  | Delete_mirror request ->
    let lifecycle =
      match t.attached with
      | Some (_, scope)
        when Logseq_db_types.Graph_types.Uuid.equal scope.graph_id request.graph_id ->
        ignore (close_attached t);
        Core.Lifecycle_closed scope.graph_generation
      | Some _ | None -> Lifecycle_unchanged
    in
    ignore
      (Logseq_db_worker_engine.Synced_mirror.delete
         ~application_support_directory:
           t.dependencies.config.application_support_directory
         ~graph_id:request.graph_id);
    Ok (sync_result ~lifecycle ())
  | Attach_graph request ->
    ignore (close_attached t);
    (match config_for_graph t.dependencies.config request with
     | Error message ->
       let error = effect_error message in
       Ok
         (sync_result
            ~event:
              (Sync.Graph_attachment_failed
                 { scope = Sync.effect_scope_of_graph request.scope; message })
            ~lifecycle:(Core.Lifecycle_failed (request.scope.graph_generation, error))
            ())
     | Ok config ->
       (match
          Logseq_db_worker_engine.Engine.open_ ~dependencies:t.dependencies.engine config
        with
        | Error error ->
          let message = Logseq_db_worker_contract.Error.message error in
          Ok
            (sync_result
               ~event:
                 (Sync.Graph_attachment_failed
                    { scope = Sync.effect_scope_of_graph request.scope; message })
               ~lifecycle:(Core.Lifecycle_failed (request.scope.graph_generation, error))
               ())
        | Ok engine ->
          let engine_id = "managed-" ^ Int64.to_string t.next_engine_id in
          t.next_engine_id <- Int64.succ t.next_engine_id;
          Hashtbl.replace t.engines engine_id engine;
          t.attached <- Some (engine_id, request.scope);
          (match
             Result.bind
               (Logseq_db_worker_engine.Engine.sync_checkpoint engine)
               (fun checkpoint ->
                  Result.map
                    (fun outbox_records -> checkpoint, outbox_records)
                    (Logseq_db_worker_engine.Engine.managed_outbox_records engine))
           with
           | Error message ->
             ignore (close_attached t);
             let error = effect_error message in
             Ok
               (sync_result
                  ~event:
                    (Sync.Graph_attachment_failed
                       { scope = Sync.effect_scope_of_graph request.scope; message })
                  ~lifecycle:
                    (Core.Lifecycle_failed (request.scope.graph_generation, error))
                  ())
           | Ok (checkpoint, outbox_records) ->
             let opened =
               Core.engine_opened
                 ~engine_id
                 ~graph_id:(Some request.scope.graph_id)
                 ~basis:(Logseq_db_worker_engine.Engine.basis engine)
             in
             Ok
               (sync_result
                  ~event:
                    (Sync.Graph_attached
                       { scope = request.scope; checkpoint; outbox_records })
                  ~lifecycle:
                    (Core.Lifecycle_opened (opened, request.scope.graph_generation))
                  ()))))
  | Detach_graph scope ->
    (match t.attached with
     | Some (_, attached) when attached = scope -> ignore (close_attached t)
     | Some _ | None -> ());
    Ok (sync_result ~lifecycle:(Core.Lifecycle_closed scope.graph_generation) ())
  | Reset_managed_account account ->
    let lifecycle =
      match t.attached with
      | Some (_, scope) when scope.account = account ->
        ignore (close_attached t);
        Core.Lifecycle_closed scope.graph_generation
      | Some _ | None -> Lifecycle_unchanged
    in
    Ok (sync_result ~lifecycle ())
  | Complete_local_batch request ->
    (match Hashtbl.find_opt t.prepared_mutations request.admission_id with
     | None -> Ok (sync_result ())
     | Some pending when pending.scope <> request.scope -> Ok (sync_result ())
     | Some pending ->
       Hashtbl.remove t.prepared_mutations request.admission_id;
       (match request.action with
        | Reject _ -> Ok (sync_result ())
        | Commit { outbox_records } ->
          (match Hashtbl.find_opt t.engines pending.engine_id with
           | None -> Error (effect_error "The managed Engine is unavailable.")
           | Some engine ->
             (match
                Logseq_db_worker_engine.Engine.commit_managed_mutation
                  engine
                  pending.prepared
                  ~outbox_records
              with
              | Error message -> Error (effect_error message)
              | Ok success ->
                Ok
                  (sync_result
                     ~event:
                       (Sync.Local_batch_committed
                          { scope = request.scope; outbox_records })
                     ~mutation_success:success
                     ())))))
  | Inspect_authoritative_batch batch ->
    (match t.attached with
     | Some (engine_id, scope) when scope = batch.scope.graph ->
       (match Hashtbl.find_opt t.engines engine_id with
        | None -> Error (effect_error "The managed Engine is unavailable.")
        | Some engine ->
          let context =
            Result.bind
              (Logseq_db_worker_engine.Engine.authoritative_precondition engine)
              (fun precondition ->
                 Result.bind
                   (Logseq_db_worker_engine.Engine.sync_checkpoint engine)
                   (fun checkpoint ->
                      Result.bind
                        (Logseq_db_worker_engine.Engine.authoritative_database engine)
                        (fun database ->
                           Result.map
                             (fun outbox_records ->
                                Sync.
                                  { batch
                                  ; precondition
                                  ; checkpoint
                                  ; database
                                  ; outbox_records
                                  })
                             (Logseq_db_worker_engine.Engine.managed_outbox_records
                                engine))))
          in
          (match context with
           | Ok context ->
             Ok (sync_result ~event:(Sync.Authoritative_batch_inspected context) ())
           | Error message ->
             Ok
               (sync_result
                  ~event:
                    (Sync.Authoritative_batch_failed
                       { scope = Sync.effect_scope_of_graph scope; message })
                  ())))
     | Some _ | None -> Error (effect_error "The authoritative graph scope is stale."))
  | Apply_authoritative_batch request ->
    (match t.attached with
     | Some (engine_id, scope) when scope = request.scope ->
       (match Hashtbl.find_opt t.engines engine_id with
        | None -> Error (effect_error "The managed Engine is unavailable.")
        | Some engine ->
          (match replan_authoritative_outbox t engine request with
           | Error `Conflict ->
             Ok
               (sync_result ~event:(Sync.Authoritative_batch_conflicted request.batch) ())
           | Error (`Failed message) ->
             Ok
               (sync_result
                  ~event:
                    (Sync.Authoritative_batch_failed
                       { scope = Sync.effect_scope_of_graph scope; message })
                  ())
           | Ok (projection_transactions, outbox_records, activity) ->
             (match
                Logseq_db_worker_engine.Engine.apply_authoritative
                  engine
                  ~expected_precondition:request.precondition
                  request.transactions
                  ~projection_transactions
                  ~checkpoint:request.checkpoint
                  ~outbox_records
              with
              | Error Authoritative_conflict ->
                Ok
                  (sync_result
                     ~event:(Sync.Authoritative_batch_conflicted request.batch)
                     ())
              | Error (Authoritative_apply_failed message) ->
                Ok
                  (sync_result
                     ~event:
                       (Sync.Authoritative_batch_failed
                          { scope = Sync.effect_scope_of_graph scope; message })
                     ())
              | Ok (_, basis_after, changed_uuids, _) ->
                let invalidation =
                  if request.transactions = []
                  then None
                  else
                    Some
                      Sync.
                        { basis = basis_after
                        ; changed_uuids = take 4096 changed_uuids
                        ; changed_uuids_truncated = List.length changed_uuids > 4096
                        }
                in
                Ok
                  (sync_result
                     ~event:
                       (Sync.Authoritative_batch_applied
                          { scope
                          ; checkpoint = request.checkpoint
                          ; outbox_records
                          ; activity
                          ; invalidation
                          })
                     ()))))
     | Some _ | None -> Error (effect_error "The authoritative graph scope is stale."))
  | Commit_outbox_transition transition ->
    (match t.attached with
     | Some (engine_id, scope) when scope = transition.scope ->
       (match Hashtbl.find_opt t.engines engine_id with
        | None -> Error (effect_error "The managed Engine is unavailable.")
        | Some engine ->
          (match
             Logseq_db_worker_engine.Engine.commit_outbox_transition
               engine
               ~expected:transition.expected_outbox_records
               transition.outbox_records
           with
           | Ok () ->
             Ok
               (sync_result
                  ~event:
                    (Sync.Outbox_transition_committed
                       { scope = transition.scope
                       ; outbox_records = transition.outbox_records
                       ; pending_message = transition.pending_message
                       })
                  ())
           | Error message ->
             let outbox_records =
               Logseq_db_worker_engine.Engine.managed_outbox_records engine
               |> Result.fold ~ok:Fun.id ~error:(fun _ ->
                 transition.expected_outbox_records)
             in
             Ok
               (sync_result
                  ~event:
                    (Sync.Outbox_transition_rejected
                       { scope = transition.scope; outbox_records; message })
                  ())))
     | Some _ | None -> Error (effect_error "The outbox graph scope is stale."))
;;

let graph_id_of_target = function
  | Logseq_db_worker_contract.Config.Snapshot { token } -> Some token
  | Synced_mirror { graph_id; _ } -> Some graph_id
  | Managed_sync _ | Import_snapshot _ | Native_local_graph _ -> None
;;

let run_request : type a. t -> Core.ticket -> a Core.runner_request -> unit =
  fun t ticket request ->
  match request with
  | Core.Open_engine config ->
    (match
       Logseq_db_worker_engine.Engine.open_ ~dependencies:t.dependencies.engine config
     with
     | Error error ->
       t.post (Core.Runner_completed (Core.Open_engine_completed (ticket, Error error)))
     | Ok engine ->
       let engine_id = Int64.to_string t.next_engine_id in
       t.next_engine_id <- Int64.succ t.next_engine_id;
       Hashtbl.replace t.engines engine_id engine;
       t.post
         (Core.Runner_completed
            (Core.Open_engine_completed
               ( ticket
               , Ok
                   (Core.engine_opened
                      ~engine_id
                      ~graph_id:(graph_id_of_target config.target)
                      ~basis:(Logseq_db_worker_engine.Engine.basis engine)) ))))
  | Core.Execute_request { engine; request } ->
    (match Hashtbl.find_opt t.engines (Core.engine_handle_id engine) with
     | None ->
       t.post
         (Core.Runner_completed
            (Core.Execute_request_completed
               (ticket, Error (effect_error "The Engine handle is unavailable."))))
     | Some engine ->
       let result =
         try Ok (Logseq_db_worker_engine.Engine.execute engine request) with
         | Logseq_db_worker_engine.Engine.Fatal_storage_error error -> Error error
       in
       t.post (Core.Runner_completed (Core.Execute_request_completed (ticket, result))))
  | Core.Prepare_managed_mutation { engine; scope; admission_id; request } ->
    let result = prepare_managed_mutation t ~engine ~scope ~admission_id request in
    t.post
      (Core.Runner_completed (Core.Prepare_managed_mutation_completed (ticket, result)))
  | Core.Handle_sync_worker_effect runner_effect ->
    let result = handle_sync_worker_effect t runner_effect in
    t.post (Core.Runner_completed (Core.Sync_worker_effect_completed (ticket, result)))
  | Core.Close_engine handle ->
    (match Hashtbl.find_opt t.engines (Core.engine_handle_id handle) with
     | None ->
       t.post (Core.Runner_completed (Core.Close_engine_completed (ticket, Ok ())))
     | Some engine ->
       let result =
         match Logseq_db_worker_engine.Engine.close engine with
         | Ok () ->
           Hashtbl.remove t.engines (Core.engine_handle_id handle);
           Ok ()
         | Error message -> Error (effect_error message)
       in
       t.post (Core.Runner_completed (Core.Close_engine_completed (ticket, result))))
;;

let publish t output =
  match output with
  | Core.Reply (id, response) ->
    let waiter =
      Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
        let key = Core.request_id_to_int64 id in
        let waiter = Hashtbl.find_opt t.waiters key in
        Hashtbl.remove t.waiters key;
        waiter)
    in
    Option.iter (fun waiter -> Eio.Promise.resolve waiter.resolve response) waiter
  | Graph_push _ | Sync_output _ | Graph_state_changed _ | Diagnostic _ ->
    t.dependencies.publish output
;;

let submit t instruction =
  if not t.stopped
  then (
    match instruction with
    | Core.Run_worker (Core.Request (ticket, request)) ->
      t.dependencies.runtime.fork ~sw:t.sw (fun () -> run_request t ticket request)
    | Run_sync runner_effect -> t.dependencies.sync_runner.submit runner_effect
    | Publish output -> publish t output)
;;

let await_reply t ~id ~request ~post =
  let promise, resolve = Eio.Promise.create () in
  Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
    let key = Core.request_id_to_int64 id in
    if Hashtbl.mem t.waiters key
    then invalid_arg "duplicate worker request ID"
    else Hashtbl.add t.waiters key { request; resolve });
  post ();
  Eio.Promise.await promise
;;

let shutdown t =
  if not t.stopped
  then (
    t.stopped <- true;
    t.dependencies.sync_runner.shutdown ();
    let waiters =
      Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
        let waiters = Hashtbl.to_seq_values t.waiters |> List.of_seq in
        Hashtbl.clear t.waiters;
        waiters)
    in
    List.iter
      (fun waiter ->
         let error = effect_error "The worker shut down before replying." in
         let response =
           Logseq_db_worker_contract.Protocol.failed
             ~request_id:waiter.request.request_id
             ~phase:Execute
             ~basis:None
             error
         in
         Eio.Promise.resolve waiter.resolve response)
      waiters;
    Hashtbl.iter
      (fun _ engine -> ignore (Logseq_db_worker_engine.Engine.close engine))
      t.engines;
    Hashtbl.clear t.engines;
    Hashtbl.clear t.prepared_mutations;
    t.attached <- None)
;;
