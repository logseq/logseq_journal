include Worker_pure_api

module type ISSUER = sig
  val binding : binding
  val revoke : unit -> unit
  val release_binding_request : unit -> (Service.request, error) result
  val binding_released : Service.response -> (unit, error) result

  val handoff_request
    :  handoff_plan
    -> (Service.request, error) result

  val handoff_receipt
    :  handoff_plan
    -> Service.response
    -> (handoff_receipt, error) result

  val consume_handoff_request : handoff_receipt -> (Service.request,error)result
  val handoff_consumed : handoff_receipt -> Service.response -> (unit,error)result
  val confirm_handoff_request : handoff_receipt -> (Service.request,error)result
  val handoff_confirmed : handoff_receipt -> Service.response -> (bool,error)result
  val bootstrap_request : unit -> (Service.request, error) result
  val bootstrap : Service.response -> (bootstrap_state, error) result

  val projection
    :  previous:projection option
    -> Service.push
    -> (projection, error) result

  val request
    :  session
    -> request_id:request_id
    -> 'a request
    -> (Service.request, error) result

  val acknowledge_mutation_request
    : session -> request_id:request_id -> presentation:presentation
    -> intent:durable_intent -> original:receipt option -> (Service.request,error) result

  val reply
    :  session
    -> request_id:request_id
    -> 'a request
    -> Service.response
    -> ('a reply, error) result

  val observation
    :  session
    -> request_id:request_id
    -> 'a observation
    -> Service.response
    -> ('a observed, error) result

  val observation_registration
    :  session
    -> request_id:request_id
    -> 'a observed request
    -> Service.response
    -> ('a observation * observation_epoch, error) result

  val changefeed_notices : Service.push -> (changefeed_notice Rrbvec.t, error) result
  val observation_notices : Service.push -> (observation_notice Rrbvec.t, error) result

  val finalize_observation_registration : session -> observation_id:request_id -> (Service.request,error)result
  val observation_registration_finalized : session -> observation_id:request_id -> Service.response -> (unit,error)result
  val finalize_asset_demand : session -> request_id:request_id -> asset_consumer -> (Service.request,error)result
  val asset_demand_finalized : session -> request_id:request_id -> asset_consumer -> Service.response -> (unit,error)result

  val release_observation_registration
    :  session
    -> observation_id:request_id
    -> (Service.request, error) result

  val observation_registration_released
    :  session
    -> observation_id:request_id
    -> Service.response
    -> (unit, error) result

  val asset_notice : session -> Service.asset_notice -> (asset_notice, error) result
end

let next_binding = Atomic.make 0
let predecessors : (int64 * int64, bool ref) Hashtbl.t = Hashtbl.create 4

let issuer ~managed_origin ~user_id ~runtime_epoch ~worker_generation =
  let origin = Uri.of_string managed_origin in
  if
    user_id = ""
    || Uri.host origin = None
    || (not (List.mem (Uri.scheme origin) [ Some "https"; Some "http" ]))
    || Uri.userinfo origin <> None
  then Error (Invalid_input "A verified account and managed origin are required")
  else (
    let key =
      ( Journal_worker_ids.Runtime.Epoch.to_int64 runtime_epoch
      , Journal_worker_ids.Worker.Generation.to_int64
          worker_generation )
    in
    Option.iter (fun revoked -> revoked := true) (Hashtbl.find_opt predecessors key);
    let serial = Atomic.fetch_and_add next_binding 1 in
    if serial = max_int then failwith "Worker binding counter exhausted";
    let revoked = ref false in
    Hashtbl.replace predecessors key revoked;
    let binding =
      (For_worker.binding ~serial:(Int64.of_int (serial + 1)) ~incarnation:(worker_incarnation ~runtime_epoch ~worker_generation) ~origin:(managed_origin) ~user:(user_id))
    in
    let latest = ref None
    and last_seen = ref None
    and last_bootstrap = ref Awaiting_baseline in
    let module I = struct
      let binding = binding
      let revoke () = revoked := true
      let release_binding_request () = Ok (Service.Release_coordination (For_worker.binding_serial binding))

      let binding_released = function
        | Service.Coordination_released id when id = (For_worker.binding_serial binding) ->
          if
            Option.fold
              ~none:false
              ~some:(fun other -> other == revoked)
              (Hashtbl.find_opt predecessors key)
          then Hashtbl.remove predecessors key;
          Ok ()
        | _ -> Error (Protocol_mismatch "Unexpected registration release ACK")
      ;;

      let handoff_request plan=
        if !revoked || not(equal_binding binding plan.plan_binding) then Error Revoked_session
        else Ok(Service.Coordination_prepare_host_change plan.plan_wire)
      let handoff_receipt plan=function
        |Service.Coordination_host_prepared actual when not !revoked
           && equal_binding binding plan.plan_binding->
          let receipt={host_plan=plan;host_receipt=actual} in
          if valid_handoff_receipt plan receipt then Ok receipt
          else Error(Protocol_mismatch "The physical handoff receipt does not match its immutable plan")
        |_->Error(Protocol_mismatch "Unexpected physical host handoff response")
      let consume_handoff_request receipt=
        if !revoked || not(equal_binding binding(handoff_binding receipt)) then Error Revoked_session
        else Ok(Service.Coordination_apply_host_change receipt.host_receipt)
      let handoff_consumed receipt=function
        |Service.Coordination_host_applied id when id=handoff_receipt_id receipt
           && equal_binding binding(handoff_binding receipt)->Ok()
        |_->Error(Protocol_mismatch "The host action did not acknowledge its exact consumed permission")

      let confirm_handoff_request receipt=
        if not(equal_binding binding(handoff_binding receipt)) then Error Revoked_session
        else Ok(Service.Coordination_confirm_host_change receipt.host_receipt)
      let handoff_confirmed receipt=function
        |Service.Coordination_host_confirmed(actual,consumed) when actual=receipt.host_receipt
          && equal_binding binding(handoff_binding receipt)->Ok consumed
        |_->Error(Protocol_mismatch "The readback did not match its original host permission")

      let bootstrap_request () =
        if !revoked
        then Error Revoked_session
        else Ok (Service.Register_coordination (For_worker.binding_serial binding))
      ;;

      let bootstrap response =
        match response with
        | Service.Coordination_registered b when b.registration = (For_worker.binding_serial binding) ->
          if !revoked
          then Ok (Binding_revoked Revoked_session)
          else if
            Option.fold
              ~none:false
              ~some:(fun version -> b.baseline.version < version)
              !last_seen
          then Ok !last_bootstrap
          else
            Result.bind (validate_baseline b) (fun () ->
              let result =
                match b.authority_user with
                | Some None ->
                  revoke ();
                  Ok (Binding_revoked Revoked_session)
                | Some (Some actual) when actual <> user_id ->
                  revoke ();
                  Ok (Binding_revoked Revoked_session)
                | _ ->
                  (match b.baseline.state.sync.account with
                   | None ->
                     if !latest = None
                     then
                       Ok (Bootstrap_not_ready "The local account has not been restored")
                     else (
                       revoke ();
                       Ok (Binding_revoked Revoked_session))
                   | Some account
                     when account.user_id <> user_id
                          || not (Uri.equal account.managed_sync_origin origin) ->
                     if !latest = None
                     then
                       Ok
                         (Bootstrap_not_ready "Waiting for the verified account baseline")
                     else (
                       revoke ();
                       Ok (Binding_revoked Revoked_session))
                   | Some account ->
                     let state = b.baseline.state in
                     if
                       List.length state.sync.desired_residents
                       <> List.length state.residents
                     then
                       Ok
                         (Bootstrap_not_ready "Waiting for resident lifecycle identities")
                     else if List.length state.residents > 3
                     then Error (Protocol_mismatch "Too many residents")
                     else if
                       b.limits.response_budget_bytes <= 0
                       || b.limits.response_budget_bytes > Worker_pure_data.maximum_response_bytes
                     then Error (Protocol_mismatch "Invalid baseline response limit")
                     else (
                       let residents =
                         List.map
                           (fun ( (scope : Service.asset_scope)
                                , (graph : Logseq_db_worker.graph_state) ) ->
                              let session =
                                (For_worker.session ~binding ~graph:(scope.graph_id) ~account:(scope.account.account_generation) ~lifecycle:(scope.account.lifecycle_generation) ~generation:(scope.graph_generation) ~limits:(b.limits) ~asset_scope:(scope) ~scope:({ startup =
                                        { account_generation =
                                            scope.account.account_generation
                                        ; presentation_generation =
                                            scope.account.presentation_generation
                                        }
                                    ; graph_id = scope.graph_id
                                    ; graph_generation = scope.graph_generation
                                    }))
                              in
                              let phase =
                                match graph.phase with
                                | Logseq_db_worker.Graph_open -> Open
                                | Graph_opening -> Opening
                                | Graph_closed | Graph_closing -> Closing
                                | Graph_failed ->
                                  Failed
                                    (Option.fold
                                       ~none:(Service_failed "Graph failed")
                                       ~some:(fun e -> Db_error e)
                                       graph.error)
                              in
                              let network =
                                match Service.coordination_network b scope with
                                | Some (Service.Offline | Paused) | None -> Offline
                                | Some (Connecting | Pulling | Submitting) -> Connecting
                                | Some Current -> Current
                                | Some Failed ->
                                  Network_failed
                                    (Service_failed "Network synchronization failed")
                              in
                              { session; phase; network })
                           state.residents
                       in
                       let selected =
                         Option.bind
                           state.sync.selected
                           (fun (owner : Service.timeline_scope) ->
                              List.find_map
                                (fun r ->
                                   if
                                     (graph_id r.session) = owner.graph_id
                                     && (For_worker.session_generation r.session) = owner.graph_generation
                                   then
                                     Some
                                       { session = r.session
                                       ; generation = b.baseline.presentation
                                       ; host_generation = owner.startup.presentation_generation
                                       }
                                   else None)
                                residents)
                       in
                       let deletion =
                         Option.map
                           (fun ((scope : Service.asset_scope), phase) ->
                              let stage = function
                                | Service.Closing_graph -> Closing_graph
                                | Deleting_mirror -> Deleting_local
                                | Clearing_selection -> Clearing_selection
                              in
                              match phase with
                              | Service.Deletion_in_progress s ->
                                Removing (scope.graph_id, Ordinary, stage s)
                              | Deletion_failed s ->
                                Removal_failed
                                  ( scope.graph_id
                                  , Ordinary
                                  , stage s
                                  , Service_failed "Local removal failed" ))
                           state.sync.deletion
                       in
                       let projection =
                         { binding
                         ; host_owner=account
                         ; account = account.account_generation
                         ; version = b.baseline.version
                         ; residents
                         ; selected
                         ; deletion
                         }
                       in
                       let projection =
                         match !latest with
                         | Some old when old.version > projection.version -> old
                         | _ -> projection
                       in
                       latest := Some projection;
                       ignore account;
                       Ok (Ready projection)))
              in
              Result.map
                (fun state ->
                   last_seen := Some b.baseline.version;
                   last_bootstrap := state;
                   state)
                result)
        | _ -> Error (Protocol_mismatch "Unexpected bootstrap response")
      ;;

      let projection ~previous:_ push =
        match push with
        | Service.Coordination_updates updates ->
          (match
             List.find_opt
               (function
                 | Service.Coordination_snapshot b -> b.registration = (For_worker.binding_serial binding)
                 | Coordination_revoked (id, _) -> id = (For_worker.binding_serial binding))
               updates
           with
           | Some (Coordination_snapshot b) ->
             Result.bind (bootstrap (Service.Coordination_registered b)) (function
               | Ready p -> Ok p
               | Binding_revoked e | Bootstrap_failed e -> Error e
               | _ -> Error (Service_failed "Baseline not ready"))
           | Some (Coordination_revoked _) ->
             revoke ();
             Error Revoked_session
           | None -> Error (Protocol_mismatch "Unowned baseline update"))
        | _ -> Error (Protocol_mismatch "Not a baseline update")
      ;;

      let live (session : session) =
        (not !revoked)
        && equal_binding (For_worker.session_binding session) binding
        && Option.fold
             ~none:false
             ~some:(fun p ->
               List.exists
                 (fun r -> r.phase = Open && equal_session r.session session)
                 p.residents)
             !latest
      ;;

      let presentation_live (presentation : presentation) =
        live presentation.session
        && Option.fold
             ~none:false
             ~some:(fun projection -> projection.selected = Some presentation)
             !latest
      ;;

      let finalize_observation_registration (session:session) ~observation_id =
        if not(equal_binding (For_worker.session_binding session) binding) then Error Revoked_session else
        Ok(Service.Coordination_finalize_observation{registration=(For_worker.binding_serial binding);owner=(For_worker.session_scope session);observation_id})
      ;;
      let observation_registration_finalized (session:session) ~observation_id = function
        |Service.Coordination_observation_finalized{registration;owner;observation_id=actual}
          when equal_binding (For_worker.session_binding session) binding && registration=(For_worker.binding_serial binding)
            && matches_scope session owner && equal_request_id actual observation_id->Ok()
        |_->Error(Protocol_mismatch "Observation finalization acknowledgement mismatch")
      ;;
      let finalize_asset_demand (session:session) ~request_id (consumer:asset_consumer) =
        if not(equal_binding (For_worker.session_binding session) binding) || not(equal_session consumer.session session) then Error Revoked_session
        else Result.map(fun consumer->Service.Coordination_finalize_asset_demand{
          registration=(For_worker.binding_serial binding);owner=(For_worker.session_asset_scope session);request_id;consumer})(asset_consumer_wire consumer)
      ;;
      let asset_demand_finalized (session:session) ~request_id (consumer:asset_consumer) response =
        match response,asset_consumer_wire consumer with
        |Service.Coordination_asset_demand_finalized{registration;owner;request_id=actual;consumer=wire},Ok expected
          when equal_binding (For_worker.session_binding session) binding && registration=(For_worker.binding_serial binding)
            && matches_asset_scope session owner && equal_request_id actual request_id && wire=expected->Ok()
        |_->Error(Protocol_mismatch "Asset finalization acknowledgement mismatch")
      ;;

      let release_observation_registration (session : session) ~observation_id =
        if not (equal_binding (For_worker.session_binding session) binding)
        then Error Revoked_session
        else
          Ok
            (Service.Coordination_release_observation
               { registration = (For_worker.binding_serial binding); owner = (For_worker.session_scope session); observation_id })
      ;;

      let observation_registration_released (session : session) ~observation_id = function
        | Service.Coordination_observation_released
            { registration; owner; observation_id = actual }
          when equal_binding (For_worker.session_binding session) binding
               && registration = (For_worker.binding_serial binding)
               && matches_scope session owner
               && equal_request_id actual observation_id -> Ok ()
        | _ -> Error (Protocol_mismatch "Observation cleanup acknowledgement mismatch")
      ;;

      let observation_registration
        : type a.
          session
          -> request_id:request_id
          -> a observed request
          -> Service.response
          -> (a observation * observation_epoch, error) result
        =
        fun session ~request_id operation response ->
        let handle =
          match operation with
          | Observe (budget, query) ->
            Result.map
              (fun () ->
                 { observation_owner = session
                 ; observation_key = request_id
                 ; observation_budget = budget
                 ; observation_query = query
                 })
              (validate_request session operation)
          | Refresh observation ->
            Result.map (fun () -> observation) (validate_request session operation)
          | _ -> .
        in
        Result.bind handle (fun observation ->
          match response with
          | Service.Coordination_observed
              { registration
              ; owner
              ; observation_id
              ; epoch
              ; request_id = actual_request
              ; answer = _
              }
            when equal_binding (For_worker.session_binding session) binding
                 && registration = (For_worker.binding_serial binding)
                 && matches_scope session owner
                 && equal_request_id observation_id observation.observation_key
                 && equal_request_id actual_request request_id
                 && epoch >= 0L -> Ok (observation, epoch)
          | _ ->
            Error
              (Protocol_mismatch "Observation registration/epoch/correlation mismatch"))
      ;;

      let observation : type a. session -> request_id:request_id -> a observation -> Service.response -> (a observed,error) result =
        fun session ~request_id observation response ->
        if not(live session) then Error Revoked_session else
        Result.bind(observation_registration session ~request_id (Refresh observation) response)(fun(actual,epoch)->(
          match same_observation observation actual,response with
          |Some Refl,Service.Coordination_observed{answer=Worker_pure_read.Query_answer(budget,query,result);_}->
            (match query_result_equality observation.observation_query query with
             |Some Refl when Worker_pure_read.equal_packed_query
               (For_worker.pack_query observation.observation_budget observation.observation_query)
               (For_worker.pack_query budget query)->
               Result.bind result(fun value->Result.map(fun()->{observation;epoch;value})
                 (Worker_pure_read.validate_value session observation.observation_budget observation.observation_query value))
             |_->Error(Protocol_mismatch "Observation value owner mismatch"))
          |_->Error(Protocol_mismatch "Observation value owner mismatch") : (a observed,error) result))
      ;;

      let observation_notices = function
        | Service.Coordination_observations values ->
          if Rrbvec.length values > 512
          then Error (Protocol_mismatch "Observation notice bound exceeded")
          else
            Rrbvec.fold_left
              (fun result signal ->
                 Result.bind result (fun notices ->
                   match signal with
                   | Service.Observations_resync ->
                     Ok (Rrbvec.push_back notices (Observations_resync binding))
                   | Observation_invalidated value
                     when value.registration_id <> (For_worker.binding_serial binding) -> Ok notices
                   | Observation_invalidated value
                     when value.epoch < 0L
                          || value.owner.startup.account_generation < 0
                          || value.owner.graph_generation < 0 ->
                     Error (Protocol_mismatch "Invalid observation notice identity/epoch")
                   | Observation_invalidated value ->
                     Ok
                       (Rrbvec.push_back
                          notices
                          (Observation_invalidated
                             { binding
                             ; owner = value.owner
                             ; id = request_id value.observation_id
                             ; epoch = value.epoch
                             }))))
              (Ok Rrbvec.empty)
              values
        | _ -> Error (Protocol_mismatch "Not an observation notice batch")
      ;;

      let changefeed_notices = function
        | Service.Graph_pushes notices ->
          if List.length notices > 128
          then Error (Protocol_mismatch "Scoped change notice bound exceeded")
          else if !revoked
          then Ok Rrbvec.empty
          else (
            let residents = Option.fold ~none:[] ~some:(fun p -> p.residents) !latest in
            List.fold_left
              (fun result ((scope : Service.asset_scope), push) ->
                 Result.bind result (fun notices ->
                   let owner =
                     List.find_opt
                       (fun resident ->
                          let session = resident.session in
                          resident.phase = Open
                          && (graph_id session) = scope.graph_id
                          && (For_worker.session_generation session) = scope.graph_generation
                          && (For_worker.session_account session) = scope.account.account_generation
                          && (For_worker.session_lifecycle session) = scope.account.lifecycle_generation
                          && (For_worker.binding_user binding) = scope.account.user_id
                          && Uri.equal
                               (Uri.of_string (For_worker.binding_origin binding))
                               scope.account.managed_sync_origin)
                       residents
                   in
                   match owner with
                   | None -> Ok notices
                   | Some resident ->
                     let version =
                       match push with
                       | Protocol.V2_changes_available value -> value.api_version
                       | V2_resync_required_push value -> value.api_version
                     in
                     if version <> Protocol.api_version
                     then
                       Error
                         (Protocol_mismatch "Scoped change notice API version mismatch")
                     else
                       Ok
                         (Rrbvec.push_back
                            notices
                            { notice_session = resident.session
                            ; notice = (match push with
                              | Protocol.V2_changes_available {generation;through;_}->Data.Changes_available {generation;through}
                              | V2_resync_required_push {generation;reason;_}->Data.Resync_required {generation;reason}) })))
              (Ok Rrbvec.empty)
              notices)
        | _ -> Ok Rrbvec.empty
      ;;

      let acknowledge_mutation_request session ~request_id ~(presentation:presentation) ~intent ~original =
        if not(live session && presentation_live presentation)
           || not(equal_session session presentation.session)
        then Error Revoked_session
        else Result.bind(validate_intent session intent)(fun()->
          let proof=match original with
            | None->Ok None
            | Some (receipt:receipt) when Bytes.to_string(encode_durable_intent receipt.intent)=Bytes.to_string(encode_durable_intent intent)->
              Result.map(fun()->Some(receipt_revisions receipt))(validate_confirmation session presentation receipt)
            | Some _->Error(Protocol_mismatch "Acknowledgement replaced the immutable intent") in
          Result.map(fun original->Service.Coordination_acknowledge_mutation
            {registration=(For_worker.binding_serial binding);owner=(For_worker.session_scope session);presentation=presentation.generation;
             request_id;intent=Bytes.to_string(encode_durable_intent intent);original})proof)
      ;;

      let request
        : type a.
          session -> request_id:request_id -> a request -> (Service.request, error) result
        =
        fun session ~request_id operation ->
        match operation with
        | Release_file lease->
          if not(equal_binding (For_worker.session_binding session) binding) || not(equal_session session lease.lease_owner)
          then Error Revoked_session else Ok(Service.Release_asset_file{scope=(For_worker.session_asset_scope session);handle=lease.lease_handle})
        | Release_asset_demand consumer->
          if not(equal_binding (For_worker.session_binding session) binding) then Error Revoked_session else
          Result.bind(validate_request session operation)(fun()->
            Result.map(fun consumer->Service.Coordination_release_asset_demand
              {registration=(For_worker.binding_serial binding);owner=(For_worker.session_asset_scope session);request_id;consumer})
              (asset_consumer_wire consumer))
        | Release observation ->
          Result.bind (validate_request session operation) (fun () ->
            release_observation_registration
              session
              ~observation_id:observation.observation_key)
        | _ ->
          if not (live session)
          then Error Revoked_session
          else (
            match operation with
            | Observe (budget, query) ->
              Result.map (fun()->Service.Coordination_observe
                {registration=For_worker.binding_serial binding;owner=For_worker.session_scope session;
                 observation_id=request_id;request_id;read=For_worker.pack_query budget query})
                (validate_request session operation)
            | Refresh observation ->
              Result.map
                (fun () ->
                   Service.Coordination_refresh_observation
                     { registration = (For_worker.binding_serial binding)
                     ; owner = (For_worker.session_scope session)
                     ; observation_id = observation.observation_key
                     ; request_id
                     })
                (validate_request session operation)
            | Query (budget,query)->
              Result.map(fun()->Service.Coordination_query{
                registration=For_worker.binding_serial binding;owner=For_worker.session_scope session;
                request_id;read=For_worker.pack_query budget query})(validate_request session operation)
            | Acknowledge_changes batch->
              Result.map(fun()->Service.Coordination_acknowledge_changes{
                registration=For_worker.binding_serial binding;owner=For_worker.session_scope session;
                request_id;batch})(validate_request session operation)
            | Confirm (presentation, receipt) ->
              if not (presentation_live presentation)
              then Error Revoked_session
              else
                Result.map
                  (fun () ->
                     Service.Coordination_confirm
                       { registration = (For_worker.binding_serial binding)
                       ; owner = (For_worker.session_scope session)
                       ; presentation = presentation.generation
                       ; request_id
                       ; intent = Bytes.to_string(encode_durable_intent receipt.intent)
                       ; original = receipt_revisions receipt
                       ; read = confirmation_read session receipt
                       })
                  (validate_confirmation session presentation receipt)
            | Mutate intent ->
              Result.map
                (fun () -> Service.Coordination_mutation
                  { registration=(For_worker.binding_serial binding);owner=(For_worker.session_scope session);request_id;
                    intent=Bytes.to_string(encode_durable_intent(Mutation_intent intent)) })
                (validate_intent session (Mutation_intent intent))
            | Append intent ->
              Result.map
                (fun () -> Service.Coordination_mutation
                  { registration=(For_worker.binding_serial binding);owner=(For_worker.session_scope session);request_id;
                    intent=Bytes.to_string(encode_durable_intent(Append_intent intent)) })
                (validate_request session operation)
            | Import intent->Result.map(fun()->Service.Coordination_import{registration=(For_worker.binding_serial binding);owner=(For_worker.session_asset_scope session);request_id;source=(Import_wire.source intent)})(validate_request session operation)
            | Acquire_asset_file file->Result.map(fun()->Service.Acquire_asset_file{scope=(For_worker.session_asset_scope session);handle=file.source_handle})(validate_request session operation)
            | Acquire_imported_file imported->Result.map(fun()->Service.Acquire_imported_file{scope=(For_worker.session_asset_scope session);operation=imported.import_receipt.operation})
                (validate_request session operation)
            | Replace_asset_demand(consumer,priority,assets)->
              Result.bind(validate_request session operation)(fun()->
              Result.map(fun consumer->Service.Coordination_asset_demand
                {registration=(For_worker.binding_serial binding);owner=(For_worker.session_scope session);request_id;consumer;
                 priority=(match priority with Foreground->Service.Asset.Foreground|Background->Background);
                 assets})(asset_consumer_wire(bind_asset_consumer consumer ~round:request_id)))
            | Retry_asset asset->Ok(Service.Asset_command_at((For_worker.session_scope session),Retry_asset asset))
            | Retry_upload upload->Result.map(fun()->Service.Asset_command_at((For_worker.session_scope session),Retry_upload upload.operation))
                (validate_request session operation)
            | Recover_import_inputs{after;maximum_items;maximum_bytes}->
              Result.map(fun()->Service.Coordination_recover_import_inputs
                {registration=(For_worker.binding_serial binding);owner=(For_worker.session_asset_scope session);request_id;
                 after=Option.map(fun cursor->cursor.input_after)after;maximum_items;maximum_bytes})
                (validate_import_recovery session ~after ~maximum_items ~maximum_bytes)
            | Confirm_import_source intent->
              Result.map(fun()->Service.Coordination_confirm_import_input{registration=(For_worker.binding_serial binding);owner=(For_worker.session_asset_scope session);
                request_id;input=Import_wire.encode intent})(validate_request session operation)
            | Acknowledge_import_source proof->
              Result.map(fun()->Service.Coordination_acknowledge_import_input{registration=(For_worker.binding_serial binding);owner=(For_worker.session_asset_scope session);
                request_id;input=Import_wire.encode proof.prepared_intent;prepared=proof.original_prepared})(validate_request session operation)
            | Recover_mutations {after;maximum_items;maximum_bytes}->
              Result.map(fun()->Service.Coordination_recover_mutations
                {registration=(For_worker.binding_serial binding);owner=(For_worker.session_scope session);request_id;
                 after=Option.map(fun cursor->cursor.after)after;maximum_items;maximum_bytes})
                (validate_recovery session ~after ~maximum_items ~maximum_bytes)
            | _ -> unavailable "This operation's resource/durability")
      ;;

      let reply
        : type a.
          session
          -> request_id:request_id
          -> a request
          -> Service.response
          -> (a reply, error) result
        =
        fun session ~request_id operation response ->
        match operation with
        | Release_file lease->
          if not(equal_binding (For_worker.session_binding session) binding) || not(equal_session session lease.lease_owner) then Error Revoked_session else
          (match response with Service.Client_command_completed->Ok(Answered(Ok()))
           | _->Error(Protocol_mismatch "File release did not acknowledge actual checked release"))
        | Recover_import_inputs{after;maximum_items;maximum_bytes}->
          if not(equal_binding (For_worker.session_binding session) binding) then Error Revoked_session else
          (match response with Service.Coordination_import_inputs_recovered{registration;owner;request_id=actual;page}
             when registration=(For_worker.binding_serial binding) && actual=request_id && matches_asset_scope session owner->
             decode_import_recovery session ~after ~maximum_items ~maximum_bytes page |> Result.map(fun value->Answered(Ok value))
           |_->Error(Protocol_mismatch "Import input recovery owner or request changed"))
        | Confirm_import_source intent->
          if not(equal_binding (For_worker.session_binding session) binding) || Result.is_error(validate_request session operation) then Error Revoked_session else
          (match response with Service.Coordination_import_input_confirmed{registration;owner;request_id=actual;input}
             when registration=(For_worker.binding_serial binding) && actual=request_id && matches_asset_scope session owner->
             (match input with None->Ok(Answered(Ok None))|Some row when row.Logseq_db_types.Asset_import.Recovery.input=Import_wire.encode intent->
               decode_import_source session row |> Result.map(fun value->Answered(Ok(Some value)))
              |Some _->Error(Protocol_mismatch "Source confirmation replaced the complete original input"))
           |_->Error(Protocol_mismatch "Import source confirmation owner or request changed"))
        | Acknowledge_import_source _->
          if not(equal_binding (For_worker.session_binding session) binding) || Result.is_error(validate_request session operation) then Error Revoked_session else
          (match response with Service.Coordination_import_input_acknowledged{registration;owner;request_id=actual}
             when registration=(For_worker.binding_serial binding) && actual=request_id && matches_asset_scope session owner->Ok(Answered(Ok()))
           |_->Error(Protocol_mismatch "Import source ACK did not match its original owner and request"))
        | Import intent->
          if not(equal_binding (For_worker.session_binding session) binding)
            || Result.is_error(restore_asset_import_intent session(encode_asset_import_intent intent))
          then Error Revoked_session else
          (match response with
           | Service.Coordination_imported{registration;owner;request_id=actual;result=Error message}
             when registration=(For_worker.binding_serial binding) && actual=request_id && matches_asset_scope session owner->Ok(Answered(Error(Service_failed message)))
           | Service.Coordination_imported{registration;owner;request_id=actual;result=Ok receipt}
             when registration=(For_worker.binding_serial binding) && actual=request_id && matches_asset_scope session owner && matches_asset_scope session receipt.scope
               && receipt.graph_generation=(For_worker.session_generation session) && receipt.operation=(Import_wire.source intent).operation
               && receipt.target=(Import_wire.source intent).target && receipt.asset.uuid=(Import_wire.source intent).asset
               && receipt.file_type=(Import_wire.source intent).file_type && receipt.asset.current_checksum<>None->
             let preview=Option.map(fun(handle,path)->{lease_owner=session;lease_id=request_id;lease_handle=handle;lease_path=path;lease_type=receipt.file_type})receipt.preview in
             if Option.exists(fun lease->lease.lease_handle="" || lease.lease_path="")preview
             then Error(Protocol_mismatch "Imported preview omitted its acquired file capability") else
             Ok(Answered(Ok(Imported{import_owner=session;import_receipt=receipt;import_preview=preview;
               source_proof={source_operation=(Import_wire.source intent).operation;
                 source_fingerprint=(Digestif.SHA256.digest_string (Import_wire.encode intent) |> Digestif.SHA256.to_hex)}})))
           | _->Error(Protocol_mismatch "Import receipt changed its exact owner or immutable identity"))
        | Acquire_asset_file file->
          if not(equal_binding (For_worker.session_binding session) binding) || not(equal_session session file.asset_owner) then Error Revoked_session else
          (match response with
           | Service.Asset_file None->Ok(Answered(Ok None))
           | Service.Asset_file(Some(handle,path)) when handle<>"" && path<>""->
             let file_type=match file.descriptor.source with
               |Managed(Some version)->version.file_type
               |Managed None|External _->Filename.extension path |> fun extension->
                 if extension="" then "bin" else String.sub extension 1(String.length extension-1) in
             Ok(Answered(Ok(Some{lease_owner=session;lease_id=request_id;lease_handle=handle;lease_path=path;lease_type=file_type})))
           | _->Error(Protocol_mismatch "Asset acquisition omitted its actual lease capability"))
        | Acquire_imported_file imported->
          if not(equal_binding (For_worker.session_binding session) binding) || not(equal_session session imported.import_owner) then Error Revoked_session else
          (match response with
           | Service.Asset_file None->Ok(Answered(Ok None))
           | Service.Asset_file(Some(handle,path)) when handle<>"" && path<>""->
             Ok(Answered(Ok(Some{lease_owner=session;lease_id=request_id;lease_handle=handle;lease_path=path;lease_type=imported.import_receipt.file_type})))
           | _->Error(Protocol_mismatch "Imported acquire omitted its actual lease capability"))
        | Release_asset_demand consumer->
          if not(equal_binding (For_worker.session_binding session) binding)
             || not(equal_asset_consumer consumer {consumer with session}) then Error Revoked_session else
          (match response,asset_consumer_wire consumer with
           | Service.Coordination_asset_demand_released value,Ok expected
             when value.registration=(For_worker.binding_serial binding) && value.request_id=request_id
               && value.consumer=expected && matches_asset_scope session value.owner->Ok(Answered(Ok()))
           | _->Error(Protocol_mismatch "Asset cleanup did not acknowledge actual scoped settlement"))
        | Release observation ->
          observation_registration_released
            session
            ~observation_id:observation.observation_key
            response
          |> Result.map (fun () -> Answered (Ok ()))
        | _ ->
          if not (live session)
          then Error Revoked_session
          else (
            match operation, response with
            | Observe _, _ ->
              Result.map
                (fun (handle, _) ->
                   Answered (observation session ~request_id handle response))
                (observation_registration session ~request_id operation response)
            | Refresh _, _ ->
              Result.map
                (fun (handle, _) ->
                   Answered (observation session ~request_id handle response))
                (observation_registration session ~request_id operation response)
            | Replace_asset_demand _,Service.Coordination_asset_demand_accepted value
              when value.request_id=request_id->Ok(Answered(Ok()))
            | Retry_asset _,Service.Client_command_completed->Ok(Answered(Ok()))
            | Retry_upload _,Service.Client_command_completed->Ok(Answered(Ok()))
            | Query(budget,query),Service.Coordination_queried value
              when value.registration=For_worker.binding_serial binding
                && value.owner=For_worker.session_scope session && value.request_id=request_id ->
              let Worker_pure_read.Query_answer(source_budget,source_query,result)=value.answer in
              (match Worker_pure_read.query_result_equality query source_query with
               |None->Error(Protocol_mismatch "The typed answer belongs to another query")
               |Some Worker_pure_read.Refl->
                 if not(Worker_pure_read.equal_packed_query (For_worker.pack_query budget query)
                   (For_worker.pack_query source_budget source_query))
                 then Error(Protocol_mismatch "The typed answer belongs to another execution")
                 else Ok(Answered(Result.bind result(fun result->
                   Result.map(fun()->result)(Worker_pure_read.validate_value session budget query result)))))
            | Acknowledge_changes batch,Service.Coordination_changes_acknowledged value
              when value.registration=For_worker.binding_serial binding
                && value.owner=For_worker.session_scope session && value.request_id=request_id ->
              let result=Result.bind value.result(fun ack->
                if equal_session session (change_ack_session ack)
                  && change_ack_generation ack=batch.generation && change_ack_through ack=batch.through
                then Ok ack else Error(Protocol_mismatch "Changefeed ACK owner/generation/window mismatch")) in
              Ok(Answered result)
            |Confirm(presentation,receipt),Service.Coordination_confirmed value
              when value.registration=For_worker.binding_serial binding && value.owner=For_worker.session_scope session
                && value.presentation=presentation.generation && value.request_id=request_id->
              if not(presentation_live presentation)then Error Revoked_session else
              decode_confirmation session ~presentation receipt value.answer
              |> Result.map(fun confirmation->Answered(Ok(Confirmed confirmation)))
            | (Recover_mutations {after;maximum_items;maximum_bytes},
               Service.Coordination_mutations_recovered{request_id=actual;page})
              when Uuid.equal actual request_id->
              decode_recovery session ~request_id ~after ~maximum_items ~maximum_bytes page
              |> Result.map(fun page->Answered(Ok page))
            | Acknowledge_intent _,Service.Coordination_mutation_acknowledged{request_id=actual}
              when Uuid.equal actual request_id->Ok(Answered(Ok()))
            | ( Mutate intent
              , Service.Coordination_mutation_result { request_id = actual; outcome } )
              when Uuid.equal request_id actual ->
              decode_mutation_progress session ~request_id ~intent:(Mutation_intent intent) outcome
              |> Result.map(fun progress->Answered(Ok progress))
            | ( Append intent
              , Service.Coordination_mutation_result { request_id = actual; outcome } )
              when Uuid.equal request_id actual ->
              decode_mutation_progress session ~request_id ~intent:(Append_intent intent) outcome
              |> Result.map(fun progress->Answered(Ok progress))
            | _ -> Error (Protocol_mismatch "Unexpected owned query receipt"))
      ;;

      let asset_notice session data =
        if not(live session) then Error Revoked_session else
        let consumer wire make=Result.map(fun consumer->
          {notice_owner=session;notice_consumer=Some consumer;notice_data=make consumer.name})
          (decode_asset_consumer session wire) in
        match data with
        | Service.Asset_availability value->consumer value.consumer(fun name->
            Service.Asset_availability{value with consumer=name})
        | Asset_demand_accepted wire->consumer wire(fun name->Service.Asset_demand_accepted name)
        | Asset_backpressure wire->consumer wire(fun name->Service.Asset_backpressure name)
        | Asset_capacity_available|Upload_status _->
          Ok{notice_owner=session;notice_consumer=None;notice_data=data}
    end
    in
    Ok (module I : ISSUER))
;;
