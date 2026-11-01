module Worker = Journal_worker_coordination.Worker_api
module Core = Journal_worker_coordination.Worker_pure_coordinator
module Runner = Journal_worker_coordination.Worker_effect_runner

type t =
  { state : Core.t ref
  ; runner : Runner.t
  ; enqueue : (unit -> unit) -> unit
  }

let apply state runner transition =
  state := transition.Core.next;
  List.iter (Runner.submit runner) transition.instructions
;;

let create ~client ~client_id ~managed_origin ~user_id ~enqueue ~changed =
  let state = ref (Core.initial ~client_id)
  and runner = ref None in
  let post event =
    enqueue (fun () ->
      Option.iter (fun runner -> apply state runner (Core.step !state event)) !runner)
  in
  Runner.create ~client ~managed_origin ~user_id ~post ~publish:(fun view ->
    enqueue (fun () -> changed view))
  |> Result.map (fun value ->
    runner := Some value;
    { state; runner = value; enqueue })
;;

let view host = Core.view !(host.state)

let request host session operation =
  Core.request !(host.state) session operation
  |> Result.map (fun (ticket, transition) ->
    apply host.state host.runner transition;
    ticket)
;;

let post host event =
  host.enqueue (fun () -> apply host.state host.runner (Core.step !(host.state) event))
;;

let on_event host event = Runner.on_event host.runner event
let shutdown host = Runner.shutdown host.runner
