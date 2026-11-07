module Config = Logseq_db_worker_contract.Config
module Error = Logseq_db_worker_contract.Error
module Pure_reducer = Logseq_db_worker_pure_reducer.Core
module Effect_runner = Logseq_db_worker_effect_runner.Effect_runner

module Sync = Logseq_sync_pure_reducer.Core

let unlock_log_count = Atomic.make 0
let unlock_attempt_count = Atomic.make 0

let unlock_log format =
  Printf.ksprintf (fun fields ->
    if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" then (
      let count = Atomic.fetch_and_add unlock_log_count 1 in
      try
        if count < 256 then Printf.eprintf "[journal-unlock] source=core %s\n%!" fields
        else if count = 256 then Printf.eprintf "[journal-unlock] source=core limit=reached\n%!"
      with _ -> ())) format
;;

let unlock_failure = function
  | None -> "none"
  | Some Sync.During_e2ee -> "e2ee"
  | Some During_catalog -> "catalog"
  | Some During_authentication -> "authentication"
  | Some During_local_restore -> "local-restore"
  | Some During_bootstrap -> "bootstrap"
;;

let observe_unlock before (transition : Pure_reducer.transition) event =
  if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" then (
    let previous = (Pure_reducer.view before).sync.snapshot.startup in
    let next = (Pure_reducer.view transition.next).sync.snapshot.startup in
    match event with
    | Pure_reducer.Sync_event (Sync.E2ee_password_submitted _) ->
      let attempt = Atomic.fetch_and_add unlock_attempt_count 1 in
      let operation = List.find_map (function
        | Pure_reducer.Run_sync (Sync.Request (ticket, Sync.Unlock_private_key _)) ->
          Some (Sync.effect_ticket_id ticket |> Sync.effect_id_to_string)
        | _ -> None) transition.effects in
      unlock_log "attempt=%d op=%s phase=password decision=%s challenge_advertised=%b challenge_ready=%b failure=%s account_generation=%d graph_generation=%d"
        attempt (Option.value operation ~default:"none")
        (if Option.is_some operation then "accepted" else "ignored")
        previous.awaiting_e2ee_password (Option.is_some operation)
        (unlock_failure previous.failure) previous.account_generation previous.graph_generation
    | Sync_event (Sync.Runner_completed (Sync.Completion (ticket, _))) ->
      unlock_log "op=%s phase=completion effects=%d challenge_advertised=%b failure=%s account_generation=%d graph_generation=%d"
        (Sync.effect_ticket_id ticket |> Sync.effect_id_to_string)
        (List.length transition.effects)
        next.awaiting_e2ee_password (unlock_failure next.failure)
        next.account_generation next.graph_generation
    | _ -> ())
;;

type graph_phase = Pure_reducer.graph_phase =
  | Graph_closed
  | Graph_opening
  | Graph_open
  | Graph_closing
  | Graph_failed

type graph_state = Pure_reducer.graph_state =
  { generation : int
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; phase : graph_phase
  ; error : Error.t option
  }

type local_deletion_waiter =
  { graph_id : Logseq_db_types.Graph_types.Uuid.t
  ; account_generation : int
  ; prepared_handoff : Logseq_db_types.Graph_types.Uuid.t option
  ; mutable request : (Pure_reducer.ticket * Sync.mirror_deletion) option
  ; resolve : (unit, string) result Eio.Promise.u
  }

module Host=Pure_reducer.Host_handoff

type host_plan={version:int64;id:Logseq_db_types.Graph_types.Uuid.t;registration:int64;
  owner:Sync.account_scope;change:Host.change;expected:Sync.graph_scope Rrbvec.t}

type queued_event =
  | Host_begin of host_plan * (Host.request * Host.admission,string)result Eio.Promise.u
  | Host_settled of Host.attempt * (Logseq_overlay_db.Types.mirror_generation option,string)result
      * (Host.receipt,string)result Eio.Promise.u
  | Host_consume of Host.receipt * (Host.change,string)result Eio.Promise.u
  | Host_confirm of Host.receipt * (bool,string)result Eio.Promise.u
  | Host_complete of Host.receipt * (unit,string)result Eio.Promise.u
  | Host_release_registration of int64 * (unit,string)result Eio.Promise.u
  | Event of Pure_reducer.event
  | Delete_copy of local_deletion_waiter
  | Asset_command_barrier of
      { serial:int64; event:Pure_reducer.event; owner:Pure_reducer.Demand_registry.owner; data:bool
      ; resolve:(Effect_runner.asset_cleanup_snapshot,string)result Eio.Promise.u }

type coordination_snapshot =
  { version : int64
  ; presentation : int64
  ; state : Pure_reducer.coordination_state
  }

type t =
  { state : Pure_reducer.state ref
  ; runner : Effect_runner.t
  ; events : queued_event Eio.Stream.t
  ; followups : queued_event Queue.t
  ; mutable next_request_id : int64
  ; mutable stopped : bool
  ; mutable local_deletion_waiter : local_deletion_waiter option
  ; mutable coordination : coordination_snapshot
  ; mutable coordination_registration : int64
  ; mutable coordination_retirement : Pure_reducer.Registration_retirement.t
  ; mutable coordination_notify : (int64 * (coordination_snapshot -> unit)) option
  ; mutable host_handoff : Host.t
  ; host_stopped : unit Eio.Promise.t * unit Eio.Promise.u
  ; host_tasks : (Logseq_db_types.Graph_types.Uuid.t,int64 * (unit Eio.Promise.t * unit Eio.Promise.u))Hashtbl.t
  ; mutable demand_registry : Pure_reducer.Demand_registry.t
  ; mutable next_asset_command_barrier : int64
  ; asset_command_waiters : (int64,(Effect_runner.asset_cleanup_snapshot,string)result Eio.Promise.u)Hashtbl.t
  }

