module Worker = Worker_api
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Mailbox = Logseq_db_worker_lui.Journal_worker
module Id = Logseq_db_worker_lui.Journal_worker_ids
module Core = Worker_pure_coordinator

type client = (Service.request, Service.response, Service.push) Mailbox.client

type flight =
  | Baseline of (module Worker.ISSUER)
  | Query :
      (module Worker.ISSUER) * 'a Core.ticket * Worker.session * 'a Worker.request
      -> flight
  | Unobserve of (module Worker.ISSUER) * Worker.session * Worker.request_id
  | Finalize_observation of (module Worker.ISSUER) * Worker.session * Worker.request_id
  | Finalize_demand of (module Worker.ISSUER) * unit Core.ticket * Worker.session * Worker.asset_consumer
  | Unregister of (module Worker.ISSUER)
  | Handoff of (module Worker.ISSUER) * Worker.handoff_plan
  | Consume of (module Worker.ISSUER) * Worker.handoff_receipt * Worker.request_id
  | Confirm of (module Worker.ISSUER) * Worker.handoff_receipt * Worker.request_id

type t =
  { client : client
  ; origin : string
  ; user : string
  ; post : Core.event -> unit
  ; publish : Core.view -> unit
  ; mutable issuer : (module Worker.ISSUER)
  ; mutable registration : int64 option
  ; pending : (Id.Worker.request_id, flight) Hashtbl.t
  ; mutable latest : Core.view option
  ; mutable shutdown_posted : bool
  }

let create ~client ~managed_origin ~user_id ~post ~publish =
  Worker.issuer
    ~managed_origin
    ~user_id
    ~runtime_epoch:(Mailbox.runtime_epoch client)
    ~worker_generation:(Mailbox.worker_generation client)
  |> Result.map (fun issuer ->
    let module I = (val issuer : Worker.ISSUER) in
    let t =
      { client
      ; origin = managed_origin
      ; user = user_id
      ; post
      ; publish
      ; issuer
      ; registration = None
      ; pending = Hashtbl.create 32
      ; latest = None
      ; shutdown_posted = false
      }
    in
    post (Core.Worker_bound I.binding);
    t)
;;

type disposition =
  | Consumed
  | Unowned_response
  | Broadcast
  | Dropped_envelope

type delivery =
  { disposition : disposition
  ; error : Worker.error option
  }

let admit t request flight =
  match Mailbox.send t.client request with
  |Mailbox.Accepted id as result->Hashtbl.add t.pending id flight;result
  |result->result
;;

let refused = function
  | Mailbox.Full -> Worker.Full
  | Not_ready -> Not_ready
  | Stopping -> Stopping
  | Accepted _ -> assert false
;;

