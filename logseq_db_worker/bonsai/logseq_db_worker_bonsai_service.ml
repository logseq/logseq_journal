module Protocol = Logseq_db_worker.Protocol
module Engine = Logseq_db_worker.Engine
module ID = Bonsai_flutter_spec.Id

type state =
  | Ready of
      { engine : Engine.t
      ; invalidations : invalidation_dispatcher
      }
  | Open_failed of Logseq_db_worker.Error.t

and invalidation_dispatcher =
  { wake : Eio.Condition.t
  ; mutable pending : Protocol.push option
  }

let random_key () =
  let channel = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel 32 |> Bytes.of_string)
;;

let production_dependencies () =
  Engine.
    { clocks =
        { epoch_ms = (fun () -> Unix.gettimeofday () *. 1_000. |> Int64.of_float)
        ; monotonic_ns = Mtime_clock.elapsed_ns
        }
    ; cursor_authentication_key = random_key ()
    }
;;

let take count values =
  let rec loop remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop count [] values
;;

let invalidation (success : Protocol.mutation_success) =
  let rec fit limit =
    let changed_uuids = take limit success.Protocol.changed_uuids in
    let push =
      Protocol.Graph_invalidated
        { basis = success.basis_after
        ; changed_uuids
        ; changed_uuids_truncated =
            success.changed_uuids_truncated
            || List.length changed_uuids < List.length success.changed_uuids
        ; invalidate_graph_info = true
        ; invalidate_pages = true
        ; invalidate_tags = true
        ; invalidate_properties = true
        ; invalidate_tasks = true
        ; invalidate_references = true
        }
    in
    let bytes = Protocol.push_to_yojson push |> Yojson.Safe.to_string |> String.length in
    if bytes <= Protocol.maximum_push_bytes
    then push
    else if limit = 0
    then failwith "logseq-db-worker invalidation metadata exceeds its protocol budget"
    else fit (limit / 2)
  in
  fit (List.length success.changed_uuids)
;;

let invalidation_topic = ID.Worker.Push_topic.of_int 0

let enqueue_invalidation dispatcher push =
  dispatcher.pending <- Some push;
  Eio.Condition.broadcast dispatcher.wake
;;

let rec dispatch_invalidations context dispatcher =
  let push =
    Eio.Condition.loop_no_mutex dispatcher.wake (fun () ->
      match dispatcher.pending with
      | None -> None
      | Some push ->
        dispatcher.pending <- None;
        Some push)
  in
  Worker.Session_context.emit context ~topic:invalidation_topic push;
  dispatch_invalidations context dispatcher
;;

let create_with_dependencies dependencies =
  Worker.Service.create
    ~push_topic_count:1
    ~concurrency:Worker.Service.Serial
    ~data_directory:(fun config ->
      Ok config.Logseq_db_worker.Config.application_support_directory)
    ~init:(fun context config ->
      match Worker.Session_context.data_dir context with
      | None -> Error "application-support data directory capability is unavailable"
      | Some _directory ->
        (match Engine.open_ ~dependencies:(dependencies ()) config with
         | Ok engine ->
           let invalidations = { wake = Eio.Condition.create (); pending = None } in
           Worker.Session_context.fork_daemon
             context
             ~name:"logseq-db-worker-invalidations"
             (fun () -> dispatch_invalidations context invalidations);
           Ok (Ready { engine; invalidations })
         | Error error -> Ok (Open_failed error)))
    ~handle:(fun _context state (request : Protocol.request) ->
      match state with
      | Open_failed error ->
        Ok
          (Protocol.failed
             ~request_id:request.Protocol.request_id
             ~phase:Open
             ~basis:None
             error)
      | Ready { engine; invalidations } ->
        let response = Engine.execute engine request in
        (match response with
         | Protocol.Succeeded
             { success = Mutation_result ({ status = Applied; _ } as success); _ } ->
           enqueue_invalidation invalidations (invalidation success)
         | Succeeded _ | Failed _ -> ());
        Ok response)
    ~shutdown:(function
      | Open_failed _ -> ()
      | Ready { engine; _ } ->
        (match Engine.close engine with
         | Ok () -> ()
         | Error message -> failwith ("logseq-db-worker close failed: " ^ message)))
    ()
;;

let create ~dependencies = create_with_dependencies (fun () -> dependencies)
let service = create_with_dependencies production_dependencies
