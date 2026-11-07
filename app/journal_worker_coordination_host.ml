module Worker = Journal_worker_coordination.Worker_api
module Core = Journal_worker_coordination.Worker_pure_coordinator
module Runner = Journal_worker_coordination.Worker_effect_runner

let error_message = function
  | Worker.Db_error error -> Logseq_db_worker.Error.message error
  | Invalid_input message | Service_failed message | Unsupported_operation message
  | Protocol_mismatch message | Stale_read message | Resync_required message -> message
  | Revoked_session -> "The graph session changed."
  | Host_change_in_progress -> "The graph is closing. The outcome is retained."
  | Response_budget_exceeded -> "The result exceeded its response budget."
;;

let diagnostic_error error =
  let module E=Logseq_db_worker.Error in
  match error with
  | Worker.Db_error error -> error
  | _ ->
    let code,category=match error with
      | Worker.Revoked_session->E.Closed_session,"revokedSession"
      | Host_change_in_progress->E.Closed_session,"hostChangeInProgress"
      | Response_budget_exceeded->E.Response_too_large,"responseBudgetExceeded"
      | Invalid_input _->E.Invalid_request,"invalidInput"
      | Protocol_mismatch _->E.Invalid_request,"protocolMismatch"
      | Unsupported_operation _->E.Unsupported_semantics,"unsupportedOperation"
      | Stale_read _->E.Stale_read_cursor,"staleRead"
      | Resync_required _->E.Stale_read_cursor,"resyncRequired"
      | Service_failed _->E.Closed_session,"serviceFailed"
      | Db_error _->assert false in
    let origin=E.create_cause_or_fallback ~component:E.Worker_service
      ~operation:"coordination" ~code:(Some category) ~message:(error_message error)
      ~fallback_message:"The Worker reported an unsafe or oversized failure description." in
    E.create_with_origin ~code ~message:origin.message ~origin ~details:[] |> Result.get_ok
;;

let admission_error = function
  | Worker.Full -> Worker.Service_failed "Worker request queue is full"
  | Not_ready -> Worker.Service_failed "Worker is not ready"
  | Stopping -> Worker.Service_failed "Worker is stopping"
  | Unsupported_request message -> Worker.Unsupported_operation message
;;

let admission_diagnostic reason =
  let module E=Logseq_db_worker.Error in
  let error=diagnostic_error(admission_error reason) in
  let code,category=match reason with
    |Worker.Full->E.Storage_busy,"queueFull"
    |Not_ready->E.Invalid_request,"notReady"
    |Stopping->E.Closed_session,"stopping"
    |Unsupported_request _->E.Unsupported_semantics,"unsupportedRequest" in
  let origin=E.create_cause ~component:E.Worker_service ~operation:"requestAdmission"
    ~code:(Some category) ~message:(E.message error) |> Result.get_ok in
  E.create_with_origin ~code ~message:(E.message error) ~origin ~details:[] |> Result.get_ok
;;

let interruption_error = function
  | Worker.Transport_lost error -> error
  | Cancelled -> Worker.Service_failed "Worker request was cancelled."
  | Worker_stopped -> Worker.Service_failed "Worker stopped before the request completed."
;;

let interruption_diagnostic reason =
  let module E=Logseq_db_worker.Error in
  let error=diagnostic_error(interruption_error reason) in
  let category,message=match reason with
    | Worker.Transport_lost _->"transportLost","Worker transport was lost; execution outcome may be unknown."
    | Cancelled->"cancelled","Worker request was cancelled."
    | Worker_stopped->"workerStopped","Worker stopped before the request completed." in
  let context=E.create_cause ~component:E.Worker_service ~operation:"requestCompletion"
    ~code:(Some category) ~message |> Result.get_ok in
  E.wrap ~code:(E.code error) ~message:(E.message error) ~details:(E.details error)
    ~context error |> Result.get_ok
;;

let reply_error = function
  | Worker.Answered(Error error)->Some error
  | Not_admitted reason->Some(Worker.Db_error(admission_diagnostic reason))
  | Interrupted reason->Some(Worker.Db_error(interruption_diagnostic reason))
  | Answered(Ok _)->None
;;
let reply_error_message ~fallback reply =
  Option.fold ~none:fallback ~some:error_message (reply_error reply)