type create_error = Invalid_create of string

let host_facts t : Host.facts =
  {authenticated=(Pure_reducer.view !(t.state)).sync.snapshot.startup.authenticated;
   version=t.coordination.version;registration=Option.map fst t.coordination_notify;
   account=t.coordination.state.sync.account;
   scopes=Rrbvec.of_list(List.map fst t.coordination.state.residents);
   catalog=Rrbvec.of_list(List.map(fun(graph:Sync.graph)->graph.graph_id)
     (Pure_reducer.view !(t.state)).sync.snapshot.catalog)}
;;
let host_error=function
  |Host.Busy->"Another host change still owns physical settlement."
  |Retired->"This host change permission has already retired."
  |Mismatch->"The host change receipt does not match its original owner."
  |Owner_changed->"The host change account or registration retired."
  |Scopes_changed->"A target execution reopened during host settlement."
  |Baseline_changed->"The authoritative baseline changed before host preparation."
  |Full->"Host change ownership capacity is full."
  |Missing_copy_witness->"The local copy has no exclusive preparation witness."
  |Not_settled->"The physical host change has not settled."
;;

let dispatch t event =
  let refused_deletion=ref None in
  let before = !(t.state) in
  let transition = Pure_reducer.step before event in
  observe_unlock before transition event;
  t.state := transition.next;
  let state=Pure_reducer.coordination_state transition.next in
  if state<>t.coordination.state then (
    let previous=t.coordination in
    if previous.version=Int64.max_int then failwith "Coordination version exhausted";
    let presentation=if previous.state.sync.selected=state.sync.selected then previous.presentation
      else (if previous.presentation=Int64.max_int then failwith "Presentation version exhausted";
        Int64.succ previous.presentation) in
    t.coordination <- {state;version=Int64.succ previous.version;presentation};
    Option.iter (fun (_,notify)->notify t.coordination) t.coordination_notify);
  t.coordination_retirement<-Pure_reducer.Registration_retirement.observe t.coordination_retirement
    ~registration:(Option.map fst t.coordination_notify) ~account:t.coordination.state.sync.account;
  t.host_handoff<-Host.observe t.host_handoff(host_facts t);
  (match Host.current t.host_handoff with
   |Some(request,Host.Consumed receipt) when request.change=Host.Replace_account
      && (match (host_facts t).account with
          |None->true|Some account->account.user_id<>request.owner.user_id
            || not(Uri.equal account.managed_sync_origin request.owner.managed_sync_origin)
            || account.account_generation<>request.owner.account_generation
            || account.lifecycle_generation<>request.owner.lifecycle_generation)->
     let _,resolve=Eio.Promise.create() in Queue.add(Host_complete(receipt,resolve))t.followups
   |_->());
  (match t.local_deletion_waiter with
   | None -> ()
   | Some waiter ->
     let finish result =
       t.local_deletion_waiter <- None;
       ignore (Eio.Promise.try_resolve waiter.resolve result : bool) in
     let snapshot = (Pure_reducer.view transition.next).sync.snapshot in
     if snapshot.startup.account_generation <> waiter.account_generation
     then finish (Error "The graph account is no longer current.")
     else (
       (match waiter.request, event with
        | None, Pure_reducer.Sync_event (Sync.Local_cache_deletion_requested graph_id)
          when graph_id = waiter.graph_id ->
          waiter.request <- List.find_map (function
            | Pure_reducer.Run_worker (Pure_reducer.Request (ticket, Pure_reducer.Handle_sync_worker_effect (Sync.Delete_mirror request))) ->
              Some (ticket, request)
            | _ -> None) transition.effects;
          if waiter.request = None then finish (Error "This local copy cannot be deleted now.");
          (match waiter.prepared_handoff,waiter.request with
           |Some handoff_id,Some(ticket,request)->
             (match Effect_runner.bind_host_copy t.runner ~handoff_id request with
              |Ok()->()|Error error->refused_deletion:=Some(ticket,error))
           |_->())
        | _ -> ());
       match waiter.request, event with
       | Some (expected_ticket, expected),
         Pure_reducer.Runner_completed
           (Pure_reducer.Sync_worker_effect_completed
             (ticket, Ok { event = Some (Sync.Mirror_deleted (actual, result)); _ }))
         when ticket = expected_ticket && actual = expected -> finish result
       | Some (expected_ticket, _),
         Pure_reducer.Runner_completed
           (Pure_reducer.Sync_worker_effect_completed (ticket, Error error))
         when ticket = expected_ticket ->finish (Error (Logseq_db_worker_contract.Error.message error))
       | _ -> ()));
  List.iter (function
    |Pure_reducer.Run_worker(Pure_reducer.Request(ticket,Pure_reducer.Handle_sync_worker_effect(Sync.Delete_mirror _)))
       when Option.exists(fun(actual,_)->actual=ticket)!refused_deletion->
      let _,error=Option.get !refused_deletion in
      Queue.add(Event(Pure_reducer.Runner_completed(Pure_reducer.Sync_worker_effect_completed(ticket,Error error))))t.followups
    |instruction->Effect_runner.submit t.runner instruction)transition.effects