let submit t = function
  | Core.Bootstrap ->
    let module I = (val t.issuer : Worker.ISSUER) in
    (match I.bootstrap_request () with
     | Error e -> t.post (Core.Bootstrap_received (I.binding, Worker.Bootstrap_failed e))
     | Ok request ->
       (match request with
        | Service.Register_coordination id -> t.registration <- Some id
        | _ -> ());
       (match admit t request (Baseline t.issuer) with
        | Accepted id -> t.post (Core.Bootstrap_admitted (I.binding, id))
        | result -> t.post (Core.Bootstrap_not_admitted (I.binding, refused result))))
  | Release_observation_registration (session, id) ->
    let module I = (val t.issuer : Worker.ISSUER) in
    (match I.release_observation_registration session ~observation_id:id with
     | Error error ->
       t.post (Core.Observation_release_completed (session, id, Error error))
     | Ok request ->
       (match admit t request (Unobserve (t.issuer, session, id)) with
        | Mailbox.Accepted _ -> ()
        | result ->
          t.post (Core.Observation_release_not_admitted (session, id, refused result))))
  | Finalize_observation_registration(session,id)->
    let module I=(val t.issuer:Worker.ISSUER) in
    (match I.finalize_observation_registration session ~observation_id:id with
     |Error error->t.post(Core.Observation_finalize_completed(session,id,Error error))
     |Ok request->match admit t request(Finalize_observation(t.issuer,session,id)) with
       |Accepted _->()
       |result->t.post(Core.Observation_finalize_not_admitted(session,id,refused result)))
  | Finalize_asset_demand(ticket,session,consumer)->
    let module I=(val t.issuer:Worker.ISSUER) in
    (match I.finalize_asset_demand session ~request_id:(Core.ticket_id ticket) consumer with
     |Error error->t.post(Core.Admission_failed(ticket,error))
     |Ok request->match admit t request(Finalize_demand(t.issuer,ticket,session,consumer)) with
       |Accepted id->t.post(Core.Admitted(ticket,id))
       |result->t.post(Core.Admission_refused(ticket,refused result)))
  | Release_binding binding ->
    let module I = (val t.issuer : Worker.ISSUER) in
    if not (Worker.equal_binding binding I.binding)
    then t.post (Core.Binding_release_completed (binding, Error Worker.Revoked_session))
    else (
      I.revoke ();
      match I.release_binding_request () with
      | Error e -> t.post (Core.Binding_release_completed (binding, Error e))
      | Ok request ->
        (match admit t request (Unregister t.issuer) with
         | Accepted _ -> ()
         | result -> t.post (Core.Binding_release_not_admitted (binding, refused result))))
  | Bind_replacement ->
    (match
       Worker.issuer
         ~managed_origin:t.origin
         ~user_id:t.user
         ~runtime_epoch:(Mailbox.runtime_epoch t.client)
         ~worker_generation:(Mailbox.worker_generation t.client)
     with
     | Error e ->
       let module I = (val t.issuer : Worker.ISSUER) in
       t.post (Core.Bootstrap_received (I.binding, Worker.Bootstrap_failed e))
     | Ok issuer ->
       t.issuer <- issuer;
       t.registration <- None;
       let module I = (val issuer : Worker.ISSUER) in
       t.post (Core.Worker_bound I.binding))
  | Send (ticket, session, operation) ->
    let module I = (val t.issuer : Worker.ISSUER) in
    let request=match operation with
      | Worker.Acknowledge_intent intent->
        (match Core.ticket_acknowledgement ticket with
         | Some(presentation,original)->I.acknowledge_mutation_request session
             ~request_id:(Core.ticket_id ticket) ~presentation ~intent ~original
         | None->Error(Worker.Invalid_input "The pure acknowledgement decision is missing"))
      | _->I.request session ~request_id:(Core.ticket_id ticket) operation in
    (match request with
     | Error e -> t.post (Core.Admission_failed (ticket, e))
     | Ok request ->
       (match admit t request (Query (t.issuer, ticket, session, operation)) with
        | Accepted id -> t.post (Core.Admitted (ticket, id))
        | result -> t.post (Core.Admission_refused (ticket, refused result))))
  | Cancel_request ticket ->
    Hashtbl.iter
      (fun id -> function
         | Query (_, actual, _, _)
           when Worker.equal_request_id (Core.ticket_id ticket) (Core.ticket_id actual) ->
           Mailbox.cancel t.client ~request_id:id
         | _ -> ())
      t.pending
  |Quiesce plan->
    let module I=(val t.issuer:Worker.ISSUER) in
    let id=Worker.handoff_plan_id plan and change=Worker.handoff_plan_change plan in
    let fail error=t.post(Core.Handoff_completed(id,Worker.Handoff_failed(change,error))) in
    (match I.handoff_request plan with
     |Error error->fail error
     |Ok request->match admit t request(Handoff(t.issuer,plan))with
       |Accepted _->()
       |Full->fail(Worker.Service_failed "Host preparation was not admitted: queue full")
       |Not_ready|Stopping->fail(Worker.Service_failed "Host preparation was not admitted: Worker unavailable"))
  |Consume_handoff(receipt,attempt)->
    let module I=(val t.issuer:Worker.ISSUER) in
    let id=Worker.handoff_receipt_id receipt in
    (match I.consume_handoff_request receipt with
     |Error error->t.post(Core.Handoff_apply_rejected(id,attempt,error))
     |Ok request->match admit t request(Consume(t.issuer,receipt,attempt))with
       |Accepted mailbox->t.post(Core.Handoff_apply_admitted(id,attempt,mailbox))
       |result->t.post(Core.Handoff_apply_not_admitted(id,attempt,refused result)))
  |Confirm_handoff(receipt,attempt)->
    let module I=(val t.issuer:Worker.ISSUER) in
    let id=Worker.handoff_receipt_id receipt in
    (match I.confirm_handoff_request receipt with
     |Error error->t.post(Core.Handoff_confirmed(id,attempt,None,Error error))
     |Ok request->match admit t request(Confirm(t.issuer,receipt,attempt))with
       |Accepted mailbox->t.post(Core.Handoff_confirm_admitted(id,attempt,mailbox))
       |result->t.post(Core.Handoff_confirm_not_admitted(id,attempt,refused result)))
  | Publish view ->
    t.latest <- Some view;
    t.publish view
  | Schedule_drain -> t.post Core.Drain
;;

