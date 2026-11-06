module W = Journal_worker_coordination.Worker_api
module Read = Worker_pure_read
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Id = Journal_worker_ids
module Sync = Logseq_sync_pure_reducer.Core

let check condition message = if not condition then failwith message
let uuid s = W.Uuid.of_string s |> Result.get_ok
let graph = uuid "98000000-0000-4000-8000-000000000001"

let limits : Worker_pure_data.capability_limits =
  { response_budget_bytes = 65536
  ; outbox_max_records = 32
  ; outbox_max_bytes = 65536
  ; change_max_items = 32
  ; change_max_bytes = 65536
  ; dispatcher_capacity = 32
  ; wire_batch_max_bytes = 65536
  }
;;

let fixture ?(graph = graph) ?(graph_generation = 7) ?(limits = limits) epoch =
  let issuer =
    Worker_effect_authority.issuer
      ~managed_origin:"https://example.invalid"
      ~user_id:"synthetic"
      ~runtime_epoch:(Id.Runtime.Epoch.of_int64 epoch)
      ~worker_generation:Id.Worker.Generation.one
    |> Result.get_ok
  in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let registration =
    match I.bootstrap_request () with
    | Ok (S.Register_coordination id) -> id
    | _ -> assert false
  in
  let account : Sync.account_scope =
    { managed_sync_origin = Uri.of_string "https://example.invalid"
    ; user_id = "synthetic"
    ; account_generation = 1
    ; presentation_generation = 1
    ; lifecycle_generation = 1L
    }
  in
  let scope : Sync.graph_scope = { account; graph_id = graph; graph_generation } in
  let cfg =
    Sync.limits
      ~maximum_response_bytes:65536
      ~maximum_artifact_bytes:65536
      ~submission_batch_size:1
    |> Result.get_ok
    |> fun limits ->
    Sync.config ~managed_sync_origin:account.managed_sync_origin ~limits |> Result.get_ok
  in
  let state = Sync.initial cfg |> Result.get_ok |> Sync.state in
  let state =
    { state with
      snapshot =
        { state.snapshot with
          selected_graph = Some graph
        ; resident_graphs = [ graph ]
        ; startup =
            { state.snapshot.startup with
              account_generation = 1
            ; graph_generation
            ; presentation_generation = 1
            }
        }
    }
  in
  let owner : S.timeline_scope =
    { startup = { account_generation = 1; presentation_generation = 1 }
    ; graph_id = graph
    ; graph_generation
    }
  in
  let sync : Sync.coordination_state =
    { account = Some account
    ; desired_residents = [ graph ]
    ; residents = [ scope, state ]
    ; selected = Some owner
    ; deletion = None
    }
  in
  let physical : Logseq_db_worker.graph_state =
    { graph_id = Some graph
    ; generation = graph_generation
    ; phase = Graph_open
    ; error = None
    }
  in
  let raw : S.coordination_baseline =
    { registration
    ; authority_user = None
    ; limits
    ; baseline =
        { version = 1L
        ; presentation = 1L
        ; state = { sync; residents = [ scope, physical ] }
        }
    }
  in
  let projection =
    match I.bootstrap (S.Coordination_registered raw) with
    | Ok (W.Ready p) -> p
    | _ -> failwith "valid fixture baseline rejected"
  in
  let session = (List.hd (W.residents projection)).session in
  issuer, raw, projection, session
;;

(* Stable typed cursors for pure route tests; constructed only through the public
   issuer/decode boundary, without exposing or inventing a continuation seal. *)
let child_cursor_fixture = lazy (fixture 6100L)

let child_continuation token =
  let issuer, _, _, session = Lazy.force child_cursor_fixture in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:Worker_pure_data.default_page_size ~maximum_bytes:65536
    |> Result.get_ok
  in
  let operation =
    W.Query (budget, W.Child_members { parent = graph; revision = None; after = None })
  in
  let request_id = uuid "98000000-0000-4000-8000-000000006100" in
  ignore
    (I.request session ~request_id:(W.request_id request_id) operation |> Result.get_ok);
  let source_query=W.Child_members{parent=graph;revision=None;after=None} in
  let cursor=Read.For_worker.continuation ~owner:session ~key:(Read.query_key budget source_query) ~budget
    ~cursor:(Logseq_db_types.Graph_types.Cursor.of_string token|>Result.get_ok) in
  let value=Read.For_worker.children ~parent:graph ~revision_scope:(Worker_pure_data.V2_children_revision graph)
    ~scope_revision:"fixture" ~items:[] ~next:(Some cursor) in
  let response=match I.request session ~request_id:(W.request_id request_id) operation|>Result.get_ok with
    |S.Coordination_query request->S.Coordination_queried{registration=request.registration;owner=request.owner;
      request_id=request.request_id;answer=Read.For_worker.answer budget source_query(Ok value)}
    |_->assert false in
  match I.reply session ~request_id:(W.request_id request_id) operation response with
  | Ok (W.Answered (Ok children)) -> Option.get children.next
  | _ -> failwith "valid route continuation rejected"
;;