;;

let accepts_after_shutdown = function
  | Pure_reducer.Asset_cleanup_barrier _->true
  | Pure_reducer.Sync_event
      ( Logseq_sync_pure_reducer.Core.Asset_requested _ | Protected_requested _
      | Runner_completed (Asset_completion _ | Protected_completion _)
      | IO_fence_completed _
      | Shutdown ) -> true
  | _ -> false
;;

let route_event t event =
  if t.stopped
  then (if accepts_after_shutdown event then dispatch t event)
  else Eio.Stream.add t.events (Event event)
;;

let coordination_live t registration=not t.stopped && Option.fold ~none:false
  ~some:(fun(id,_)->id=registration)t.coordination_notify

let dispatch_queued t = function
  |Host_begin(plan,resolve)->
    let result=if t.stopped then Error "Worker stopped before host preparation." else
      let captured=Host.capture ~owner:plan.owner ~change:plan.change
        (Rrbvec.append (host_facts t).scopes (Effect_runner.physical_host_scopes t.runner)) in
      let request:Host.request={version=plan.version;id=plan.id;registration=plan.registration;
        owner=plan.owner;change=plan.change;expected=plan.expected;captured} in
      let next,decision=Host.prepare t.host_handoff(host_facts t)request in
      t.host_handoff<-next;
      (match decision with
       |Host.Start _->
         Hashtbl.add t.host_tasks plan.id(plan.registration,Eio.Promise.create());
         let previous=Option.map(fun(fence:Sync.host_fence)->fence.id)(Pure_reducer.host_fence_active !(t.state)) in
         let target=match plan.change with Host.Close_graph id|Remove_graph(id,_)->Sync.One_graph id
           |Replace_account|Stop_connection->All_graphs in
         dispatch t(Pure_reducer.Sync_event(Sync.Host_fence_started{id=plan.id;owner=plan.owner;target;captured_scopes=captured;previous}));
         if Option.exists(fun(fence:Sync.host_fence)->fence.id=plan.id)(Pure_reducer.host_fence_active !(t.state))
         then Ok(request,decision) else Error "The physical execution gate was not admitted."
       |_->Ok(request,decision)) in
    ignore(Eio.Promise.try_resolve resolve result:bool)
  |Host_settled(attempt,result,resolve)->
    t.host_handoff<-Host.observe t.host_handoff(host_facts t);
    t.host_handoff<-(match result with Ok copy_generation->Host.settled t.host_handoff attempt ~copy_generation
      |Error _->Host.failed t.host_handoff attempt);
    let result=match result,Host.current t.host_handoff with
      |Error message,_->Error message
      |Ok _,Some(_,Host.Safe receipt)->Ok receipt
      |Ok _,Some(_,Host.Failed error)->Error(host_error error)
      |_->Error "The physical host settlement retired before acknowledgement." in
    ignore(Eio.Promise.try_resolve resolve result:bool)
  |Host_consume(receipt,resolve)->
    let next,result=Host.consume t.host_handoff(host_facts t)receipt in
    t.host_handoff<-next;
    (match result with Ok _->let request=Host.receipt_request receipt in
      Hashtbl.add t.host_tasks request.id(request.registration,Eio.Promise.create())|Error _->());
    ignore(Eio.Promise.try_resolve resolve(Result.map_error host_error result):bool)
  |Host_confirm(receipt,resolve)->
    ignore(Eio.Promise.try_resolve resolve(Result.map_error host_error(Host.consumed t.host_handoff receipt)):bool)
  |Host_complete(receipt,resolve)->
    t.host_handoff<-Host.completed t.host_handoff receipt;
    let id=(Host.receipt_request receipt).id in
    dispatch t(Pure_reducer.Sync_event(Sync.Host_fence_released id));
    ignore(Eio.Promise.try_resolve resolve(Ok()):bool)
  |Host_release_registration(registration,resolve)->
    let next,retired=Host.released_registration t.host_handoff registration in
    t.host_handoff<-next;
    Option.iter(fun id->dispatch t(Pure_reducer.Sync_event(Sync.Host_fence_released id)))retired;
    ignore(Eio.Promise.try_resolve resolve(Ok()):bool)
  | Event event -> dispatch t event
  | Asset_command_barrier{serial;event;owner;data;resolve}->
    Hashtbl.remove t.asset_command_waiters serial;
    let result=if t.stopped then Error "The Worker stopped before resource settlement."
      else if data && (not(coordination_live t owner.registration)
        || not(Pure_reducer.Demand_registry.admitted t.demand_registry owner))
      then Error "The asset demand round retired before application."
      else (dispatch t event;Ok(Effect_runner.asset_cleanup_snapshot t.runner ~scope:owner.scope)) in
    ignore(Eio.Promise.try_resolve resolve result:bool)
  | Delete_copy waiter ->
    let snapshot = (Pure_reducer.view !(t.state)).sync.snapshot in
    if not t.stopped && snapshot.startup.authenticated
       && snapshot.startup.account_generation = waiter.account_generation
       && snapshot.selected_graph <> Some waiter.graph_id
       && Option.fold ~none:false ~some:(fun active -> active == waiter) t.local_deletion_waiter
    then dispatch t (Pure_reducer.Sync_event (Sync.Local_cache_deletion_requested waiter.graph_id))
    else (
      if Option.fold ~none:false ~some:(fun active -> active == waiter) t.local_deletion_waiter
      then t.local_deletion_waiter <- None;
      ignore (Eio.Promise.try_resolve waiter.resolve (Error "The graph account is no longer current.") : bool))
