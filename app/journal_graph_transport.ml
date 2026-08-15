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
  let rec send_pending = function
    | [] -> None
    | request :: rest ->
      (match send request with
       | Accepted -> send_pending rest
       | (Full | Not_ready | Stopping) as result ->
         List.iter (Journal_graph_runtime.abandon runtime) (request :: rest);
         error_message result)
  in
  { responses = output.responses; error = send_pending output.requests }
;;
