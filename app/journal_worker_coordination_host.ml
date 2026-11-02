module Worker = Journal_worker_coordination.Worker_api
module Core = Journal_worker_coordination.Worker_pure_coordinator
module Runner = Journal_worker_coordination.Worker_effect_runner

type watch =
  | Watch :
      'a Core.ticket
      * ((Worker.session * Worker.read_budget) option -> 'a Worker.reply -> unit)
      -> watch

type t =
  { state : Core.t ref
  ; runner : Runner.t
  ; enqueue : (unit -> unit) -> unit
  ; watches : watch Rrbvec.t ref
  }

let apply state runner transition =
  state := transition.Core.next;
  List.iter (Runner.submit runner) transition.instructions
;;

let flush host =
  let view = Core.view !(host.state) in
  let callbacks = ref [] in
  host.watches
  := Rrbvec.fold_left
       (fun retained (Watch (ticket, callback) as watch) ->
          match Core.reply view ticket with
          | None -> Rrbvec.push_back retained watch
          | Some result ->
            let origin = Core.query_origin view ticket in
            host.enqueue (fun () ->
              apply host.state host.runner (Core.step !(host.state) (Core.Forget ticket)));
            callbacks := (fun () -> callback origin result) :: !callbacks;
            retained)
       Rrbvec.empty
       !(host.watches);
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
      Option.iter flush !host;
      changed view))
  |> Result.map (fun value ->
    runner := Some value;
    let value = { state; runner = value; enqueue; watches = ref Rrbvec.empty } in
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

let validate_session ?owner host session =
  Core.validate_session ?owner !(host.state) session
;;

let watch_read host ticket ~f =
  host.watches := Rrbvec.push_back !(host.watches) (Watch (ticket, f));
  host.enqueue (fun () -> flush host)
;;

let watch host ticket ~f = watch_read host ticket ~f:(fun _ result -> f result)

let query_point host ~owner ~maximum_bytes command ~f =
  let module P = Logseq_db_worker.Protocol in
  let submit
    : type a. a Worker.query -> (a -> P.v2_outcome) -> (bool, Worker.error) result
    =
    fun query outcome ->
    Core.plan_query_when_available
      !(host.state)
      ~owner
      ~maximum_items:1
      ~maximum_bytes
      query
    |> Result.map (fun (ticket, transition) ->
      apply host.state host.runner transition;
      watch_read host ticket ~f:(fun origin reply ->
        let result =
          match reply with
          | Worker.Answered (Ok value) -> Ok (outcome value)
          | Answered (Error error) -> Error error
          | Not_admitted _ ->
            Error (Worker.Service_failed "The dependency read was not admitted")
          | Interrupted _ ->
            Error (Worker.Service_failed "The dependency read was interrupted")
        in
        f origin result);
      true)
  in
  match command with
  | P.V2_get_outline_block { block; revision } ->
    submit
      (Worker.Outline_block { uuid = block; revision })
      (fun value -> P.V2_block_outcome value)
  | V2_get_page { page; revision } ->
    submit (Worker.Page { uuid = page; revision }) (fun value -> P.V2_page_outcome value)
  | _ -> Ok false
;;