;;

let fresh_host_lifetime () =
  let bytes=In_channel.with_open_bin "/dev/urandom"(fun input->really_input_string input 16) in
  let hex=String.concat ""(List.init 16(fun n->Printf.sprintf "%02x"(Char.code bytes.[n]))) in
  Logseq_db_types.Graph_types.Uuid.of_string(Printf.sprintf "%s-%s-4%s-8%s-%s"
    (String.sub hex 0 8)(String.sub hex 8 4)(String.sub hex 13 3)(String.sub hex 17 3)(String.sub hex 20 12))
  |> Result.get_ok
;;

let create ~sw ~config ~runner_dependencies =
  match Pure_reducer.initial config with
  | Error (Pure_reducer.Invalid_create message) -> Error (Invalid_create message)
  | Ok state ->
    let events = Eio.Stream.create 256 in
    let state_ref = ref state in
    let event_sink = ref (fun event -> Eio.Stream.add events (Event event)) in
    (match
       Effect_runner.create
         ~sw
         runner_dependencies
         ~recovery_current:(fun ticket ->
           Pure_reducer.upload_recovery_current !state_ref ticket)
         ~upload_current:(fun ticket ->
           Pure_reducer.upload_ticket_current !state_ref ticket)
         ~asset_current:(fun ticket ->
           Pure_reducer.asset_ticket_current !state_ref ticket)
         ~post:(fun event -> !event_sink event)
     with
     | Error (Effect_runner.Invalid_create message) -> Error (Invalid_create message)
     | Ok runner ->
       let t =
         { state = state_ref; runner; events;followups=Queue.create(); next_request_id = 0L; stopped = false
         ; local_deletion_waiter = None
         ; coordination={version=0L;presentation=0L;state=Pure_reducer.coordination_state state}
         ; coordination_registration=0L;coordination_notify=None;coordination_retirement=Pure_reducer.Registration_retirement.empty
         ; host_handoff=Host.empty ~lifetime:(fresh_host_lifetime());host_stopped=Eio.Promise.create();host_tasks=Hashtbl.create 2
         ; demand_registry=Pure_reducer.Demand_registry.empty;next_asset_command_barrier=0L
         ; asset_command_waiters=Hashtbl.create 16 }
       in
       event_sink := route_event t;
       dispatch t Pure_reducer.Start;
       Eio.Fiber.fork ~sw (fun () ->
         while not t.stopped do
           dispatch_queued t (if Queue.is_empty t.followups then Eio.Stream.take events else Queue.take t.followups)
         done);
       Ok t)
;;

let post t event = route_event t event
let report_asset_diagnostic t ~scope ~operation ~request_operation diagnostic =
  if not t.stopped then
    Effect_runner.report_asset_diagnostic t.runner ~scope ~operation ~request_operation diagnostic
;;

let view t = Pure_reducer.view !(t.state)
let graph_state t = (view t).graph

let coordination_current t ~registration=coordination_live t registration
;;

let register_coordination t ~registration ~notify =
  if t.stopped then Error "Worker stopped"
  else if coordination_current t ~registration then Ok t.coordination
  else if registration<=t.coordination_registration then Error "Coordination binding retired"
  else (
    Result.map(fun retirement->
      t.coordination_retirement<-retirement;
      t.coordination_registration<-registration;
      t.coordination_notify<-Some(registration,notify);
      t.coordination)(Pure_reducer.Registration_retirement.bind t.coordination_retirement
        ~registration ~account:t.coordination.state.sync.account))
;;

let run_asset_command_barrier t ~owner ~data event =
  if t.stopped then Error "The Worker stopped before asset resource admission."
  else if t.next_asset_command_barrier=Int64.max_int then Error "Resource command counter exhausted." else
  let promise,resolve=Eio.Promise.create() in
  t.next_asset_command_barrier<-Int64.succ t.next_asset_command_barrier;
  let serial=t.next_asset_command_barrier in
  Hashtbl.add t.asset_command_waiters serial resolve;
  Fun.protect ~finally:(fun()->Hashtbl.remove t.asset_command_waiters serial)(fun()->
    Eio.Stream.add t.events(Asset_command_barrier{serial;event;owner;data;resolve});
    Eio.Promise.await promise)
;;

let replace_coordinated_asset_demand t ~registration ~scope ~consumer ~priority ~assets =
  let module R=Pure_reducer.Demand_registry in
  if not(coordination_current t ~registration) then Error "The coordination binding retired."
  else
    let owner:R.owner={registration;scope;consumer} in
    let registry,decision=R.reserve t.demand_registry owner ~priority ~assets in
    t.demand_registry<-registry;
    match decision with
    | R.Existing->Ok()
    | R.Retired->Error "The asset demand round retired."
    | R.Mismatch->Error "The asset demand round changed its immutable owner or descriptors."
    | R.Full->Error "Asset demand ownership capacity is full. Retire previous rounds."
    | R.Invalid->Error "Invalid bounded asset demand."
    | R.Start->
      Eio.Cancel.protect(fun()->
        run_asset_command_barrier t ~owner ~data:true
          (Pure_reducer.Asset_requested_for_scope(scope,Logseq_sync_pure_reducer.Asset_transfer.Replace{consumer;priority;assets}))
        |> Result.map(fun _->()))
;;

