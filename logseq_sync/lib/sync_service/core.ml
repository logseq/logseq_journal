module Dsl = Sync_dsl.Core
module Execute = Execute.Core

type config =
  { identity : Dsl.identity
  ; limits : Dsl.limits
  ; network : Dsl.network_gate
  ; policy : Dsl.policy_config
  }

type ingress =
  { outbox_committed :
      owner:Execute.database_owner -> identity:Dsl.identity -> (unit, Dsl.error) result
  ; submit_unlock :
      identity:Dsl.identity
      -> valid_for:float
      -> Dsl.unlock_input
      -> (Execute.ingress_ack, Dsl.error) result
  ; update_demand : Dsl.demand_change -> (Execute.ingress_ack, Dsl.error) result
  ; receive_demand : unit -> (Dsl.demand_output, Dsl.error) result
  ; demand_status : Dsl.demand_delivery -> (Execute.delivery_status, Dsl.error) result
  ; release_demand : Dsl.demand_delivery -> (unit, Dsl.error) result
  }

type 'clock dependencies =
  { clock : 'clock Eio.Time.Mono.t
  ; database_owner : Execute.database_owner
  ; capabilities : Execute.capabilities
  ; bind_ingress : ingress -> unit
  }

type error = Dsl.error

exception Reentrant_close
exception Close_already_called

exception
  Close_failed of
    { error : error option
    ; cause : (exn * Printexc.raw_backtrace) option
    }

module State = Logseq_sync_service_lifecycle

type lifecycle = State.lifecycle =
  | Running
  | Closing
  | Closed

type status =
  { lifecycle : lifecycle
  ; observation : Execute.runtime_observation
  }

exception Stop_service

type close_result = (unit, error option * (exn * Printexc.raw_backtrace) option) result

type t =
  { runtime : Execute.t
  ; sw : Eio.Switch.t
  ; mutable network_join : Execute.network_retirement option
  ; mutable control_failure : error option
  ; mutable control_cause : (exn * Printexc.raw_backtrace) option
  ; callback_key : unit Eio.Fiber.key
  ; resolve_stop : unit Eio.Promise.u
  ; finished : close_result Eio.Promise.t
  ; mutable state : State.t
  }

