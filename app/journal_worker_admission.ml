module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Worker = Logseq_db_worker_lui.Journal_worker
module Id = Logseq_db_worker_lui.Journal_worker_ids.Worker
module Runtime = Logseq_db_worker_lui.Journal_worker_ids.Runtime

type t =
  { runtime_epoch : Runtime.epoch
  ; worker_generation : Id.generation
  ; responses : (Id.request_id, unit) Hashtbl.t
  ; send : Service.request -> Worker.send_result
  ; refused : Service.request -> Worker.send_result -> unit
  }

let create ~runtime_epoch ~worker_generation ~send ~refused =
  {runtime_epoch;worker_generation;responses=Hashtbl.create 64;send;refused}
;;

type delivery = Registered_response | Unowned_response | Broadcast | Dropped_envelope

let receive owner event =
  let runtime_epoch, worker_generation = match event with
    | Worker.Response {runtime_epoch;worker_generation;_}
    | Push {runtime_epoch;worker_generation;_}
    | Terminal {runtime_epoch;worker_generation;_} -> runtime_epoch,worker_generation in
  if not (Runtime.Epoch.equal owner.runtime_epoch runtime_epoch)
     || not (Id.Generation.equal owner.worker_generation worker_generation)
  then Dropped_envelope
  else match event with
    | Worker.Response {request_id;_} ->
      if Hashtbl.mem owner.responses request_id then (
        Hashtbl.remove owner.responses request_id;
        Registered_response)
      else Unowned_response
    | Push _ | Terminal _ -> Broadcast
;;

let dispatch owner request =
  match owner.send request with
  | Worker.Accepted id as accepted->Hashtbl.add owner.responses id ();accepted
  | refused->owner.refused request refused;refused
;;