let asset_demand_creator_finished t ~registration ~consumer =
  t.demand_registry<-Pure_reducer.Demand_registry.creator_finished t.demand_registry ~registration ~consumer
;;
let finalize_coordinated_asset_demand t ~registration ~scope ~consumer =
  let owner:Pure_reducer.Demand_registry.owner={registration;scope;consumer} in
  let next,result=Pure_reducer.Demand_registry.finalize t.demand_registry owner in
  t.demand_registry<-next;result
;;

let release_coordinated_asset_demand t ~registration ~scope ~consumer =
  let module R=Pure_reducer.Demand_registry in
  if t.stopped then Error "The Worker stopped before resource release."
  else if registration<=0L || registration>t.coordination_registration then Error "Unknown coordination resource owner." else
  let owner:R.owner={registration;scope;consumer} in
  let registry,decision=R.retire t.demand_registry owner in
  t.demand_registry<-registry;
  match decision with
  | R.Unknown|R.Already_settled->Ok()
  | R.Mismatch->Error "The resource cleanup owner does not match its allocation."
  | R.Full->Error "Asset demand retirement capacity is full."
  | R.Release->
    let actual=R.pending t.demand_registry ~registration |> Rrbvec.find_opt(fun owner->owner.R.consumer=consumer) |> Option.get in
    Result.bind(run_asset_command_barrier t ~owner:actual ~data:false
      (Pure_reducer.Asset_requested_for_scope(actual.scope,Logseq_sync_pure_reducer.Asset_transfer.Release consumer)))
      (fun snapshot->Result.map(fun()->t.demand_registry<-R.settled t.demand_registry actual)
        (Effect_runner.await_asset_cleanup t.runner snapshot))
;;

let release_coordination t ~registration =
  if registration>=t.coordination_registration then (
    t.coordination_registration<-registration;
    t.coordination_notify<-None);
  let jobs=Hashtbl.fold(fun _ (owner,(promise,_)) jobs->
    if owner=registration then promise::jobs else jobs)t.host_tasks [] in
  List.iter Eio.Promise.await jobs;
  let error=ref None in
  let record=function Ok()->()|Error message->if !error=None then error:=Some message in
  Pure_reducer.Demand_registry.pending t.demand_registry ~registration
  |> Rrbvec.iter(fun owner->record(release_coordinated_asset_demand t ~registration ~scope:owner.Pure_reducer.Demand_registry.scope ~consumer:owner.consumer));
  record(Effect_runner.release_observations_checked t.runner ~registration);
  let plan_retirement ()=Pure_reducer.Registration_retirement.begin_release t.coordination_retirement
    ~registration ~active_account:t.coordination.state.sync.account
    ~active_scopes:(Rrbvec.of_list(Pure_reducer.graph_scopes !(t.state)))
    ~physical_scopes:(Effect_runner.physical_host_scopes t.runner) in
  let retirement,plan=plan_retirement() in t.coordination_retirement<-retirement;
  if plan.blocked then record(Error "A newer live account still owns this resource namespace.") else (
    (match Host.current t.host_handoff with
     |Some(request,phase) when request.registration=registration->
       (match phase,request.change with
        |Host.Consumed _,(Host.Stop_connection|Replace_account)->()
        |_->Rrbvec.iter(fun scope->record(Effect_runner.settle_host_scope t.runner ~scope))request.captured;
          record(Effect_runner.release_host_copy t.runner ~registration))
     |_->());
    Rrbvec.iter(fun scope->record(Effect_runner.settle_host_scope t.runner ~scope))plan.scopes);
  if plan.join_account then Option.iter(fun owner->
    let scope={(Sync.effect_scope_of_account owner)with presentation_generation=None;lifecycle_generation=None} in
    record(Effect_runner.await_sync_io t.runner ~scope))plan.owner;
  (* Joining IO yields. Recheck the original pure owner before touching its
     logical namespace; a later live incarnation cannot be purged by this ACK. *)
  let retirement,current=plan_retirement() in t.coordination_retirement<-retirement;
  if current.blocked then record(Error "The account reopened during physical retirement.")
  else if plan.join_account && !error=None then Option.iter(fun owner->
    record(Effect_runner.retire_account t.runner ~account:owner))plan.owner;
  Effect_runner.retire_changefeed t.runner ~registration;
  (match !error with
   | Some message->Error message
   | None->
     let promise,resolve=Eio.Promise.create() in
     if not t.stopped then Eio.Stream.add t.events(Host_release_registration(registration,resolve))
     else ignore(Eio.Promise.try_resolve resolve(Error "Worker stopped before host retirement."):bool);
     Result.map(fun()->
       t.coordination_retirement<-Pure_reducer.Registration_retirement.released t.coordination_retirement ~registration;
       Effect_runner.retire_observation_registration t.runner ~registration;
       t.demand_registry<-Pure_reducer.Demand_registry.forget_settled t.demand_registry ~registration)
       (Eio.Fiber.first(fun()->Eio.Promise.await promise)
         (fun()->Eio.Promise.await(fst t.host_stopped);Error "Worker stopped before host retirement.")))
;;

let revoke_coordination t = t.coordination_notify<-None