let confirmed_summary issuer session presentation receipt request_id
    ~lookup ~page ~items ~scope_revision ~generation ~projection_revision =
  let module I=(val issuer:Worker_effect_authority.ISSUER)in
  let operation=W.Confirm(presentation,receipt)in
  match I.request session ~request_id operation |> Result.get_ok with
  |S.Coordination_confirm request->
    let Read.Read_query(budget,query)=request.read in
    let answer=match query with
      |Read.Block_summary _->Read.For_worker.answer budget query(Ok(Read.For_worker.block_summary
        ~lookup ~page ~items ~next:None ~scope_revision ~generation ~projection_revision))
      |_->failwith "Expected the original summary confirmation"in
    let response=S.Coordination_confirmed{registration=request.registration;owner=request.owner;
      presentation=request.presentation;request_id=request.request_id;answer}in
    (match I.reply session ~request_id operation response with
     |Ok(W.Answered(Ok proof))->proof
     |_->failwith "Production confirmation was rejected")
  |_->failwith "Confirmation did not use the typed boundary"
;;

let favorites_sources = Hashtbl.create 2

let favorites
      ?(graph_generation = 1)
      ?(after = None)
      ?(next = None)
      ?(wire_next = None)
      ?(favorites_page = None)
      ?(generation = "generation:v1:1:1")
      ?(projection_revision = "projection:v1:0")
      items
  =
  let produce = match Hashtbl.find_opt favorites_sources graph_generation with
    | Some produce -> produce
    | None ->
      let issuer, _, _, session = fixture ~graph_generation
        (Int64.add 0x1100_0000L (Int64.of_int graph_generation)) in
      let module I = (val issuer : Worker_effect_authority.ISSUER) in
      let budget = W.read_budget session ~maximum_items:50 ~maximum_bytes:65536 |> Result.get_ok in
      let request_id = W.request_id graph in
      let produce after next wire_next favorites_page generation projection_revision items =
        let source_query=W.Favorites after in
        let next=match wire_next with
          |None->next
          |Some cursor->Some(Read.For_worker.continuation ~owner:session ~key:(Read.query_key budget source_query) ~budget ~cursor) in
        let value=Read.For_worker.favorites ~favorites_page ~generation ~projection_revision ~items ~next in
        let operation=W.Query(budget,source_query) in
        let response=match I.request session ~request_id operation|>Result.get_ok with
          |S.Coordination_query request->S.Coordination_queried{registration=request.registration;owner=request.owner;
            request_id=request.request_id;answer=Read.For_worker.answer budget source_query(Ok value)}
          |_->assert false in
        match I.reply session ~request_id operation response with
        |Ok(W.Answered(Ok result))->result
        |_->failwith "Favorites fixture did not produce a checked spec value"
      in
      Hashtbl.add favorites_sources graph_generation produce;
      produce
  in
  produce after next wire_next favorites_page generation projection_revision items
;;

(* Private resource capabilities for the existing business reducers are issued
   through the actual Service request/reply boundary, never record construction. *)
