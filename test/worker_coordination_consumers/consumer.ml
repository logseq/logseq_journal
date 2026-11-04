(* Compile-only clients using the actual App projection. No runtime implementation is linked. *)
module W = Journal_worker_coordination.Worker_api
module C = Journal_worker_coordination.Worker_pure_coordinator
let request (session,operation) state = Result.map snd (C.request state session operation)

module Client_bootstrap_query_projection_and_release = struct

module R = Journal_worker_coordination.Worker_effect_runner
module Projection = Journal_graph_projection
let start client managed_origin user_id publish enqueue =
  let post event = enqueue event in
  R.create ~client ~managed_origin ~user_id ~post ~publish
let first_request event day =
  match event with
  | C.Bootstrap_received (_,W.Ready projection) ->
    (match W.residents projection with
     | [] -> `No_graph
     | resident::_ ->
       let session = resident.W.session in
       (match W.read_budget session ~maximum_items:20 ~maximum_bytes:65536 with
        | Error error -> `Error error
        | Ok budget -> `Request (request(session,W.Query(budget,W.Journal day)))))
  | C.Bootstrap_received (_,(W.Awaiting_baseline | W.Bootstrap_not_ready _)) -> `Wait
  | C.Bootstrap_received (_,(W.Bootstrap_failed error | W.Binding_revoked error)) -> `Error error
  | _ -> `Other
let project time_context ~child_count page block =
  Projection.block_on_page ~page:(W.page_data page) ~revision:(W.block_revision block)
    ~child_count ~time_context (W.block_data block).Worker_pure_data.block
let observe session budget day = request(session,W.Observe(budget,W.Journal day))
let end_observation (observed : W.page option W.observed) = C.Release observed.observation
let start_typed state session budget day =
  match C.request state session (W.Query(budget,W.Journal day)) with
  | Error error -> `Error error
  | Ok(ticket,transition) ->
    let typed : W.page option C.ticket = ticket in
    `Pending(typed,transition)
let retry_bootstrap = C.Retry_bootstrap
end

module All_read_families_and_current_projection_consumers = struct

module Projection = Journal_graph_projection
let queries session budget uuid day = [
  request(session,W.Query(budget,W.Graph_info));
  request(session,W.Query(budget,W.Admission));
  request(session,W.Query(budget,W.Journals {from_day=day;through_day=day;revision=None;after=None}));
  request(session,W.Query(budget,W.Page {uuid;revision=None}));
  request(session,W.Query(budget,W.Outline_block {uuid;revision=None}));
  request(session,W.Query(budget,W.Block_summary {block=uuid;after=None}));
  request(session,W.Query(budget,W.Tree {page=uuid;maximum_depth=0;revision=None;after=None}));
  request(session,W.Query(budget,W.Favorites None));
  request(session,W.Query(budget,W.Task_statuses None));
  request(session,W.Query(budget,W.Task_status_definitions [uuid]));
  request(session,W.Query(budget,W.Asset_descriptors [uuid]));
  request(session,W.Query(budget,W.Assets {recursive=true;roots=[uuid];after=None}));
  request(session,W.Query(budget,W.Changes {generation="generation";after=None}))]
let favorite (result : W.favorites) = List.map Projection.favorite result.items
let summary time_context (result : W.block_summary) =
  match result.next with
  | Some after -> `More after
  | None ->
    (match result.lookup,result.page with
     | Worker_pure_data.V2_present_block {value;revision},Some(Worker_pure_data.V2_present_page {page;_}) ->
       `Complete(Some(Projection.block_on_page ~page ~revision
         ~child_count:(List.length result.items) ~time_context value.block))
     | _ -> `Complete None)
let confirmed time_context confirmation =
  match W.confirmation_primary confirmation with
  | W.Confirmed_block readback -> `Block (summary time_context readback)
  | W.Confirmed_page page -> `Page page
  | W.Confirmed_absence {uuid;revision;generation;projection_revision} ->
    `Deleted(uuid,revision,generation,projection_revision)
let child (member : Worker_pure_data.child_member) : Projection.block_member =
  {block=member.value.block;revision=member.revision}
let tree (member : Worker_pure_data.tree_member) : Projection.tree_member =
  {block=member.value.block;revision=member.revision;depth=member.depth}
let next (result : Worker_pure_data.tree_member W.slice) : Worker_pure_data.tree_member W.continuation option = result.W.next
let ack session batch = request(session,W.Acknowledge_changes batch)
end

module Client_to_projection_observation_write_and_cleanup = struct

module R = Journal_worker_coordination.Worker_effect_runner
module Projection = Journal_graph_projection
type pending =
  | Idle
  | Page of W.page option C.ticket
  | Children of W.page * W.block W.slice C.ticket
  | Summary of W.block_summary C.ticket
  | Observe of W.page option W.observed C.ticket
  | Write of W.mutation_progress C.ticket
  | Confirm of W.mutation_progress C.ticket
  | Releasing of unit C.ticket
  | Finished
type rendering =
  | Rows of (Projection.block,string) result list
  | Partial of W.block_summary
type client = {
  mutable core:C.t; mutable runner:R.t option; events:C.event Queue.t;
  mutable active:(W.session * W.read_budget) option;
  mutable pending:pending; mutable observation:W.page option W.observation option;
  day:W.journal_day; mutation_id:W.Uuid.t; block_id:W.Uuid.t;
  save:bytes -> unit; render:rendering -> unit;
  time_context:Projection.time_context;
}
let apply t (transition:C.transition) =
  t.core <- transition.next;
  Option.iter (fun runner -> List.iter (R.submit runner) transition.instructions) t.runner
let plan (type a) t session (operation:a W.request) (stage:a C.ticket -> pending) =
  match C.request t.core session operation with
  | Error _ -> t.pending <- Finished
  | Ok(ticket,transition) -> t.pending <- stage ticket; apply t transition
let release t session =
  match t.observation with
  | None -> t.pending <- Finished
  | Some handle -> plan t session (W.Release handle) (fun ticket -> Releasing ticket)
let observe t session budget = plan t session (W.Observe(budget,W.Journal t.day))
    (fun ticket -> Observe ticket)
let forget t ticket = apply t (C.step t.core (C.Forget ticket))
let advance t =
  let view = C.view t.core in
  match t.active,t.pending with
  | None,Idle ->
    (match C.bootstrap view with
     | W.Ready projection ->
       (match List.find_opt(fun resident -> resident.W.phase=W.Open) (W.residents projection) with
        | None -> ()
        | Some resident ->
          (match W.read_budget resident.session ~maximum_items:20 ~maximum_bytes:65536 with
           | Error _ -> t.pending <- Finished
           | Ok budget -> t.active <- Some(resident.session,budget);
             plan t resident.session (W.Query(budget,W.Journal t.day)) (fun ticket -> Page ticket)))
     | W.Awaiting_baseline | W.Bootstrap_not_ready _ -> ()
     | W.Bootstrap_failed _ | W.Binding_revoked _ -> t.pending <- Finished)
  | Some(session,budget),Page ticket ->
    (match C.reply view ticket with
     | Some(W.Answered(Ok(Some page))) -> forget t ticket;
       plan t session (W.Query(budget,W.Children{parent=W.page_uuid page;after=None}))
         (fun ticket -> Children(page,ticket))
     | Some(W.Answered(Ok None)) -> forget t ticket; observe t session budget
     | Some _ -> forget t ticket; release t session
     | None -> ())
  | Some(session,budget),Children(_page,ticket) ->
    (match C.reply view ticket with
     | Some(W.Answered(Ok slice)) ->
       forget t ticket;
       (match slice.items with
        | [] -> t.render(Rows []); observe t session budget
        | block::_ ->
          plan t session (W.Query(budget,W.Block_summary{block=W.block_uuid block;after=None}))
            (fun ticket -> Summary ticket))
     | Some _ -> forget t ticket; release t session
     | None -> ())
  | Some(session,budget),Summary ticket ->
    (match C.reply view ticket with
     | Some(W.Answered(Ok summary)) ->
       (match summary.next with
        | Some _ -> t.render(Partial summary)
        | None ->
          (match summary.lookup,summary.page with
           | Worker_pure_data.V2_present_block{value;revision},Some(Worker_pure_data.V2_present_page{page;_}) ->
             t.render(Rows[Projection.block_on_page ~page ~revision
               ~child_count:(List.length summary.items) ~time_context:t.time_context value.block])
           | _ -> t.render(Rows [])));
       forget t ticket; observe t session budget
     | Some _ -> forget t ticket; release t session
     | None -> ())
  | Some(session,_),Observe ticket ->
    (match C.reply view ticket with
     | Some(W.Answered(Ok value)) -> t.observation <- Some value.observation;
       forget t ticket;
       (match W.append_intent session ~mutation_id:t.mutation_id ~block_id:t.block_id
           ~day:t.day ~title:"synthetic" ~task_status:None ~children:Rrbvec.empty with
        | Error _ -> release t session
        | Ok intent -> t.save(W.encode_durable_intent(W.Append_intent intent));
          plan t session (W.Append intent) (fun ticket -> Write ticket))
     | Some _ -> forget t ticket; release t session
     | None -> ())
  | Some(session,_),Write ticket ->
    (match C.reply view ticket with
     | Some(W.Answered(Ok(W.Committed_pending_presentation receipt))) ->
       forget t ticket;
       (match Option.bind (C.projection view) W.selected with
        | None -> release t session
        | Some presentation -> plan t session (W.Confirm(presentation,receipt)) (fun ticket -> Confirm ticket))
     | Some _ -> forget t ticket; release t session
     | None -> ())
  | Some(session,_),Confirm ticket ->
    (match C.reply view ticket with Some _ -> forget t ticket; release t session | None -> ())
  | Some _,Releasing ticket ->
    (match C.reply view ticket with
     | Some(W.Answered(Ok())) -> forget t ticket; t.observation <- None; t.pending <- Finished
     | Some _ | None -> ())
  | _ -> ()
let start client managed_origin user_id client_id day mutation_id block_id save render time_context =
  let t = {core=C.initial ~client_id;runner=None;events=Queue.create();active=None;
    pending=Idle;observation=None;day;mutation_id;block_id;save;render;time_context} in
  Result.map(fun runner -> t.runner <- Some runner; t)
    (R.create ~client ~managed_origin ~user_id ~post:(fun event -> Queue.add event t.events)
       ~publish:(fun _ -> ()))
let turn t =
  if not(Queue.is_empty t.events) then (
    let event=Queue.take t.events in apply t (C.step t.core event); advance t)
let incoming t event = match t.runner with
  | None -> None | Some runner -> Some(R.on_event runner event)
let stop t = Option.map R.shutdown t.runner
end