let delete_local_copy_internal ?prepared_handoff t ~account_generation ~graph_id =
  let snapshot = (view t).sync.snapshot in
  if t.stopped || t.local_deletion_waiter <> None
     || (prepared_handoff=None && Pure_reducer.host_fence_active !(t.state)<>None)
     || not snapshot.startup.authenticated
     || snapshot.startup.account_generation <> account_generation
     || List.exists (fun (scope:Sync.graph_scope)->scope.graph_id=graph_id) (Pure_reducer.graph_scopes !(t.state))
     || not (List.exists (fun (graph : Sync.graph) -> graph.graph_id = graph_id) snapshot.catalog)
  then Error "This local copy cannot be deleted now."
  else (
    let outcome, resolve = Eio.Promise.create () in
    let waiter = { graph_id; account_generation; prepared_handoff;request = None; resolve } in
    t.local_deletion_waiter <- Some waiter;
    (try Eio.Stream.add t.events (Delete_copy waiter)
     with error ->
       if Option.fold ~none:false ~some:(fun active -> active == waiter) t.local_deletion_waiter
       then t.local_deletion_waiter <- None;
       raise error);
    Eio.Promise.await outcome)
;;

let delete_local_copy t ~account_generation ~graph_id =
  delete_local_copy_internal t ~account_generation ~graph_id
;;

let shutdown t =
  if not t.stopped
  then (
    t.stopped <- true;
    ignore(Eio.Promise.try_resolve(snd t.host_stopped)():bool);
    revoke_coordination t;
    Option.iter (fun waiter ->
      ignore (Eio.Promise.try_resolve waiter.resolve (Error "The Worker stopped.") : bool))
      t.local_deletion_waiter;
    t.local_deletion_waiter <- None;
    Hashtbl.iter(fun _ resolve->ignore(Eio.Promise.try_resolve resolve(Error "The Worker stopped before resource settlement."):bool))t.asset_command_waiters;
    Hashtbl.clear t.asset_command_waiters;
    dispatch t Pure_reducer.Shutdown;
    let rec drain () =
      match (if Queue.is_empty t.followups then Eio.Stream.take_nonblocking t.events else Some(Queue.take t.followups)) with
      | None -> ()
      | Some (Event event) ->
        if accepts_after_shutdown event then dispatch t event;
        drain ()
      | Some(Host_begin(_,resolve))->
        ignore(Eio.Promise.try_resolve resolve(Error "Worker stopped before host preparation."):bool);drain()
      | Some(Host_settled(_,_,resolve))->
        ignore(Eio.Promise.try_resolve resolve(Error "Worker stopped before host settlement."):bool);drain()
      | Some(Host_consume(_,resolve))->
        ignore(Eio.Promise.try_resolve resolve(Error "Worker stopped before host consumption."):bool);drain()
      | Some(Host_confirm(_,resolve))->
        ignore(Eio.Promise.try_resolve resolve(Error "Worker stopped before host readback."):bool);drain()
      | Some(Host_release_registration(_,resolve))
      | Some(Host_complete(_,resolve))->
        ignore(Eio.Promise.try_resolve resolve(Error "Worker stopped before host action completion."):bool);drain()
      | Some(Asset_command_barrier{resolve;_})->
        ignore(Eio.Promise.try_resolve resolve(Error "The Worker stopped before resource settlement."):bool);drain()
      | Some (Delete_copy waiter) ->
        ignore (Eio.Promise.try_resolve waiter.resolve (Error "The Worker stopped.") : bool);
        drain ()
    in
    drain ();
    Eio.Stream.add t.events (Event Pure_reducer.Shutdown);
    Effect_runner.shutdown t.runner)
;;

let retain_asset_file t ~scope ~handle =
  if t.stopped || not (Pure_reducer.asset_scope_current !(t.state) scope)
  then None
  else Effect_runner.retain_asset_file t.runner ~scope ~handle
;;

let release_asset_file t ~scope ~handle =
  Effect_runner.release_asset_file t.runner ~scope ~handle
;;

let release_asset_file_checked t ~scope ~handle =
  Effect_runner.release_asset_file_checked t.runner ~scope ~handle
;;

let abandon_asset_file t ~scope ~handle=Effect_runner.abandon_asset_file t.runner ~scope ~handle
let unsettled_orphan_retains t=Effect_runner.unsettled_orphan_retains t.runner

type import_receipt =
  { operation : Logseq_db_types.Graph_types.Uuid.t
  ; graph_generation : int
  ; scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; target : Logseq_db_types.Graph_types.Uuid.t
  ; asset : Logseq_db_types.Asset_descriptor.t
  ; file_type : string
  ; preview : (string * string) option
  }

let import_asset ?scope ?(current=(fun()->true)) t ~graph_generation request =
  let authorized=current in
  let context=match scope with None->Pure_reducer.import_context !(t.state) ~graph_generation
    |Some (scope:Sync.graph_scope) when scope.graph_generation=graph_generation->Pure_reducer.import_context_for_scope !(t.state) scope
    |Some _->None in
  match context with
  | None -> Error "The graph is unavailable or its import queue is full"
  | Some context ->
    let current () =
      (not t.stopped) && authorized()
      &&
      match Pure_reducer.import_context_for_scope !(t.state) context.scope with
      | Some latest -> latest.scope = context.scope
      | None -> false
    in
    Result.bind
      (Effect_runner.prepare_import t.runner ~context request ~current)
      (fun intent -> Eio.Cancel.protect(fun()->
         if not(current()) then Error "The import owner retired after source preparation." else
         let preview =
           Effect_runner.retain_imported_file
             t.runner
             ~scope:context.scope
             ~operation:intent.Logseq_db_types.Asset_upload_intent.operation_id
         in
         if not(current()) then (
           Option.iter(fun(handle,_)->Effect_runner.abandon_asset_file t.runner ~scope:context.scope ~handle)preview;
           Error "The import owner retired after preview acquisition.") else
         let asset =
           Logseq_db_types.Asset_descriptor.create
             ~uuid:intent.asset
             ~source:(Managed None)
             ~current_checksum:(Some intent.version.checksum)
             ~size:(Some intent.size)
             ~dimensions:None
           |> Result.get_ok
         in
         dispatch
           t
           (Pure_reducer.Upload_requested_for_scope
              (context.scope, intent.Logseq_db_types.Asset_upload_intent.operation_id,
                Logseq_db_worker_pure_reducer.Asset_upload.Restore intent));
         Ok { operation = intent.operation_id
         ; graph_generation
         ; scope = context.scope
         ; target = intent.target
         ; asset
         ; file_type = intent.version.file_type
         ; preview
         }))
