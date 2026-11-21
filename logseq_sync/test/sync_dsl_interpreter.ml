module D = Sync_dsl.Core

type responder =
  { respond : 'a. D.scope -> 'a D.task_operation -> ('a, D.error) result option }

type region =
  { scope : D.scope
  ; mutable cancel : ((unit -> bool) * (unit -> unit)) list
  }

type engine =
  { owner : D.Producer.owner
  ; responder : responder
  ; input : unit -> D.service_input option
  ; mutable fibers : (unit -> bool) list
  ; mutable cancelling : bool
  ; admit : unit -> (unit, D.error) result
  }

type 'a fiber =
  { mutable result : ('a, D.error) result option
  ; mutable step : unit -> bool
  }

let rec fiber : type value. engine -> region -> value D.task -> value fiber =
  fun engine region task ->
  let fiber = { result = None; step = (fun () -> false) } in
  let finish result =
    fiber.result <- Some result;
    fiber.step <- (fun () -> false)
  in
  let rec run
    : type value. region -> value D.task -> (value -> unit) -> (D.error -> unit) -> unit
    =
    fun region task success failure ->
    fiber.step
    <- (fun () ->
         match D.task_view task with
         | D.Task_return value ->
           success value;
           true
         | D.Task_fail error ->
           failure error;
           true
         | D.Task_bind (first, continuation) ->
           run
             region
             first
             (fun value -> run region (continuation value) success failure)
             failure;
           true
         | D.Task_perform (operation, accepted, rejected) ->
           (match respond engine region operation with
            | None -> false
            | Some (Ok value) ->
              run region (accepted value) success failure;
              true
            | Some (Error error) ->
              run region (rejected error) success failure;
              true)
         | D.Task_scope body ->
           let nested = { scope = D.Producer.scope engine.owner; cancel = [] } in
           let close () =
             List.iter (fun (_, cancel) -> cancel ()) nested.cancel;
             ignore (D.Producer.close_scope engine.owner nested.scope)
           in
           run
             nested
             (body nested.scope)
             (fun value ->
                close ();
                success value)
             (fun error ->
                close ();
                failure error);
           true
         | D.Task_spawn (scope, body) ->
           success (spawn engine region scope body);
           true
         | D.Task_spawn_asset (scope, receipt, body) ->
           (match D.Producer.check_demand_receipt engine.owner scope receipt with
            | Error error -> success (Error error)
            | Ok () -> success (spawn engine region scope body));
           true
         | D.Task_join child ->
           (match D.Producer.child_result engine.owner region.scope child with
            | Error error ->
              failure error;
              true
            | Ok None -> false
            | Ok (Some result) ->
              ignore (D.Producer.forget_child engine.owner region.scope child);
              success result;
              true)
         | D.Task_cancel child ->
           engine.cancelling <- true;
           let result = D.Producer.child_result engine.owner region.scope child in
           engine.cancelling <- false;
           (match result with
            | Error error -> failure error
            | Ok _ -> success ());
           true)
  in
  run region task (fun value -> finish (Ok value)) (fun error -> finish (Error error));
  engine.fibers
  <- engine.fibers
     @ [ (fun () ->
           ignore (fiber.step ());
           fiber.result = None)
       ];
  fiber

and spawn
  : type value.
    engine -> region -> D.scope -> value D.task -> (value D.child, D.error) result
  =
  fun engine region scope task ->
  match D.Producer.check_scope engine.owner scope with
  | Error error -> Error error
  | Ok () when scope != region.scope -> Error D.Stale_context
  | Ok () ->
    (match engine.admit () with
     | Error error -> Error error
     | Ok () ->
       let running = fiber engine region task in
       let cancel () =
         if running.result = None
         then (
           running.result <- Some (Error D.Cancelled);
           running.step <- (fun () -> false))
       in
       region.cancel
       <- ((fun () -> running.result = None), cancel)
          :: List.filter (fun (active, _) -> active ()) region.cancel;
       D.Producer.child engine.owner scope task ~poll:(fun () ->
         if engine.cancelling then cancel ();
         running.result))

and respond
  : type value.
    engine -> region -> value D.task_operation -> (value, D.error) result option
  =
  fun engine region operation ->
  match operation with
  | D.Await_input_or_child children ->
    (match engine.input () with
     | Some input -> Some (Ok (D.Input input))
     | None ->
       let rec ready index =
         if index = Rrbvec.length children
         then None
         else (
           let child = Rrbvec.nth children index in
           match D.Producer.child_result engine.owner region.scope child with
           | Error error -> Some (Error error)
           | Ok None -> ready (index + 1)
           | Ok (Some _) -> Some (Ok (D.Child_ready child)))
       in
       ready 0)
  | D.Next_input -> Option.map (fun input -> Ok input) (engine.input ())
  | operation -> engine.responder.respond region.scope operation
;;

let run_task ?(admit = fun () -> Ok ()) ~identity ~responder ~input task =
  let owner = D.Producer.create identity in
  let engine =
    { owner; responder = responder owner; input; fibers = []; cancelling = false; admit }
  in
  let root = { scope = D.Producer.scope owner; cancel = [] } in
  let running = fiber engine root task in
  let rec drive remaining =
    match running.result with
    | Some result -> result
    | None when remaining = 0 ->
      Alcotest.fail "deterministic task interpreter exhausted its step budget"
    | None ->
      let scheduled = engine.fibers in
      engine.fibers <- [];
      let pending = List.filter (fun step -> step ()) scheduled in
      engine.fibers <- pending @ engine.fibers;
      drive (remaining - 1)
  in
  drive 200000
;;

type task_runner = { run_task : 'a. 'a D.task -> ('a, D.error) result }

let run_program
      ~(restore : unit -> (D.restore_report, D.error) result)
      ~(install : D.network_gate -> (unit, D.error) result)
      ~runner
      program
  =
  let dispatch
    : type before after failed value.
      (before, after, failed, value) D.operation -> (value, D.error) result
    = function
    | D.Restore -> restore ()
    | D.Install_initial_network network -> install network
    | D.Run_task task -> runner.run_task task
    | _ -> Alcotest.fail "unexpected policy lifecycle operation"
  in
  let rec run
    : type before after value. (before, after, value) D.program -> (value, D.error) result
    =
    fun program ->
    match D.view program with
    | D.Return value -> Ok value
    | D.Abort error -> Error error
    | D.Perform (operation, success, failure) ->
      let result = dispatch operation in
      (match result with
       | Ok value -> run (success value)
       | Error error -> run (failure error))
  in
  run program
;;
