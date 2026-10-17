type send_result =
  | Accepted
  | Full
  | Not_ready
  | Stopping

type delivery =
  { responses : Journal_graph_runtime.response list
  ; error : string option
  }

let error_message = function
  | Accepted -> None
  | Full -> Some "Worker request queue is full"
  | Not_ready -> Some "Worker is not ready"
  | Stopping -> Some "Worker is stopping"
;;

let deliver ~runtime ~send (output : Journal_graph_runtime.output) =
  let responses = ref (Rrbvec.of_list output.responses) in
  let retire_unsent message requests =
    let pending = Queue.create () in
    List.iter (fun request -> Queue.push request pending) requests;
    while not (Queue.is_empty pending) do
      let request = Queue.pop pending in
      let retired = Journal_graph_runtime.fail_request runtime request ~message in
      responses := Rrbvec.append_list !responses retired.responses;
      (* A failed completion can release queued work. It is still unsent and
         must be settled, not retried against the refusing Worker. *)
      List.iter (fun request -> Queue.push request pending) retired.requests
    done
  in
  let rec send_pending = function
    | [] -> None
    | request :: rest ->
      (match send request with
       | Accepted -> send_pending rest
       | (Full | Not_ready | Stopping) as result ->
         let message = Option.get (error_message result) in
         retire_unsent message (request :: rest);
         Some message)
  in
  let error = send_pending output.requests in
  { responses = Rrbvec.to_list !responses; error }
;;