module Resources = struct
  module C = Journal_worker_coordination.Worker_pure_coordinator
  type t =
    { issuer : (module Worker_effect_authority.ISSUER)
    ; session : W.session
    ; scope : S.asset_scope
    ; mutable next : int
    ; mutable core : C.t
    ; demands : (string, W.asset_consumer * string * Logseq_db_types.Asset_descriptor.t list) Hashtbl.t
    }

  let create ?graph ?graph_generation epoch =
    let issuer,raw,projection,session=fixture ?graph ?graph_generation epoch in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let core=(C.step(C.initial ~client_id:(W.graph_id session))(C.Worker_bound I.binding)).next in
    let core=(C.step core(C.Bootstrap_received(I.binding,W.Ready projection))).next in
    let scope=fst(List.hd raw.baseline.state.residents) in
    {issuer;session;scope;core;next=1;demands=Hashtbl.create 8}

  let id t =
    let id=uuid(Printf.sprintf "97000000-0000-4000-8000-%012d" t.next) in
    t.next<-t.next+1;id

  let demand t ~graph_generation ~name priority assets =
    if graph_generation<>t.scope.graph_generation then None else
    let module I=(val t.issuer:Worker_effect_authority.ISSUER) in
    let consumer=W.asset_consumer t.session ~name |> Result.get_ok in
    let request_id=id t in
    match I.request t.session ~request_id:(W.request_id request_id)
      (W.Replace_asset_demand(consumer,priority,assets)) with
    |Ok(S.Coordination_asset_demand{consumer=wire;_})->
      let demand=match I.reply t.session ~request_id:(W.request_id request_id)
          (W.Replace_asset_demand(consumer,priority,assets))
          (S.Coordination_asset_demand_accepted{request_id}) with
        |Ok(W.Answered(Ok demand))->demand
        |_->failwith "resource fixture rejected its matching demand acknowledgement" in
      Hashtbl.replace t.demands name(consumer,wire,assets);Some demand
    |_->failwith "resource fixture rejected its original typed demand"

  let rec settle_cleanup t (transition:C.transition) =
    t.core<-transition.next;
    List.iter(function
      |C.Release_asset_demand_registration(ticket,registration)->
        settle_registration t ticket registration false
      |C.Finalize_asset_demand(ticket,registration)->
        settle_registration t ticket registration true
      |_->())transition.instructions
  and settle_registration t ticket (registration:C.asset_demand_registration) finalize =
    let module I=(val t.issuer:Worker_effect_authority.ISSUER) in
    let session=W.asset_consumer_session registration.consumer in
    let request_id=C.ticket_id ticket in
    let make,check=if finalize then I.finalize_asset_demand,I.asset_demand_finalized
      else I.release_asset_demand_registration,I.asset_demand_registration_released in
    let response=match make session ~request_id ~consumer:registration.consumer ~round:registration.round |> Result.get_ok with
      |S.Coordination_release_asset_demand value->S.Coordination_asset_demand_released{
        registration=value.registration;owner=value.owner;request_id=value.request_id;consumer=value.consumer}
      |S.Coordination_finalize_asset_demand value->S.Coordination_asset_demand_finalized{
        registration=value.registration;owner=value.owner;request_id=value.request_id;consumer=value.consumer}
      |_->failwith "fixture cleanup did not use the planned registration" in
    let result=check session ~request_id ~consumer:registration.consumer ~round:registration.round response in
    let mailbox=Id.Worker.Request_id.of_int64(Int64.of_int t.next) in
    t.next<-t.next+1;
    settle_cleanup t (C.step t.core(C.Admitted(ticket,mailbox)));
    settle_cleanup t (C.step t.core(C.Completed(ticket,W.Answered result)))

  let demand_ticket t ~graph_generation ~name priority assets =
    if graph_generation<>t.scope.graph_generation then None else
    let module I=(val t.issuer:Worker_effect_authority.ISSUER) in
    let consumer=W.asset_consumer t.session ~name |> Result.get_ok in
    let operation=W.Replace_asset_demand(consumer,priority,assets) in
    let ticket,transition=C.request t.core t.session operation |> Result.get_ok in
    settle_cleanup t transition;
    let request_id=C.ticket_id ticket in
    let wire,wire_request_id=match I.request t.session ~request_id operation |> Result.get_ok with
      |S.Coordination_asset_demand value->value.consumer,value.request_id
      |_->failwith "resource fixture did not plan an asset replacement" in
    let reply=I.reply t.session ~request_id operation
      (S.Coordination_asset_demand_accepted{request_id=wire_request_id}) |> Result.get_ok in
    t.core<-(C.step t.core(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int t.next)))).next;
    t.next<-t.next+1;
    settle_cleanup t (C.step t.core(C.Completed(ticket,reply)));
    Hashtbl.replace t.demands name(consumer,wire,assets);
    Some ticket

  let cancel_demand t ticket =
    settle_cleanup t (C.step t.core(C.Cancel ticket));
    settle_cleanup t (C.step t.core(C.Forget ticket))

  let notice t notice =
    let wire name=let _,wire,_=Hashtbl.find t.demands name in wire in
    let notice=match notice with
      |S.Asset_availability value->S.Asset_availability{value with consumer=wire value.consumer}
      |Asset_demand_accepted name->S.Asset_demand_accepted(wire name)
      |Asset_backpressure name->S.Asset_backpressure(wire name)
      |Asset_capacity_available|Upload_status _->notice in
    let module I=(val t.issuer:Worker_effect_authority.ISSUER) in
    I.asset_notice t.session notice |> Result.get_ok

  let availability t ~consumer ~asset availability =
    notice t (S.Asset_availability{consumer;asset=asset.Logseq_db_types.Asset_descriptor.uuid;
      descriptor=asset;availability})

  let lease t file ~handle ~path =
    let module I=(val t.issuer:Worker_effect_authority.ISSUER) in
    let request_id=W.request_id(id t) in
    let operation=W.Acquire_asset_file file in
    ignore(I.request t.session ~request_id operation |> Result.get_ok);
    match I.reply t.session ~request_id operation(S.Asset_file(Some(handle,path))) with
    |Ok(W.Answered(Ok(Some lease)))->lease
    |_->failwith "resource fixture rejected its acquired lease"

  let imported t (receipt:Logseq_db_worker.import_receipt) =
    let module I=(val t.issuer:Worker_effect_authority.ISSUER) in
    let source:Logseq_db_types.Asset_import.t=
      {operation=receipt.operation;asset=receipt.asset.uuid;replace_reference=None;target=receipt.target;
       local_mutation=id t;metadata_mutation=id t;source_file="/synthetic/picker-source";
       title="Synthetic attachment";file_type=receipt.file_type} in
    let intent=W.asset_import_intent t.session source |> Result.get_ok in
    let request_id=id t in
    let operation=W.Import intent in
    let registration=match I.request t.session ~request_id:(W.request_id request_id) operation |> Result.get_ok with
      |S.Coordination_import{registration;_}->registration|_->assert false in
    match I.reply t.session ~request_id:(W.request_id request_id) operation
      (S.Coordination_imported{registration;owner=t.scope;request_id;result=Ok receipt}) with
    |Ok(W.Answered(Ok(W.Imported imported)))->imported
    |_->failwith "resource fixture rejected its actual import proof"
end