let on_event t event =
  let runtime, worker =
    match event with
    | Mailbox.Response { runtime_epoch; worker_generation; _ }
    | Push { runtime_epoch; worker_generation; _ }
    | Terminal { runtime_epoch; worker_generation; _ } -> runtime_epoch, worker_generation
  in
  if
    (not (Id.Runtime.Epoch.equal runtime (Mailbox.runtime_epoch t.client)))
    || not (Id.Worker.Generation.equal worker (Mailbox.worker_generation t.client))
  then { disposition = Dropped_envelope; error = None }
  else (
    let error = ref None in
    let disposition =
      match event with
      | Mailbox.Response { request_id; outcome; _ } ->
        (match Hashtbl.find_opt t.pending request_id with
         | None -> Unowned_response
         | Some flight ->
           Hashtbl.remove t.pending request_id;
           (match flight with
            | Baseline issuer ->
              let module I = (val issuer : Worker.ISSUER) in
              let state =
                match outcome with
                | Completed response ->
                  (match I.bootstrap response with
                   | Ok state -> state
                   | Error e ->
                     error := Some e;
                     Worker.Bootstrap_failed e)
                | Failed message ->
                  Worker.Bootstrap_failed (Worker.Service_failed message)
                | Cancelled | Shutdown ->
                  Worker.Bootstrap_failed
                    (Worker.Service_failed "Registration interrupted; ownership retained")
              in
              t.post (Core.Bootstrap_received (I.binding, state))
            | Query (issuer, ticket, session, request) ->
              let module I = (val issuer : Worker.ISSUER) in
              let result =
                match outcome with
                | Completed response ->
                  (match request with
                   | Worker.Observe _ ->
                     (match
                        I.observation_registration
                          session
                          ~request_id:(Core.ticket_id ticket)
                          request
                          response
                      with
                      | Ok (handle, epoch) ->
                        t.post (Core.Observation_registered (ticket, handle, epoch))
                      | Error _ -> ())
                   | Worker.Refresh _ ->
                     (match
                        I.observation_registration
                          session
                          ~request_id:(Core.ticket_id ticket)
                          request
                          response
                      with
                      | Ok (handle, epoch) ->
                        t.post (Core.Observation_registered (ticket, handle, epoch))
                      | Error _ -> ())
                   | _ -> ());
                  (match
                     I.reply session ~request_id:(Core.ticket_id ticket) request response
                   with
                   | Ok result -> result
                   | Error e ->
                     error := Some e;
                     Worker.Answered (Error e))
                | Failed message ->
                  (match request with
                   | Worker.Import _ -> Worker.Interrupted Worker.Transport_lost
                   | _ -> Worker.Answered (Error (Worker.Service_failed message)))
                | Cancelled -> Worker.Interrupted Worker.Cancelled
                | Shutdown -> Worker.Interrupted Worker.Worker_stopped
              in
              t.post (Core.Completed (ticket, result))
            | Unobserve (issuer, session, id) ->
              let module I = (val issuer : Worker.ISSUER) in
              let result =
                match outcome with
                | Completed response ->
                  I.observation_registration_released session ~observation_id:id response
                | _ ->
                  Error
                    (Worker.Service_failed
                       "Observation release did not acknowledge physical retirement")
              in
              t.post (Core.Observation_release_completed (session, id, result))
            |Finalize_observation(issuer,session,id)->
              let module I=(val issuer:Worker.ISSUER) in
              let result=match outcome with Completed response->I.observation_registration_finalized session ~observation_id:id response
                |_->Error(Worker.Service_failed "Observation finalization was not acknowledged") in
              t.post(Core.Observation_finalize_completed(session,id,result))
            |Finalize_demand(issuer,ticket,session,consumer)->
              let module I=(val issuer:Worker.ISSUER) in
              let result=match outcome with
                |Completed response->Worker.Answered(I.asset_demand_finalized session ~request_id:(Core.ticket_id ticket) consumer response)
                |Failed message->Worker.Answered(Error(Worker.Service_failed message))
                |Cancelled->Worker.Interrupted Worker.Cancelled|Shutdown->Worker.Interrupted Worker.Worker_stopped in
              t.post(Core.Completed(ticket,result))
            |Consume(issuer,receipt,attempt)->
              let module I=(val issuer:Worker.ISSUER) in
              let result=match outcome with
                |Completed response->I.handoff_consumed receipt response
                |Failed message->Error(Worker.Service_failed message)
                |Cancelled|Shutdown->Error(Worker.Service_failed "Host action outcome is unknown; original permission cannot be replayed") in
              t.post(Core.Handoff_applied(Worker.handoff_receipt_id receipt,attempt,request_id,result))
            |Confirm(issuer,receipt,attempt)->
              let module I=(val issuer:Worker.ISSUER) in
              let result=match outcome with Completed response->I.handoff_confirmed receipt response
                |Failed message->Error(Worker.Service_failed message)
                |Cancelled|Shutdown->Error(Worker.Service_failed "Original host consumption readback is unavailable; outcome remains unknown") in
              t.post(Core.Handoff_confirmed(Worker.handoff_receipt_id receipt,attempt,Some request_id,result))
            |Handoff(issuer,plan)->
              let module I=(val issuer:Worker.ISSUER) in
              let id=Worker.handoff_plan_id plan and change=Worker.handoff_plan_change plan in
              let result=match outcome with
                |Completed response->I.handoff_receipt plan response
                |Failed message->Error(Worker.Service_failed message)
                |Cancelled|Shutdown->Error(Worker.Service_failed "Host preparation was interrupted; cleanup ownership retained") in
              t.post(Core.Handoff_completed(id,match result with
                |Ok receipt->Worker.Safe_to_proceed receipt|Error error->Worker.Handoff_failed(change,error)))
            | Unregister issuer ->
              let module I = (val issuer : Worker.ISSUER) in
              let result =
                match outcome with
                | Completed response -> I.binding_released response
                | _ ->
                  Error
                    (Worker.Service_failed
                       "Unregister did not acknowledge resource retirement")
              in
              t.post (Core.Binding_release_completed (I.binding, result)));
           Consumed)
      | Push { payload = Service.Graph_pushes _ as payload; push_sequence; _ } ->
        let module I = (val t.issuer : Worker.ISSUER) in
        (match I.changefeed_notices payload with
         | Ok notices ->
           Rrbvec.iter
             (fun notice -> t.post (Core.Changefeed_notice (notice, push_sequence)))
             notices
         | Error e -> error := Some e);
        Broadcast
      | Push { payload = Service.Coordination_updates updates; _ } ->
        let module I = (val t.issuer : Worker.ISSUER) in
        List.iter
          (function
            | Service.Coordination_snapshot b when t.registration = Some b.registration ->
              (match I.bootstrap (Service.Coordination_registered b) with
               | Ok state -> t.post (Core.Bootstrap_received (I.binding, state))
               | Error e ->
                 error := Some e;
                 t.post (Core.Bootstrap_received (I.binding, Worker.Bootstrap_failed e)))
            | Coordination_revoked (id, _) when t.registration = Some id ->
              I.revoke ();
              t.post (Core.Binding_invalidated I.binding)
            | _ -> ())
          updates;
        Broadcast
      | Push { payload = Service.Coordination_observations _ as payload; _ } ->
        let module I = (val t.issuer : Worker.ISSUER) in
        (match I.observation_notices payload with
         | Ok notices ->
           Rrbvec.iter (fun notice -> t.post (Core.Observation_notice notice)) notices
         | Error e ->
           error := Some e;
           t.post (Core.Observation_notices_failed (I.binding, e)));
        Broadcast
      | Push {payload=(Service.Asset_notice _|Asset_notices _) as payload;push_sequence;_}->
        let module I=(val t.issuer:Worker.ISSUER) in
        Option.iter(fun view->Option.iter(fun projection->
          List.iter(fun(scope,data)->
            match List.find_opt(fun resident->resident.Worker.phase=Worker.Open
              && Worker.matches_asset_scope resident.session scope)(Worker.residents projection) with
            | None->()
            | Some resident->(match I.asset_notice resident.session data with
              | Ok notice->t.post(Core.Asset_received(notice,push_sequence))
              | Error _->()))(Service.asset_notices payload))
          (Core.projection view))t.latest;
        Broadcast
      | Push _ -> Broadcast
      | Terminal { error = message; _ } ->
        let module I = (val t.issuer : Worker.ISSUER) in
        I.revoke ();
        t.post
          (Core.Bootstrap_received
             (I.binding, Worker.Binding_revoked (Worker.Service_failed message)));
        t.post
          (Core.Binding_release_completed
             (I.binding, Error (Worker.Service_failed message)));
        Broadcast
    in
    t.post Core.Capacity_available;
    { disposition; error = !error })
;;

let authorize_host_change t receipt ~attempt =
  let module I=(val t.issuer:Worker.ISSUER) in
  Result.bind(I.consume_handoff_request receipt)(fun request->
    match admit t request(Consume(t.issuer,receipt,attempt))with
    |Accepted id->Ok id
    |_->Error(Worker.Service_failed "Host action was not admitted; no consumption ACK"))
;;

type shutdown_state =
  | Draining
  | Stopped
  | Shutdown_failed of Worker.error

let shutdown t =
  if not t.shutdown_posted
  then (
    t.shutdown_posted <- true;
    t.post Core.Shutdown_requested)
  else (
    match Option.map Core.shutdown_state t.latest with
    | Some (Core.Shutdown_failed _) -> t.post Core.Shutdown_requested
    | _ -> ());
  match Option.map Core.shutdown_state t.latest with
  | Some Core.Stopped -> Stopped
  | Some (Core.Shutdown_failed e) -> Shutdown_failed e
  | _ -> Draining
;;
