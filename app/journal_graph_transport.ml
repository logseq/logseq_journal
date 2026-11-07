type send_result =
  | Accepted
  | Full
  | Not_ready
  | Stopping
  | Refused of Logseq_db_worker.Error.t

type delivery =
  { responses : Journal_graph_runtime.response list
  ; error : string option
  }

let error_message = function
  | Accepted -> None
  | Full -> Some "Worker request queue is full"
  | Not_ready -> Some "Worker is not ready"
  | Stopping -> Some "Worker is stopping"
  | Refused error -> Some(Logseq_db_worker.Error.message error)
;;

let deliver ~runtime ~send (output : Journal_graph_runtime.output) =
  let responses = ref (Rrbvec.of_list output.responses) in
  let retire_unsent error message requests =
    let fatal = ref false in
    let pending = Queue.create () in
    List.iter (fun request -> Queue.push request pending) requests;
    while not (Queue.is_empty pending) do
      let request = Queue.pop pending in
      let retired = Journal_graph_runtime.fail_request ~error runtime request ~message in
      responses := Rrbvec.append_list !responses retired.responses;
      (* Owned durable business failures retain their retry obligation. A
         refusal of any other work still reports a transport failure. *)
      let business_responses=List.filter(fun response->match response.Journal_graph_runtime.payload with
        | Diagnostic _->false | _->true) retired.responses in
      if (business_responses=[] && retired.requests=[]) || not(List.for_all(fun response->
        match response.Journal_graph_runtime.payload with
        | Child_waiting _ | Capture_waiting _ | Mutation_waiting _
        | Child_not_admitted _ | Capture_not_admitted _ -> true
        | _ -> false) business_responses) then fatal:=true;
      (* A failed completion can release queued work. It is still unsent and
         must be settled, not retried against the refusing Worker. *)
      List.iter (fun request -> Queue.push request pending) retired.requests
    done;
    !fatal
  in
  let rec send_pending = function
    | [] -> None
    | request :: rest ->
      (match send request with
       | Accepted -> send_pending rest
       | (Full | Not_ready | Stopping | Refused _) as result ->
         let message = Option.get (error_message result) in
         let error=match result with
           |Refused error->error
           |_->let reason=match result with
             |Full->Journal_worker_coordination.Worker_api.Full
             |Not_ready->Not_ready |Stopping->Stopping |Accepted|Refused _->assert false in
             Journal_worker_coordination_host.admission_diagnostic reason in
         if retire_unsent error message (request :: rest) then Some message else None)
  in
  let error = send_pending output.requests in
  { responses = Rrbvec.to_list !responses; error }
;;
