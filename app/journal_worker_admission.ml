module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Worker = Logseq_db_worker_lui.Journal_worker
module Id = Logseq_db_worker_lui.Journal_worker_ids.Worker
module Protocol = Logseq_db_worker.Protocol

type graph_owner = int * Logseq_db_types.Graph_types.Uuid.t * int

let graph_owner = Option.map (fun (scope:Service.timeline_scope)->
  scope.startup.account_generation,scope.graph_id,scope.graph_generation)

type lease =
  { scope : Service.timeline_scope option
  ; protocol_request : Protocol.request
  ; mutable retired : bool
  }

type t =
  { send : Service.request -> Worker.send_result
  ; cancel : Id.request_id -> unit
  ; projection_accepted : Protocol.request -> unit
  ; projection_finished : Logseq_db_types.Graph_types.Uuid.t -> unit
  ; refused : Service.request -> Worker.send_result -> unit
  ; graph_requests : (Id.request_id, lease) Hashtbl.t
  ; protocol_ids : (graph_owner option * Logseq_db_types.Graph_types.Uuid.t, Id.request_id) Hashtbl.t
  }

let create ~send ~cancel ~projection_accepted ~projection_finished ~refused =
  { send; cancel; projection_accepted; projection_finished; refused
  ; graph_requests = Hashtbl.create 32
  ; protocol_ids = Hashtbl.create 32
  }
;;

let dispatch owner ?(observe_projection = false) (request : Service.request) =
  let protocol = match request with
    | Graph_request request | Graph_request_at (_,request) -> Some request
    | _ -> None in
  let scope=match request with Service.Graph_request_at(scope,_) -> Some scope | _->None in
  let protocol_key id=graph_owner scope,id in
  let duplicate = Option.fold ~none:false ~some:(fun request ->
    Hashtbl.mem owner.protocol_ids (protocol_key request.Protocol.request_id)) protocol in
  if duplicate then Worker.Full
  else match owner.send request with
    | Accepted worker_id as accepted ->
      Option.iter (fun protocol ->
        Hashtbl.add owner.graph_requests worker_id {scope=(match request with Service.Graph_request_at (scope,_) -> Some scope | _ -> None);protocol_request=protocol;retired=false};
        Hashtbl.add owner.protocol_ids (protocol_key protocol.Protocol.request_id) worker_id;
        if observe_projection then owner.projection_accepted protocol) protocol;
      accepted
    | (Full | Not_ready | Stopping) as refused ->
      owner.refused request refused;
      refused
;;

let retire owner worker_id =
  match Hashtbl.find_opt owner.graph_requests worker_id with
  | None -> false
  | Some lease ->
    let protocol_id = lease.protocol_request.request_id in
    let key=graph_owner lease.scope,protocol_id in
    if Hashtbl.find_opt owner.protocol_ids key = Some worker_id then
      Hashtbl.remove owner.protocol_ids key;
    Hashtbl.remove owner.graph_requests worker_id;
    lease.retired
;;

let cancel_graph_leases owner =
  Hashtbl.iter (fun worker_id lease ->
    if not lease.retired then (
      lease.retired <- true;
      owner.projection_finished lease.protocol_request.request_id;
      owner.cancel worker_id)) owner.graph_requests;
  Hashtbl.clear owner.protocol_ids
;;

let cancel_graph_scope owner scope =
  Hashtbl.iter (fun worker_id lease ->
    if graph_owner lease.scope=graph_owner scope && not lease.retired then (
      lease.retired<-true;owner.projection_finished lease.protocol_request.request_id;
      Hashtbl.remove owner.protocol_ids (graph_owner lease.scope,lease.protocol_request.request_id);owner.cancel worker_id)) owner.graph_requests
;;