;;

let retain_imported_file t ~scope ~operation =
  if t.stopped || not (Pure_reducer.asset_scope_current !(t.state) scope)
  then None
  else Effect_runner.retain_imported_file t.runner ~scope ~operation
;;

let read_for_scope t ~scope read =
  let id=Pure_reducer.request_id_of_int64 t.next_request_id in
  t.next_request_id<-Int64.succ t.next_request_id;
  Effect_runner.await_reply t.runner ~id ~read ~post:(fun()->
    post t(Pure_reducer.Graph_request_for_scope{scope;id;read}))
;;
let register_observation
      t
      ~registration
      ~id
      ~scope
      ~read
            ~current
      ~notify
  =
  let current () =
    (not t.stopped)
    && coordination_current t ~registration
    && current ()
    &&
    match Pure_reducer.graph_state_for_scope !(t.state) scope with
    | Some { phase = Graph_open; graph_id = Some actual; generation; _ } ->
      actual = scope.Sync.graph_id && generation = scope.graph_generation
    | _ -> false
  in
  Effect_runner.register_observation
    t.runner
    ~registration
    ~id
    ~scope
    ~read
        ~current
    ~notify
;;

let refresh_observation t ~registration ~id ~scope  =
  if not (coordination_current t ~registration)
  then Error "Observation binding retired"
  else Effect_runner.refresh_observation t.runner ~registration ~id ~scope
;;

let observation_scope t ~registration ~id =
  Effect_runner.observation_scope t.runner ~registration ~id
;;

let release_observation t ~registration ~id ~scope =
  Effect_runner.release_observation t.runner ~registration ~id ~scope
;;
let observation_creator_finished t ~registration ~id =
  Effect_runner.observation_creator_finished t.runner ~registration ~id
;;
let finalize_observation t ~registration ~id ~owner =
  Effect_runner.finalize_observation t.runner ~registration ~id ~owner
;;

let release_unallocated_observation t ~registration ~id ~owner =
  Effect_runner.release_unallocated_observation t.runner ~registration ~id ~owner
;;

let durable_mutation_for_scope t ~scope ~intent ~current =
  let current () = not t.stopped && current () &&
    (match Pure_reducer.graph_state_for_scope !(t.state) scope with
     | Some {phase=Graph_open;graph_id=Some id;generation;_} ->
       id=scope.Sync.graph_id && generation=scope.graph_generation
     | _ -> false) in
  Effect_runner.durable_mutation t.runner ~scope ~intent ~current
;;
let graph_scopes t = Pure_reducer.graph_scopes !(t.state)
let graph_state_for_scope t ~scope = Pure_reducer.graph_state_for_scope !(t.state) scope

let coordination_presentation_current t ~registration ~presentation ~(owner:Sync.timeline_scope) =
  coordination_current t ~registration && t.coordination.presentation=presentation &&
  Option.fold ~none:false ~some:(fun (selected:Sync.timeline_scope) ->
    selected.graph_id=owner.graph_id && selected.graph_generation=owner.graph_generation &&
    selected.startup.account_generation=owner.startup.account_generation)
    t.coordination.state.sync.selected
;;
let confirm_mutation_for_scope t ~scope ~read ~intent ~original ~current =
  let current ()=not t.stopped && current () &&
    (match Pure_reducer.graph_state_for_scope !(t.state) scope with
     | Some{phase=Graph_open;graph_id=Some id;generation;_}->
       id=scope.Sync.graph_id && generation=scope.graph_generation
     | _->false) in
  Effect_runner.confirm_mutation t.runner ~scope ~read ~intent ~original ~current
;;

let recover_mutations_for_scope t ~scope ~after ~maximum_items ~maximum_bytes ~current =
  let current ()=not t.stopped && current() &&
    (match Pure_reducer.graph_state_for_scope !(t.state) scope with
     | Some{phase=Graph_open;graph_id=Some id;generation;_}->id=scope.Sync.graph_id && generation=scope.graph_generation
     | _->false) in
  Effect_runner.recover_mutations t.runner ~scope ~after ~maximum_items ~maximum_bytes ~current
;;

let acknowledge_mutation_for_scope t ~scope ~intent ~original ~current =
  let current ()=not t.stopped && current() &&
    (match Pure_reducer.graph_state_for_scope !(t.state) scope with
     | Some{phase=Graph_open;graph_id=Some id;generation;_}->id=scope.Sync.graph_id && generation=scope.graph_generation
     | _->false) in
  Effect_runner.acknowledge_mutation t.runner ~scope ~intent ~original ~current