let set_network t gate =
  if State.lifecycle t.state <> Running
  then Error Dsl.Stale_context
  else (
    match gate with
    | Dsl.Closed ->
      (match Execute.close_network t.runtime with
       | Error error -> Error error
       | Ok retirement ->
         (match t.network_join with
          | Some _ -> ()
          | None ->
            t.network_join <- Some retirement;
            Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
              (match Execute.await_network_retirement retirement with
               | Ok () -> ()
               | Error error ->
                 t.control_failure <- Some error;
                 ignore (Eio.Promise.try_resolve t.resolve_stop () : bool));
              `Stop_daemon));
         Ok ())
    | Dsl.Open { authorization_epoch } ->
      let joined =
        match t.network_join with
        | None -> Ok ()
        | Some retirement -> Execute.await_network_retirement retirement
      in
      (match joined with
       | Error error -> Error error
       | Ok () when State.lifecycle t.state <> Running -> Error Dsl.Stale_context
       | Ok () ->
         (match Execute.open_network t.runtime ~authorization_epoch with
          | Error error -> Error error
          | Ok () ->
            t.network_join <- None;
            Ok ())))
;;

let close t =
  match
    State.request_close
      ~inside_callback:(Option.is_some (Eio.Fiber.get t.callback_key))
      t.state
  with
  | Error State.Reentrant -> raise Reentrant_close
  | Error State.Already_called -> raise Close_already_called
  | Ok state ->
    t.state <- state;
    Eio.Cancel.protect (fun () ->
      (try
         match Execute.close_network t.runtime with
         | Ok _ -> ()
         | Error error -> t.control_failure <- Some error
       with
       | exn -> t.control_cause <- Some (exn, Printexc.get_raw_backtrace ()));
      ignore (Eio.Promise.try_resolve t.resolve_stop () : bool));
    (match Eio.Promise.await t.finished with
     | Ok () -> ()
     | Error (error, cause) -> raise (Close_failed { error; cause }))
;;

let retirement : type state. state Dsl.phase -> (state, Dsl.retired, unit) Dsl.program =
  fun phase ->
  let finish () =
    Dsl.perform Dsl.finish_retirement ~success:Dsl.return ~failure:Dsl.abort
  in
  match phase with
  | Dsl.Retired -> Dsl.return ()
  | Dsl.Cold ->
    Dsl.perform (Dsl.begin_drain Dsl.Cold_context) ~success:finish ~failure:Dsl.abort
  | Dsl.Ready ->
    Dsl.perform (Dsl.begin_drain Dsl.Ready_context) ~success:finish ~failure:Dsl.abort
  | Dsl.Draining ->
    Dsl.perform (Dsl.begin_drain Dsl.Draining_context) ~success:finish ~failure:Dsl.abort
;;

let start ~sw ~config ~dependencies ~on_change =
  match
    Execute.create
      ~sw
      ~clock:dependencies.clock
      ~database_owner:dependencies.database_owner
      ~identity:config.identity
      ~limits:config.limits
      dependencies.capabilities
  with
  | Error error -> Error error
  | Ok (runtime, cold) ->
    let stop, resolve_stop = Eio.Promise.create () in
    let finished, resolve_finished = Eio.Promise.create () in
    let t =
      { runtime
      ; sw
      ; network_join = None
      ; control_failure = None
      ; control_cause = None
      ; callback_key = Eio.Fiber.create_key ()
      ; resolve_stop
      ; finished
      ; state = State.initial
      }
    in
    let context = ref (Execute.Context (Dsl.Cold, cold)) in
    let cancel_running = ref None in
    let failure = ref None in
    let record_error error =
      failure
      := Some
           (match !failure with
            | None -> error
            | Some primary ->
              Dsl.Cleanup_failure
                { primary = Some primary; failures = Rrbvec.of_list [ error ] })
    in
    let callback_failed = ref false in
    let invoke_callback callback =
      try Eio.Fiber.with_binding t.callback_key () callback with
      | exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        callback_failed := true;
        Printexc.raise_with_backtrace exn backtrace
    in
    let callback observation =
      invoke_callback (fun () ->
        on_change { lifecycle = State.lifecycle t.state; observation })
    in
    let install_outcome
      : type state value. state Dsl.phase -> (state, value) Execute.outcome -> unit
      =
      fun phase -> function
        | Execute.Completed (next, _) -> context := Execute.Context (phase, next)
        | Execute.Failed (next, error) ->
          context := next;
          (match State.lifecycle t.state, error with
           | Closing, Dsl.Cancelled -> ()
           | (Running | Closing | Closed), _ -> record_error error)
    in
    let observed, resolve_observed = Eio.Promise.create () in
    let observe () =
      match Execute.observe_runtime runtime with
      | Error error ->
        record_error error;
        raise Stop_service
      | Ok initial ->
        callback initial;
        Eio.Promise.resolve resolve_observed ();
        let rec loop previous =
          match Execute.await_observation runtime ~after:previous.Execute.revision with
          | Error error ->
            record_error error;
            raise Stop_service
          | Ok observation ->
            callback observation;
            loop observation
        in
        loop initial
    in
    let policy () =
      Eio.Promise.await observed;
      if State.lifecycle t.state = Running
      then (
        let program = Dsl.sync_policy config.policy ~initial_network:config.network in
        match Execute.start runtime cold program with
        | Error error ->
          record_error error;
          raise Stop_service
        | Ok running ->
          cancel_running
          := Some
               (fun () ->
                 (match Execute.cancel runtime running with
                  | Ok () | Error Dsl.Stale_context -> ()
                  | Error error -> record_error error);
                 install_outcome Dsl.Ready (Execute.await running));
          install_outcome Dsl.Ready (Execute.await running);
          cancel_running := None;
          (match !failure with
           | None -> ()
           | Some _ -> raise Stop_service));
      Eio.Promise.await stop
    in
    let cleanup () =
      t.state <- State.begin_cleanup t.state;
      (match !cancel_running with
       | None -> ()
       | Some cancel -> cancel ());
      (match t.control_failure with
       | None -> ()
       | Some error -> record_error error);
      let (Execute.Context (phase, current)) = !context in
      match Execute.start runtime current (retirement phase) with
      | Error error -> record_error error
      | Ok running -> install_outcome Dsl.Retired (Execute.await running)
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let cause =
        try
          Eio.Fiber.yield ();
          invoke_callback (fun () ->
            dependencies.bind_ingress
              { outbox_committed =
                  (fun ~owner ~identity ->
                    Execute.notify_outbox_changed runtime ~owner ~identity)
              ; submit_unlock =
                  (fun ~identity ~valid_for input ->
                    Execute.submit_unlock runtime ~identity ~valid_for input)
              ; update_demand = Execute.update_demand runtime
              ; receive_demand = (fun () -> Execute.receive_demand runtime)
              ; demand_status = Execute.demand_status runtime
              ; release_demand = Execute.release_demand runtime
              });
          Eio.Fiber.first
            (fun () -> Eio.Fiber.both observe policy)
            (fun () -> Eio.Promise.await stop);
          None
        with
        | Stop_service -> None
        | exn -> Some (exn, Printexc.get_raw_backtrace ())
      in
      Eio.Cancel.protect (fun () ->
        let cause =
          try
            cleanup ();
            cause
          with
          | exn ->
            let cleanup_cause = exn, Printexc.get_raw_backtrace () in
            (match cause with
             | None -> Some cleanup_cause
             | Some original -> Some (Eio.Exn.combine original cleanup_cause))
        in
        let cause =
          match cause, t.control_cause with
          | None, cause | cause, None -> cause
          | Some primary, Some control -> Some (Eio.Exn.combine primary control)
        in
        let cause =
          match !failure, cause with
          | None, None ->
            (try
               t.state <- State.complete t.state;
               (match Execute.observe_runtime runtime with
                | Ok observation -> callback observation
                | Error error ->
                  t.state <- State.begin_cleanup t.state;
                  record_error error);
               None
             with
             | exn ->
               t.state <- State.begin_cleanup t.state;
               Some (exn, Printexc.get_raw_backtrace ()))
          | _, cause -> cause
        in
        match !failure, cause with
        | None, None -> Eio.Promise.resolve resolve_finished (Ok ())
        | error, cause ->
          Eio.Promise.resolve resolve_finished (Error (error, cause));
          (match cause with
           | Some (exn, backtrace) when !callback_failed ->
             Printexc.raise_with_backtrace exn backtrace
           | Some _ | None -> ()));
      `Stop_daemon);
    Ok t
;;