;;

type watch =
  | Watch :
      'a Core.ticket
      * ((Worker.session * Worker.read_budget) option -> 'a Worker.reply -> unit)
      -> watch

module Pure_source_recovery = struct
module Source_keys=Map.Make(struct
  type t=Worker.session * string
  let compare (left,wire) (right,other)=
    let c=Worker.compare_session left right in if c=0 then String.compare wire other else c
end)
type source_phase=Reading of int | Finished
type t=source_phase Source_keys.t
type read={session:Worker.session;intent:Worker.asset_import_intent;attempt:int}
let source_key (read:read)=read.session,Bytes.to_string(Worker.encode_asset_import_intent read.intent)

(* Pure selection and completion policy; the host only interprets the returned reads. *)
let plan previous state intents =
  let candidates=match Core.projection(Core.view state) with
    |None->Source_keys.empty
    |Some projection->List.fold_left(fun all(resident:Worker.resident)->
      if resident.phase<>Worker.Open || Core.validate_session state resident.session<>Ok() then all else
      Rrbvec.fold_left(fun all intent->
        match Worker.restore_asset_import_intent resident.session(Worker.encode_asset_import_intent intent)with
        |Error _->all
        |Ok intent->let read={session=resident.session;intent;attempt=0}in
          Source_keys.add(source_key read)read all)all intents)Source_keys.empty(Worker.residents projection)in
  let previous=Source_keys.filter(fun key _->Source_keys.mem key candidates)previous in
  Source_keys.fold(fun key read(state,work)->if Source_keys.mem key state then state,work
    else Source_keys.add key(Reading 0)state,Rrbvec.push_back work read)candidates(previous,Rrbvec.empty)
type completion=Ignored | Settled | Retry of read
let empty=Source_keys.empty
let completed state read ~retryable =
  let key=source_key read in
  match Source_keys.find_opt key state with
  |Some(Reading attempt)when attempt=read.attempt->
    if attempt=0 && retryable then
      Source_keys.add key(Reading 1)state,Retry{read with attempt=1}
    else Source_keys.add key Finished state,Settled
  |_->state,Ignored

end

type t =
  { state : Core.t ref
  ; runner : Runner.t
  ; enqueue : (unit -> unit) -> unit
  ; watches : watch Rrbvec.t ref
  ; host_watches : (Worker.handoff_id * (Worker.handoff_state -> unit))Rrbvec.t ref
  ; source_reads : Pure_source_recovery.t ref
  }

let apply state runner transition =
  state := transition.Core.next;
  List.iter (Runner.submit runner) transition.instructions
;;

let flush host =
  let view = Core.view !(host.state) in
  let callbacks = ref [] and reads = ref Rrbvec.empty in
  host.watches
  := Rrbvec.fold_left
       (fun retained (Watch (ticket, callback) as watch) ->
          match Core.reply view ticket with
          | None -> Rrbvec.push_back retained watch
          | Some result ->
            let origin=Core.query_origin view ticket in
            reads := Rrbvec.push_back !reads (fun () ->
              apply host.state host.runner
                (Core.step !(host.state)(Core.Forget ticket));
              callback origin (Core.revalidate_reply (Core.view !(host.state)) ticket result));
            retained)
       Rrbvec.empty
       !(host.watches);
  host.host_watches:=Rrbvec.fold_left(fun retained(id,callback as watch)->
    match Core.handoff view id with
    |Some(Worker.Safe_to_proceed _|Host_change_applied _|Handoff_failed _ as outcome)->
      callbacks:=(fun()->callback outcome)::!callbacks;retained
    |_->Rrbvec.push_back retained watch)Rrbvec.empty !(host.host_watches);
  (* Publish already runs on the shared serial pump. Deliver after committing
     the watch lists, without an extra queue gap in which its logical result
     could be retired/replanned before a captured callback is applied. *)
  Rrbvec.iter (fun deliver -> deliver ()) !reads;
  List.iter host.enqueue (List.rev !callbacks)
;;

let create ~client ~client_id ~managed_origin ~user_id ~enqueue ~changed =
  let state = ref (Core.initial ~client_id)
  and runner = ref None
  and host = ref None in
  let post event =
    enqueue (fun () ->
      Option.iter (fun runner -> apply state runner (Core.step !state event)) !runner)
  in
  Runner.create ~client ~managed_origin ~user_id ~post ~publish:(fun view ->
    enqueue (fun () ->
      changed view;
      Option.iter flush !host))
  |> Result.map (fun value ->
    runner := Some value;
    let value = { state; runner = value; enqueue; watches = ref Rrbvec.empty;host_watches=ref Rrbvec.empty;source_reads=ref Pure_source_recovery.empty } in
    host := Some value;
    value)
;;

let view host = Core.view !(host.state)

let request host session operation =
  Core.request !(host.state) session operation
  |> Result.map (fun (ticket, transition) ->
    apply host.state host.runner transition;
    ticket)
;;

let reconcile_mutation host ~presentation intent =
  Core.reconcile_mutation !(host.state) ~presentation intent
  |> Result.map (fun (ticket, transition) ->
    apply host.state host.runner transition;
    ticket)
;;

let settle_applied_mutation host ~presentation ~applied_presentation intent =
  Core.settle_applied_mutation !(host.state) ~presentation ~applied_presentation intent
  |> Result.map(fun(ticket,transition)->apply host.state host.runner transition;ticket)
;;

let begin_change_application host batch ~root =
  Core.begin_change_application !(host.state) batch ~root
  |> Result.map (fun (token, transition) ->
    apply host.state host.runner transition;
    token)
;;

let post host event =
  host.enqueue (fun () -> apply host.state host.runner (Core.step !(host.state) event))
;;

let on_event host event = Runner.on_event host.runner event
let shutdown host = Runner.shutdown host.runner

let plan_query host ~owner ~maximum_items ~maximum_bytes query =
  Core.plan_query !(host.state) ~owner ~maximum_items ~maximum_bytes query
  |> Result.map (fun (ticket, transition) ->
    apply host.state host.runner transition;
    ticket)
;;

let plan_query_when_available host ~owner ~maximum_items ~maximum_bytes query =
  Core.plan_query_when_available !(host.state) ~owner ~maximum_items ~maximum_bytes query
  |> Result.map (fun (ticket, transition) ->
    apply host.state host.runner transition;
    ticket)
;;

let validate_session ?owner host session =
  Core.validate_session ?owner !(host.state) session
;;

let watch_read host ticket ~f =
  host.watches := Rrbvec.push_back !(host.watches) (Watch (ticket, f));
  host.enqueue (fun () -> flush host)
;;

let watch host ticket ~f = watch_read host ticket ~f:(fun _ result -> f result)

let prepare_host_change ?(legacy_pending=false) host change =
  Core.prepare_host_change ~legacy_pending !(host.state) change
  |> Result.map(fun(id,transition)->apply host.state host.runner transition;id)
;;
let authorize_host_change host receipt =
  Core.authorize_host_change !(host.state) receipt
  |> Result.map(fun transition->apply host.state host.runner transition)
;;
let watch_handoff host id ~f =
  host.host_watches:=Rrbvec.push_back !(host.host_watches)(id,f);
  host.enqueue(fun()->flush host)
;;

let host_change_blocks host ~owner=Core.host_change_blocks !(host.state) ~owner

let recover_import_sources host intents ~failed =
  let next,reads=Pure_source_recovery.plan !(host.source_reads) !(host.state)intents in
  host.source_reads:=next;
  let rec issue (read:Pure_source_recovery.read) =
    let finish error =
      let current=Core.validate_session !(host.state)read.session=Ok() in
      let retryable=current && Option.exists(function Worker.Service_failed _->true|_->false)error in
      let state,retry=Pure_source_recovery.completed !(host.source_reads)read ~retryable in
      host.source_reads:=state;
      match retry with
      |Pure_source_recovery.Ignored->()
      |Retry next->issue next
      |Settled->Option.iter(function
        |Worker.Revoked_session|Host_change_in_progress->()
        |error when current->failed read.session error
        |_->())error in
    match request host read.session(Worker.Confirm_import_source read.intent)with
    |Error error->finish(Some error)
    |Ok ticket->watch host ticket ~f:(function
      |Worker.Answered(Ok _)->finish None
      |Answered(Error error)->finish(Some error)
      |(Not_admitted _|Interrupted _) as reply->finish(reply_error reply))in
  Rrbvec.iter issue reads