;;

let acknowledge_change_batch t ~registration ~scope ~batch ~current =
  let current ()=coordination_current t ~registration && current() &&
    match Pure_reducer.graph_state_for_scope !(t.state) scope with
    |Some{phase=Graph_open;graph_id=Some id;generation;_}->id=scope.Sync.graph_id && generation=scope.graph_generation
    |_->false in
  Effect_runner.acknowledge_change_batch t.runner ~registration ~scope ~batch ~current
;;
let quiesce_writers t ~registration ~scope =
  if not(coordination_current t ~registration)
     || not(List.exists(fun actual->Pure_reducer.Writer_fence.same_incarnation scope actual)(Pure_reducer.graph_scopes !(t.state)))
  then Error "The writer fence owner is no longer current." else
  Result.bind(Effect_runner.quiesce_writers t.runner ~scope)(fun()->
    if coordination_current t ~registration then Ok() else Error "The writer fence binding retired.")
;;

let await_host_command t make =
  if t.stopped then Error "Worker stopped before host command admission." else
  let promise,resolve=Eio.Promise.create() in
  Eio.Stream.add t.events(make resolve);
  Eio.Fiber.first (fun()->Eio.Promise.await promise)
    (fun()->Eio.Promise.await(fst t.host_stopped);Error "Worker stopped before host acknowledgement.")
;;

let finish_host_task t id =match Hashtbl.find_opt t.host_tasks id with
  |None->()|Some(_,(_,resolve))->Hashtbl.remove t.host_tasks id;
    ignore(Eio.Promise.try_resolve resolve():bool)
;;

let prepare_host_change t plan = Eio.Cancel.protect(fun()->
  let started=ref false in
  Fun.protect ~finally:(fun()->if !started then finish_host_task t plan.id)(fun()->
  Result.bind(await_host_command t(fun resolve->Host_begin(plan,resolve)))(fun(request,decision)->
    match decision with
    |Host.Refused error|Existing(Failed error)->Error(host_error error)
    |Existing(Safe receipt)->Ok receipt
    |Existing(Consumed _)->Error "This host permission has already been consumed."
    |Existing Preparing->Error "This host preparation is still running."
    |Start attempt->
      started:=true;
      let settled=Rrbvec.fold_left(fun result scope->Result.bind result(fun()->
        Effect_runner.settle_host_scope t.runner ~scope))(Ok())request.captured in
      let settled=Result.bind settled(fun()->
        match request.change with
        |Host.Replace_account|Stop_connection->
          let scope={ (Sync.effect_scope_of_account request.owner) with
            presentation_generation=None;lifecycle_generation=None } in
          Effect_runner.await_sync_io t.runner ~scope
        |Close_graph _|Remove_graph _->Ok()) in
      let settled=Result.bind settled(fun()->
        match request.change with
        |Host.Remove_graph(graph_id,_)->Effect_runner.prepare_host_copy t.runner
          ~registration:request.registration ~handoff_id:request.id ~owner:request.owner ~graph_id
          |> Result.map Option.some
        |Close_graph _|Replace_account|Stop_connection->Ok None) in
      await_host_command t(fun resolve->Host_settled(attempt,settled,resolve)))))
;;

let apply_host_change t receipt = Eio.Cancel.protect(fun()->
  let request=Host.receipt_request receipt in
  let started=ref false in
  Fun.protect ~finally:(fun()->if !started then finish_host_task t request.id)(fun()->
    Result.bind(await_host_command t(fun resolve->Host_consume(receipt,resolve)))(fun change->
      started:=true;
      match change with
      |Host.Close_graph _->await_host_command t(fun resolve->Host_complete(receipt,resolve))
      |Replace_account|Stop_connection->Ok()
      |Remove_graph(graph_id,_)->
        let result=delete_local_copy_internal ~prepared_handoff:request.id t
          ~account_generation:request.owner.account_generation ~graph_id in
        Result.bind(Effect_runner.release_host_copy t.runner ~registration:request.registration)(fun()->
          Result.bind(await_host_command t(fun resolve->Host_complete(receipt,resolve)))(fun()->result)))))
;;

let confirm_host_change t receipt = Eio.Cancel.protect(fun()->
  let id=(Host.receipt_request receipt).id in
  Option.iter(fun(_, (promise,_))->Eio.Promise.await promise)(Hashtbl.find_opt t.host_tasks id);
  await_host_command t(fun resolve->Host_confirm(receipt,resolve)))
;;

let import_input_current t ~scope ~current ()=
  not t.stopped && current() &&
  match Pure_reducer.graph_state_for_scope !(t.state) scope with
  |Some{phase=Graph_open;graph_id=Some id;generation;_}->id=scope.Sync.graph_id && generation=scope.graph_generation
  |_->false
;;
let recover_import_inputs_for_scope t ~scope ~after ~maximum_items ~maximum_bytes ~current =
  Effect_runner.recover_import_inputs t.runner ~scope ~after ~maximum_items ~maximum_bytes
    ~current:(import_input_current t ~scope ~current)
;;
let confirm_import_input_for_scope t ~scope ~input ~current =
  Effect_runner.confirm_import_input t.runner ~scope ~input ~current:(import_input_current t ~scope ~current)
;;
let acknowledge_import_input_for_scope t ~scope ~input ~prepared ~current =
  Effect_runner.acknowledge_import_input t.runner ~scope ~input ~prepared ~current:(import_input_current t ~scope ~current)
;;
