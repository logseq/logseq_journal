module Config = Logseq_db_worker_contract.Config
module Error = Logseq_db_worker_contract.Error
module Protocol = Logseq_db_worker_contract.Protocol
module Engine = Logseq_db_worker_engine.Engine
module Pure_reducer = Logseq_db_worker_pure_reducer.Core
module Effect_runner = Logseq_db_worker_effect_runner.Effect_runner

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

type t =
  { state : Pure_reducer.state ref
  ; runner : Effect_runner.t
  ; events : Pure_reducer.event Eio.Stream.t
  ; mutable next_request_id : int64
  ; mutable stopped : bool
  }

type create_error = Invalid_create of string

let dispatch t event =
  let transition = Pure_reducer.step !(t.state) event in
  t.state := transition.next;
  List.iter (Effect_runner.submit t.runner) transition.effects
;;

let create ~sw ~config ~runner_dependencies =
  match Pure_reducer.initial config with
  | Error (Pure_reducer.Invalid_create message) -> Error (Invalid_create message)
  | Ok state ->
    let events = Eio.Stream.create 256 in
    (match
       Effect_runner.create ~sw runner_dependencies ~post:(fun event ->
         Eio.Stream.add events event)
     with
     | Error (Effect_runner.Invalid_create message) -> Error (Invalid_create message)
     | Ok runner ->
       let t =
         { state = ref state; runner; events; next_request_id = 0L; stopped = false }
       in
       dispatch t Pure_reducer.Start;
       Eio.Fiber.fork ~sw (fun () ->
         while not t.stopped do
           dispatch t (Eio.Stream.take events)
         done);
       Ok t)
;;

let post t event = if not t.stopped then Eio.Stream.add t.events event
let view t = Pure_reducer.view !(t.state)
let graph_state t = (view t).graph

let request t request =
  let id = Pure_reducer.request_id_of_int64 t.next_request_id in
  t.next_request_id <- Int64.succ t.next_request_id;
  Effect_runner.await_reply t.runner ~id ~request ~post:(fun () ->
    post t (Pure_reducer.Graph_request { id; request }))
;;

let shutdown t =
  if not t.stopped
  then (
    dispatch t Pure_reducer.Shutdown;
    t.stopped <- true;
    Eio.Stream.add t.events Pure_reducer.Shutdown;
    Effect_runner.shutdown t.runner)
;;
