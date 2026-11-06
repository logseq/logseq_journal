module W = Journal_worker_coordination.Worker_api
module C = Journal_worker_coordination.Worker_pure_coordinator
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Id = Journal_worker_ids
module Sync = Logseq_sync_pure_reducer.Core

let check condition message = if not condition then failwith message
let uuid s = W.Uuid.of_string s |> Result.get_ok
let graph = uuid "98000000-0000-4000-8000-000000000001"
let client = uuid "98000000-0000-4000-8000-000000000002"

let fixture = Coordination_test_fixture.fixture

module Read=Worker_pure_read
let typed_query_answer session request_id budget query result =
  let module F=Read.For_worker in
  S.Coordination_queried{registration=F.binding_serial(F.session_binding session);
    owner=F.session_scope session;request_id;answer=F.answer budget query result}
let changes_answer session request_id budget ~generation ~after ~through ~windows ~next =
  typed_query_answer session request_id budget (Read.Changes{generation;after})
    (Ok(Read.For_worker.change_batch ~change_owner:session ~generation ~from_exclusive:after ~through ~windows ~next))
let changes_ack_answer session request_id batch =
  let module F=Read.For_worker in
  S.Coordination_changes_acknowledged{registration=F.binding_serial(F.session_binding session);
    owner=F.session_scope session;request_id;
    result=Ok(F.change_ack ~ack_owner:session ~generation:batch.W.generation ~through:batch.through)}

let ready binding projection =
  let state = (C.step (C.initial ~client_id:client) (C.Worker_bound binding)).next in
  (C.step state (C.Bootstrap_received (binding, W.Ready projection))).next
;;

(* Only a deterministic codec fixture. Real physical settlement is separately
   exercised through Service/DB/Sync; this helper cannot supply that evidence. *)
let pure_host_receipt_fixture issuer plan =
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let request=match I.handoff_request plan |> Result.get_ok with
    |S.Coordination_prepare_host_change request->request|_->assert false in
  let module H=Logseq_db_worker_pure_reducer.Core.Host_handoff in
  let catalog=match request.change with H.Close_graph id|Remove_graph(id,_)->Rrbvec.singleton id|_->Rrbvec.empty in
  let facts:H.facts={authenticated=true;version=request.version;registration=Some request.registration;
    account=Some request.owner;scopes=request.expected;catalog} in
  let backend:H.request={version=request.version;id=request.id;registration=request.registration;
    owner=request.owner;change=request.change;expected=request.expected;captured=request.expected} in
  let pending,admission=H.prepare(H.empty ~lifetime:(uuid "98000000-0000-4000-8000-000000009899"))facts backend in
  let attempt=match admission with H.Start value->value|_->failwith "invalid pure host codec fixture" in
  let safe=H.settled pending attempt ~copy_generation:None in
  let receipt=match H.phase safe request.id with Some(H.Safe value)->value|_->failwith "invalid pure settlement input" in
  I.handoff_receipt plan(S.Coordination_host_prepared receipt) |> Result.get_ok
;;

let checked_import_reply issuer session ticket intent receipt =
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let response=match I.request session ~request_id:(C.ticket_id ticket)(W.Import intent) |> Result.get_ok with
    |S.Coordination_import{registration;owner;request_id;_}->S.Coordination_imported{registration;owner;request_id;result=Ok receipt}
    |_->failwith "Import bypassed its registration-owned Service entry" in
  I.reply session ~request_id:(C.ticket_id ticket)(W.Import intent)response |> Result.get_ok
;;

let checked_demand issuer session ticket consumer assets =
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let operation=W.Replace_asset_demand(consumer,W.Foreground,assets) in
  let request_id=match I.request session ~request_id:(C.ticket_id ticket)operation |> Result.get_ok with
    |S.Coordination_asset_demand{request_id;_}->request_id|_->assert false in
  match I.reply session ~request_id:(C.ticket_id ticket)operation
    (S.Coordination_asset_demand_accepted{request_id}) |> Result.get_ok with
  |W.Answered(Ok demand)->demand
  |_->failwith "checked demand fixture rejected matching ACK"
;;

let test_asset_demand_notice_has_one_registered_owner () =
  let issuer,raw,projection,session=fixture 881L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let state=ready I.binding projection in
  let consumer=W.asset_consumer session ~name:"media:synthetic-owner" |> Result.get_ok in
  let asset=Logseq_db_types.Asset_descriptor.create ~uuid:(uuid "98000000-0000-4000-8000-000000000881")
    ~source:(Managed None) ~current_checksum:None ~size:None ~dimensions:None |> Result.get_ok in
  let oversized=Logseq_db_types.Asset_descriptor.create ~uuid:asset.uuid
    ~source:(External(String.make(Worker_pure_data.maximum_response_bytes+1)'x'))
    ~current_checksum:None ~size:None ~dimensions:None |> Result.get_ok in
  check(Result.is_error(W.validate_request session(W.Replace_asset_demand(consumer,W.Foreground,[oversized]))))
    "asset demand admitted an unbounded descriptor payload";
  let operation=W.Replace_asset_demand(consumer,W.Foreground,[asset]) in
  let ticket,planned=match C.request state session operation with
    | Ok value->value
    | Error(W.Unsupported_operation message)->failwith("typed demand admission unsupported: "^message)
    | Error _->failwith "typed demand admission rejected" in
  let wire_name=match I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok with
    | S.Coordination_asset_demand{consumer;_}->consumer
    | _->failwith "typed asset demand did not use the existing scoped Service command" in
  check(wire_name<>"media:synthetic-owner") "asset demand was not isolated by binding/session";
  let notice=I.asset_notice session(S.Asset_demand_accepted wire_name) |> Result.get_ok in
  let demand=W.asset_notice_demand notice |> Option.get in
  let announced=(C.step planned.next(C.Asset_received(notice,Id.Worker.Push_sequence.of_int64 1L))).next in
  let values=C.asset_notices(C.view announced)demand in
  check(Rrbvec.to_list(C.asset_updates ~previous:(Some(C.view planned.next))(C.view announced))=[notice])
    "accepted asset notice did not leave the original typed outlet";
  check(not(C.equal_view(C.view announced)(C.view planned.next))) "asset fact update was hidden by view equality";
  check(List.length values=1) "registered consumer did not own its exact acceptance notice";
  check(Option.exists(W.equal_asset_consumer consumer)(W.asset_notice_consumer(List.hd values))) "notice guessed a different consumer association";
  let duplicate=(C.step announced(C.Asset_received(notice,Id.Worker.Push_sequence.of_int64 1L))).next in
  check(C.asset_notices(C.view duplicate)demand=values) "duplicate acceptance accumulated an event log";
  check(Rrbvec.length(C.asset_updates ~previous:(Some(C.view announced))(C.view duplicate))=0)
    "duplicate sequence escaped the typed outlet";
  let capacity=I.asset_notice session S.Asset_capacity_available |> Result.get_ok in
  let capacity_one=(C.step duplicate(C.Asset_received(capacity,Id.Worker.Push_sequence.of_int64 6L))).next in
  let capacity_two=(C.step capacity_one(C.Asset_received(capacity,Id.Worker.Push_sequence.of_int64 7L))).next in
  check(C.session_asset_notices(C.view capacity_one)session=C.session_asset_notices(C.view capacity_two)session)
    "same-content capacity fixture changed payload";
  check(Rrbvec.to_list(C.asset_updates ~previous:(Some(C.view capacity_one))(C.view capacity_two))=[capacity])
    "a second real capacity notification could not wake backpressured consumers";
  let capacity_old=(C.step capacity_two(C.Asset_received(capacity,Id.Worker.Push_sequence.of_int64 6L))).next in
  check(Rrbvec.length(C.asset_updates ~previous:(Some(C.view capacity_two))(C.view capacity_old))=0)
    "out-of-order capacity notification escaped the typed outlet";
  let asset_notice=I.asset_notice session(S.Asset_availability{consumer=wire_name;asset=asset.uuid;descriptor=asset;availability=Ready "real-ready-capability"}) |> Result.get_ok in
  let latest=(C.step duplicate(C.Asset_received(asset_notice,Id.Worker.Push_sequence.of_int64 3L))).next in
  let old=I.asset_notice session(S.Asset_availability{consumer=wire_name;asset=asset.uuid;descriptor=asset;availability=Downloading}) |> Result.get_ok in
  let older=(C.step latest(C.Asset_received(old,Id.Worker.Push_sequence.of_int64 2L))).next in
  check(List.exists(fun notice->Option.is_some(W.ready_asset_file notice))(C.asset_notices(C.view older)demand))
    "out-of-order notice rolled a Ready capability backwards";
  check(Rrbvec.length(C.asset_updates ~previous:(Some(C.view latest))(C.view older))=0)
    "stale Ready replacement escaped the typed outlet";
  let ready_file=W.ready_asset_file asset_notice |> Option.get in
  let acquire,_=C.request older session(W.Acquire_asset_file ready_file) |> Result.get_ok in
  check(match I.request session ~request_id:(C.ticket_id acquire)(W.Acquire_asset_file ready_file) with
    |Ok(S.Acquire_asset_file _)->true|_->false) "registered Ready did not reach the existing scoped acquire";
  let version=Logseq_db_types.Asset_descriptor.version ~checksum:(String.make 64 '1') ~file_type:"png" |> Result.get_ok in
  let replacement=Logseq_db_types.Asset_descriptor.create ~uuid:asset.uuid ~source:(Managed(Some version))
    ~current_checksum:(Some version.checksum) ~size:None ~dimensions:None |> Result.get_ok in
  let replacement_ticket,replaced=C.request older session(W.Replace_asset_demand(consumer,W.Foreground,[replacement])) |> Result.get_ok in
  let _,late_release=C.request replaced.next session(W.Release_asset_demand demand) |> Result.get_ok in
  let new_wire=match I.request session ~request_id:(C.ticket_id replacement_ticket)
    (W.Replace_asset_demand(consumer,W.Foreground,[replacement])) |> Result.get_ok with
    |S.Coordination_asset_demand{consumer;_}->consumer|_->assert false in
  let new_notice=I.asset_notice session(S.Asset_demand_accepted new_wire) |> Result.get_ok in
  let new_demand=W.asset_notice_demand new_notice |> Option.get in
  let after_late_release=(C.step late_release.next(C.Asset_received(new_notice,Id.Worker.Push_sequence.of_int64 5L))).next in
  check(C.asset_notices(C.view after_late_release)new_demand<>[])
    "queued old-round release retired its replacement consumer";
  let old_ready=(C.step replaced.next(C.Asset_received(asset_notice,Id.Worker.Push_sequence.of_int64 4L))).next in
  check(not(List.exists(fun notice->Option.is_some(W.ready_asset_file notice))(C.asset_notices(C.view old_ready)demand)))
    "old demand Ready capability survived a descriptor replacement round";
  let focused=match I.bootstrap(S.Coordination_registered{raw with limits={raw.limits with response_budget_bytes=32768};
    baseline={raw.baseline with version=2L;presentation=2L}}) with
    | Ok(W.Ready value)->value|_->failwith "changed metadata did not produce a Ready session" in
  let focused_session=(List.hd(W.residents focused)).session in
  let focused_consumer=W.asset_consumer focused_session ~name:"media:synthetic-owner" |> Result.get_ok in
  check(W.equal_asset_consumer consumer focused_consumer && W.compare_asset_consumer consumer focused_consumer=0)
    "consumer identity changed with presentation/read metadata";
  let focused_state=(C.step older(C.Projection_received focused)).next in
  check(C.asset_notices(C.view focused_state)demand<>[])
    "pure consumer registry did not preserve execution across focus/metadata updates";
  let _,releasing=C.request focused_state focused_session(W.Release_asset_demand demand) |> Result.get_ok in
  let late=(C.step releasing.next(C.Asset_received(notice,Id.Worker.Push_sequence.of_int64 1L))).next in
  check(C.asset_notices(C.view late)demand=[]) "late demand notice revived a retired consumer";
  check(Rrbvec.length(C.asset_updates ~previous:(Some(C.view releasing.next))(C.view late))=0)
    "retired consumer notice escaped the typed outlet";
  let foreign,_,_,foreign_session=fixture 882L in
  let module F=(val foreign:Worker_effect_authority.ISSUER) in
  check(Result.is_error(F.asset_notice foreign_session(S.Asset_demand_accepted wire_name)))
    "old binding consumer namespace crossed into a new issuer"
;;

let asset_release_tickets instructions =
  let release : C.instruction -> unit C.ticket option = function
    | C.Release_asset_demand_registration(ticket,_)->Some ticket
    | _->None in
  List.filter_map release instructions
;;

let asset_finalize_tickets instructions =
  List.filter_map(function C.Finalize_asset_demand(ticket,_)->Some ticket|_->None)instructions
;;
let complete_unit state ticket =
  let admitted=(C.step state(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
  let completed=(C.step admitted(C.Completed(ticket,W.Answered(Ok())))).next in
  (C.step completed(C.Forget ticket)).next
;;

let test_asset_cleanup_ack_and_shutdown_retry () =
  let issuer,_,projection,session=fixture 883L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let initial=ready I.binding projection in
  let consumer=W.asset_consumer session ~name:"cleanup-owner" |> Result.get_ok in
  let asset=Logseq_db_types.Asset_descriptor.create ~uuid:graph ~source:(Managed None)
    ~current_checksum:None ~size:None ~dimensions:None |> Result.get_ok in
  let creator,planned=C.request initial session(W.Replace_asset_demand(consumer,W.Foreground,[asset])) |> Result.get_ok in
  let demand=checked_demand issuer session creator consumer [asset] in
  let admitted=(C.step planned.next(C.Admitted(creator,Id.Worker.Request_id.one))).next in
  let created=(C.step admitted(C.Completed(creator,W.Answered(Ok demand)))).next in
  let created=(C.step created(C.Forget creator)).next in
  let waiter,releasing=C.request created session(W.Release_asset_demand demand) |> Result.get_ok in
  let cleanup=List.hd(asset_release_tickets releasing.instructions) in
  let forged=(C.step releasing.next(C.Completed(waiter,W.Answered(Ok())))).next in
  check(C.reply(C.view forged)waiter=None) "public release waiter accepted a fabricated transport ACK";
  let full=C.step forged(C.Admission_refused(cleanup,W.Full)) in
  check(C.reply(C.view full.next)waiter=None) "Full lost the actual release waiter";
  check(asset_release_tickets(C.step full.next C.Drain).instructions=[]) "Full cleanup spun without capacity";
  let retry=C.step full.next C.Capacity_available in
  let cleanup=List.hd(asset_release_tickets retry.instructions) in
  let early=(C.step retry.next(C.Completed(cleanup,W.Answered(Ok())))).next in
  check(C.reply(C.view early)waiter=None) "early physical reply escaped admission ordering";
  let finalized=C.step early(C.Admitted(cleanup,Id.Worker.Request_id.one)) in
  check(C.reply(C.view finalized.next)waiter=None) "physical release bypassed registry finalization";
  let finalizer=List.hd(asset_finalize_tickets finalized.instructions) in
  let done_state=complete_unit finalized.next finalizer in
  check(C.reply(C.view done_state)waiter=Some(W.Answered(Ok()))) "actual release ACK did not settle waiter";
  check(C.validate_session initial session=Ok()) "cleanup mutated a preceding pure state";
  let creator,planned=C.request done_state session(W.Replace_asset_demand(consumer,W.Foreground,[asset])) |> Result.get_ok in
  let demand=checked_demand issuer session creator consumer [asset] in
  let admitted=(C.step planned.next(C.Admitted(creator,Id.Worker.Request_id.one))).next in
  let created=(C.step admitted(C.Completed(creator,W.Answered(Ok demand)))).next in
  let stopping=C.step (C.step created(C.Forget creator)).next C.Shutdown_requested in
  let cleanup=List.hd(asset_release_tickets stopping.instructions) in
  let admitted=(C.step stopping.next(C.Admitted(cleanup,Id.Worker.Request_id.of_int64 2L))).next in
  let failed=(C.step admitted(C.Completed(cleanup,W.Answered(Error(W.Service_failed "synthetic physical failure"))))).next in
  check((match C.shutdown_state(C.view failed)with C.Shutdown_failed _->true|_->false)) "physical release failure was hidden";
  let aggregate=(C.step failed(C.Binding_release_completed(I.binding,Ok()))).next in
  check(C.shutdown_state(C.view aggregate)=C.Stopped)
    "actual aggregate binding ACK retained a settled demand failure";
  let late=(C.step aggregate(C.Completed(cleanup,W.Answered(Error(W.Service_failed "duplicate old cleanup"))))).next in
  check(C.shutdown_state(C.view late)=C.Stopped) "old cleanup error revived an aggregate-settled obligation";
  let wake=C.step failed C.Capacity_available in
  check(asset_release_tickets wake.instructions=[]) "failed physical release retried automatically on every callback";
  let retried=C.step wake.next C.Shutdown_requested in
  check(List.length(asset_release_tickets retried.instructions)=1) "explicit shutdown retry stranded the failed resource obligation"
;;

let test_unconfirmed_asset_registration_cleanup () =
  List.iter(fun mode->
    let issuer,_,projection,session=fixture(Int64.add 885L(Int64.of_int mode)) in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let consumer=W.asset_consumer session ~name:"unconfirmed-cleanup" |> Result.get_ok in
    let ticket,planned=C.request(ready I.binding projection)session
      (W.Replace_asset_demand(consumer,W.Foreground,[])) |> Result.get_ok in
    let demand=checked_demand issuer session ticket consumer [] in
    let pending=if mode=1 then C.step planned.next(C.Cancel ticket)
      else if mode=2 then C.step planned.next(C.Forget ticket) else planned in
    if mode=1 || mode=2 then check(asset_release_tickets pending.instructions=[])
      "pending creator was physically released before terminal completion";
    let admitted=(C.step pending.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
    let completed=C.step admitted(C.Completed(ticket,
      if mode=0 then W.Answered(Error(W.Service_failed "accepted demand lost its ACK"))
      else W.Answered(Ok demand))) in
    let releases=asset_release_tickets completed.instructions in
    check(releases<>[]) "failed or canceled registration did not plan exact physical cleanup";
    let release=List.hd releases in
    check(List.exists(function C.Release_asset_demand_registration(actual,registration)->
      W.equal_request_id(C.ticket_id actual)(C.ticket_id release)
      && W.equal_request_id registration.round(C.ticket_id ticket)
      && W.equal_asset_consumer registration.consumer consumer|_->false)completed.instructions)
      "unconfirmed cleanup retargeted another round";
    check(C.asset_notices(C.view completed.next)demand=[])
      "unconfirmed retired demand retained data authority";
    let forgotten=(C.step completed.next(C.Forget ticket)).next in
    if mode=0 then check(C.revalidate_reply(C.view forgotten)ticket
      (W.Answered(Error(W.Service_failed "accepted demand lost its ACK")))
      =W.Answered(Error(W.Service_failed "accepted demand lost its ACK")))
      "cleanup retirement masked the original failure from its callback";
    let canceled=(C.step forgotten(C.Cancel ticket)).next in
    let admitted=(C.step canceled(C.Admitted(release,Id.Worker.Request_id.of_int64 2L))).next in
    let released=C.step admitted(C.Completed(release,W.Answered(Ok()))) in
    let finalizer=List.hd(asset_finalize_tickets released.instructions) in
    ignore(complete_unit released.next finalizer)) [0;1;2];
  let issuer,_,projection,session=fixture 889L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let consumer=W.asset_consumer session ~name:"never-admitted" |> Result.get_ok in
  let initial=ready I.binding projection in
  let ticket,planned=C.request initial session(W.Replace_asset_demand(consumer,W.Foreground,[])) |> Result.get_ok in
  let refused=C.step planned.next(C.Admission_refused(ticket,W.Full)) in
  check(asset_release_tickets refused.instructions=[])
    "never-admitted demand fabricated a physical cleanup";
  let retried=C.request (C.step refused.next(C.Forget ticket)).next session
    (W.Replace_asset_demand(consumer,W.Foreground,[])) |> Result.get_ok in
  check(asset_release_tickets(snd retried).instructions=[])
    "never-created demand persisted an unnecessary release obligation"
;;

let test_asset_cleanup_round_properties () =
  let run actions =
    let issuer,_,projection,session=fixture 884L in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let consumer=W.asset_consumer session ~name:"round-properties" |> Result.get_ok in
    let first,one=C.request(ready I.binding projection)session(W.Replace_asset_demand(consumer,W.Foreground,[])) |> Result.get_ok in
    let first_demand=checked_demand issuer session first consumer [] in
    let admitted=(C.step one.next(C.Admitted(first,Id.Worker.Request_id.one))).next in
    let first_state=(C.step admitted(C.Completed(first,W.Answered(Ok first_demand)))).next in
    let first_state=(C.step first_state(C.Forget first)).next in
    let second,two=C.request first_state session(W.Replace_asset_demand(consumer,W.Foreground,[])) |> Result.get_ok in
    let old=List.hd(asset_release_tickets two.instructions) in
    let demand=checked_demand issuer session second consumer [] in
    let admitted=(C.step two.next(C.Admitted(second,Id.Worker.Request_id.one))).next in
    let created=(C.step admitted(C.Completed(second,W.Answered(Ok demand)))).next in
    let created=(C.step created(C.Forget second)).next in
    let waiter,release=C.request created session(W.Release_asset_demand demand) |> Result.get_ok in
    let current=List.hd(asset_release_tickets release.instructions) in
    let state=ref release.next in
    let admitted=Array.make 4 false and answered=Array.make 4 false in
    let tickets=Array.make 4 None in tickets.(0)<-Some old;tickets.(1)<-Some current;
    let apply event=
      let tr=C.step !state event in state:=tr.next;
      List.iter(function C.Finalize_asset_demand(ticket,registration)->
        let which=if W.equal_request_id registration.round (C.ticket_id first) then 2 else 3 in
        tickets.(which)<-Some ticket |_->())tr.instructions in
    (* Four genuine flights: two old/current physical releases, then their
       metadata finalizers. Callbacks may arrive before admission, once each. *)
    List.iter(fun action->
      let which=(action/2)mod 4 in
      (match tickets.(which) with
       |Some ticket when action mod 2=0 && not admitted.(which)->
         admitted.(which)<-true;apply(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(which+10))))
       |Some ticket when action mod 2=1 && not answered.(which)->
         answered.(which)<-true;apply(C.Completed(ticket,W.Answered(Ok())))
       |_->());
      check((C.reply(C.view !state)waiter=Some(W.Answered(Ok())))=(admitted.(3)&&answered.(3)))
        "current waiter borrowed another round or skipped finalization";
      check(C.asset_notices(C.view !state)demand=[]) "retired consumer regained notification authority")actions
  in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions=
    let rec remove prefix=function
      | []->actions
      | _::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      | action::rest->remove(action::prefix)rest in remove [] actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0xA55E;seed|] in
    let actions=List.init 80(fun _->Random.State.int random 8) @ [0;1;2;3;4;5;6;7] in
    if fails actions then failwith(Printf.sprintf "asset round seed=%d minimized=[%s]" seed
      (String.concat ";"(List.map string_of_int(shrink actions))))
  done
;;

let test_import_source_recovery_owner_cursor_and_ack () =
  let issuer,raw,projection,session=fixture 9888L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let module U=Logseq_db_types.Asset_upload_intent in
  let module R=Logseq_db_types.Asset_import.Recovery in
  let scope,_=List.hd raw.baseline.state.residents in
  let source:Logseq_db_types.Asset_import.t={operation=uuid "96000000-0000-4000-8000-000000008881";
    asset=uuid "96000000-0000-4000-8000-000000008882";target=uuid "96000000-0000-4000-8000-000000008883";
    local_mutation=uuid "96000000-0000-4000-8000-000000008884";metadata_mutation=uuid "96000000-0000-4000-8000-000000008885";
    replace_reference=None;source_file="/isolated-picker/persisted.png";title="Original staged input";file_type="png"} in
  let intent=W.asset_import_intent session source |> Result.get_ok in
  let prepared=U.prepare ~operation_id:source.operation ~origin:(Uri.to_string scope.account.managed_sync_origin)
      ~account:scope.account.user_id ~graph:scope.graph_id ~asset:source.asset
      ~version:(Logseq_db_types.Asset_descriptor.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok)
      ~title:source.title ~size:4L ~staged_file:"isolated-prepared.bin" ~replace_reference:None ~target:source.target
      ~local_mutation:source.local_mutation ~metadata_mutation:source.metadata_mutation |> Result.get_ok in
  let row:R.item={sequence=1L;input=Bytes.to_string(W.encode_asset_import_intent intent);
    prepared=Some(U.Pure_codec.encode prepared);acknowledged=false} in
  let input_id=uuid "96000000-0000-4000-8000-000000008886" in
  let mailbox=ref 9888L in
  let consume state ticket reply=mailbox:=Int64.succ !mailbox;
    (C.step(C.step state(C.Admitted(ticket,Id.Worker.Request_id.of_int64 !mailbox))).next(C.Completed(ticket,reply))).next in
  let raw_id:type a. a C.ticket -> a W.request -> W.Uuid.t =fun ticket operation->
    match I.request session ~request_id:(C.ticket_id ticket)operation |> Result.get_ok with
    |S.Coordination_recover_import_inputs{request_id;_}|Coordination_confirm_import_input{request_id;_}
    |Coordination_acknowledge_import_input{request_id;_}->request_id
    |_->assert false in
  let imported,planned=C.request(ready I.binding projection)session(W.Import intent) |> Result.get_ok in
  check(Rrbvec.is_empty(C.pending_import_source_intents(C.view planned.next)))
    "source lookup raced the pending original Import";
  let admitted=(C.step planned.next(C.Admitted(imported,Id.Worker.Request_id.of_int64 9889L))).next in
  check(Rrbvec.is_empty(C.pending_import_source_intents(C.view admitted)))
    "source lookup raced the admitted original Import";
  let unknown=consume planned.next imported(W.Interrupted W.Transport_lost) in
  check(C.import_source_pending(C.view unknown) ~operation:source.operation)"lost import reply did not retain its source";
  let operation=W.Recover_import_inputs{after=None;maximum_items=2;maximum_bytes=65536} in
  let recovery,planned=C.request unknown session operation |> Result.get_ok in
  let recovery_id=raw_id recovery operation in
  let frame request_id page=S.Coordination_import_inputs_recovered{registration=raw.registration;owner=scope;request_id;page} in
  let page:R.page={items=[row];next=Some 1L} in
  let reply=I.reply session ~request_id:(C.ticket_id recovery)operation(frame recovery_id page) |> Result.get_ok in
  let decoded=match reply with W.Answered(Ok value)->value|_->assert false in
  check(Rrbvec.length decoded.inputs=1 && decoded.continuation<>None)"partial import input recovery lost its More cursor";
  let budget_changed=W.Recover_import_inputs{after=decoded.continuation;maximum_items=1;maximum_bytes=65536} in
  check(Result.is_error(W.validate_request session budget_changed))"source cursor silently changed its budgets";
  let _,_,_,other=fixture 9889L in
  check(Result.is_error(W.validate_request other(W.Recover_import_inputs{after=decoded.continuation;maximum_items=2;maximum_bytes=65536})))
    "source cursor crossed its original binding/session";
  check(Result.is_error(I.reply session ~request_id:(C.ticket_id recovery)operation(frame input_id page)))
    "foreign source recovery request consumed this ticket";
  check(Result.is_error(I.reply session ~request_id:(C.ticket_id recovery)operation(frame recovery_id{page with next=Some 0L})))
    "source recovery accepted a nonadvancing cursor";
  check(Result.is_error(I.reply session ~request_id:(C.ticket_id recovery)operation
    (frame recovery_id{items=[row;{row with sequence=2L}];next=None})))
    "source recovery accepted duplicate original operation identities";
  let confirmation,confirming=C.request planned.next session(W.Confirm_import_source intent) |> Result.get_ok in
  let full=C.step confirming.next(C.Admission_refused(confirmation,W.Full))in
  check(C.reply(C.view full.next)confirmation=None) "source read Full consumed its recovery attempt";
  let capacity=C.step full.next C.Capacity_available in
  check(List.exists(function C.Send(ticket,_,W.Confirm_import_source original)->
    W.equal_request_id(C.ticket_id ticket)(C.ticket_id confirmation)
    && W.encode_asset_import_intent original=W.encode_asset_import_intent intent|_->false)capacity.instructions)
    "source read did not keep its original ticket for actual capacity";
  let response input=S.Coordination_import_input_confirmed{registration=raw.registration;owner=scope;
    request_id=raw_id confirmation(W.Confirm_import_source intent);input} in
  let unknown_reply=I.reply session ~request_id:(C.ticket_id confirmation)(W.Confirm_import_source intent)
    (response(Some{row with prepared=None})) |> Result.get_ok in
  let still_unknown=consume confirming.next confirmation unknown_reply in
  check(C.import_source_pending(C.view still_unknown) ~operation:source.operation)"unprepared readback discarded the original source";
  let confirmed_reply=I.reply session ~request_id:(C.ticket_id confirmation)(W.Confirm_import_source intent)(response(Some row)) |> Result.get_ok in
  let confirmed=consume confirming.next confirmation confirmed_reply in
  check(not(C.import_source_pending(C.view confirmed) ~operation:source.operation))"real original Prepared readback failed to settle source ownership";
  let source_proof=match confirmed_reply with W.Answered(Ok(Some item))->Option.get item.prepared|_->assert false in
  check(Result.is_error(W.validate_request other(W.Acknowledge_import_source source_proof)))"Prepared proof authorized ACK in a reopened session";
  let acknowledgement,acknowledging=C.request confirmed session(W.Acknowledge_import_source source_proof) |> Result.get_ok in
  let acknowledged=consume acknowledging.next acknowledgement(W.Answered(Ok())) in
  let stale=consume acknowledged recovery reply in
  check(match C.reply(C.view stale)recovery with Some(W.Answered(Error(W.Stale_read _)))->true|_->false)
    "old source page revived pending membership after actual ACK";
  check(C.import_source_proof(C.view acknowledged)intent<>None)"source ACK erased immutable source adoption proof";
  let duplicate=(C.step acknowledged(C.Completed(acknowledgement,W.Answered(Ok())))).next in
  check(C.equal_view(C.view acknowledged)(C.view duplicate))"duplicate ACK mutated the source lifecycle twice"
;;

let test_import_recovery_pure_original_proof_owner () =
  let module P=Logseq_db_types.Asset_import.Pure_intent in
  let module I=Logseq_db_types.Asset_upload_intent in
  let module R=Logseq_db_types.Asset_import.Recovery in
  let namespace=String.make 64 'a' in
  let owner:R.owner={namespace;origin="https://synthetic.invalid";account="source-owner";graph=client} in
  let source:Logseq_db_types.Asset_import.t={operation=uuid "96000000-0000-4000-8000-000000007101";
    asset=uuid "96000000-0000-4000-8000-000000007102";target=uuid "96000000-0000-4000-8000-000000007103";
    local_mutation=uuid "96000000-0000-4000-8000-000000007104";metadata_mutation=uuid "96000000-0000-4000-8000-000000007105";
    replace_reference=None;source_file="/isolated-picker/original.png";title="Pure original source";file_type="png"} in
  let input=P.create ~namespace source |> Result.get_ok in
  let prepared ?(account=owner.account) ?(graph=owner.graph) ?(target=source.target) ()=
    I.prepare ~operation_id:source.operation ~origin:owner.origin ~account ~graph ~asset:source.asset
      ~version:(Logseq_db_types.Asset_descriptor.version ~checksum:(String.make 64 'a') ~file_type:source.file_type |> Result.get_ok)
      ~title:source.title ~size:4L ~staged_file:"isolated-original.bin" ~replace_reference:None ~target
      ~local_mutation:source.local_mutation ~metadata_mutation:source.metadata_mutation |> Result.get_ok in
  let original=prepared() in
  let row:R.item={sequence=1L;input=P.encode input;prepared=Some(I.Pure_codec.encode original);acknowledged=false} in
  check(I.Pure_codec.decode(I.Pure_codec.encode original)=Ok original)"pure checkpoint codec lost original fields";
  let check_case action=
    let candidate_owner,candidate,valid=match action mod 11 with
      |0|1->owner,row,true
      |2->{owner with account="foreign"},row,false
      |3->owner,{row with prepared=Some(I.Pure_codec.encode(prepared ~target:client()))},false
      |4->owner,{row with prepared=Some(I.Pure_codec.encode(I.advance original Local_committed |> Result.get_ok))},false
      |5->owner,{row with prepared=None;acknowledged=true},false
      |6->owner,{row with sequence=0L},false
      |7->owner,{row with prepared=Some "malformed original proof"},false
      |8->{owner with namespace=String.make 64 'b'},row,false
      |9->owner,{row with input=row.input^" "},false
      |_->owner,{row with prepared=Some(I.Pure_codec.encode(prepared ~graph:source.asset()))},false in
    let first=R.decode ~owner:candidate_owner candidate in
    check(Result.is_ok first=valid)"pure recovered input accepted wrong owner, status, or original identity";
    check(first=R.decode ~owner:candidate_owner candidate)"same proof validation input changed its result";
    check(P.encode input=row.input)"proof validation mutated the original complete input" in
  let fails actions=try List.iter check_case actions;false with _->true in
  let rec shrink actions=let rec remove prefix=function []->actions
    |_::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
    |head::rest->remove(head::prefix)rest in remove [] actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0x534f5552;seed|] in
    let actions=List.init 11 Fun.id @ List.init 60(fun _->Random.State.int random 512) in
    if fails actions then failwith(Printf.sprintf "source proof seed=%d minimized=[%s]" seed
      (String.concat ";"(List.map string_of_int(shrink actions))))
  done
;;

let test_import_intent_preserves_complete_source () =
  let _,_,_,session=fixture 885L in
  let source:Logseq_db_types.Asset_import.t=
    {operation=uuid "98000000-0000-4000-8000-000000000885";
     asset=uuid "98000000-0000-4000-8000-000000000886";target=graph;replace_reference=None;
     local_mutation=uuid "98000000-0000-4000-8000-000000000887";
     metadata_mutation=uuid "98000000-0000-4000-8000-000000000888";
     source_file="/tmp/synthetic-picker-885.png";title="Synthetic attachment";file_type="png"} in
  let intent=W.asset_import_intent session source |> Result.get_ok in
  let encoded=W.encode_asset_import_intent intent in
  (* cbe942a's persisted flat Import_json encoding is the compatibility fixture. *)
  check(Bytes.to_string encoded={golden|{"asset":"98000000-0000-4000-8000-000000000886","file_type":"png","local_mutation":"98000000-0000-4000-8000-000000000887","metadata_mutation":"98000000-0000-4000-8000-000000000888","namespace":"fb8d27f50b99fca49665bdb748e7c3518017a82099d540b8d62ead3c96ba2e48","operation":"98000000-0000-4000-8000-000000000885","replace_reference":null,"schema":1,"source_file":"/tmp/synthetic-picker-885.png","target":"98000000-0000-4000-8000-000000000001","title":"Synthetic attachment"}|golden})
    "shared pure import codec changed a previously persisted intent identity";
  check(W.asset_import_intent_id intent=source.operation) "import minted a replacement operation identity";
  let _,_,_,restarted=fixture ~graph_generation:99 886L in
  let restored=W.restore_asset_import_intent restarted encoded |> Result.get_ok in
  check(W.encode_asset_import_intent restored=encoded) "import restore changed exact source/target/IDs";
  let _,_,_,foreign=fixture ~graph:client 887L in
  check(Result.is_error(W.restore_asset_import_intent foreign encoded)) "import restore crossed logical graph";
  check(Result.is_error(W.asset_import_intent session {source with metadata_mutation=source.local_mutation}))
    "import accepted shared metadata/local mutation identity";
  check(Result.is_error(W.asset_import_intent session {source with source_file=""})) "import omitted source ownership";
  let changed=W.asset_import_intent session {source with target=client} |> Result.get_ok in
  check(W.encode_asset_import_intent changed<>encoded) "same operation's changed target had identical immutable bytes";
  check(Result.is_error(W.restore_asset_import_intent restarted(Bytes.of_string "{\"schema\":1,\"schema\":1}")))
    "import accepted duplicate JSON ownership fields"
;;

let test_import_preview_late_result_is_cleanup_owned () =
  let issuer,raw,projection,session=fixture 888L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let source:Logseq_db_types.Asset_import.t=
    {operation=uuid "98000000-0000-4000-8000-000000000885";
     asset=uuid "98000000-0000-4000-8000-000000000886";target=graph;replace_reference=None;
     local_mutation=uuid "98000000-0000-4000-8000-000000000887";
     metadata_mutation=uuid "98000000-0000-4000-8000-000000000888";
     source_file="/tmp/synthetic-import-888.png";title="Synthetic preview";file_type="png"} in
  let intent=W.asset_import_intent session source |> Result.get_ok in
  let ticket,planned=C.request(ready I.binding projection)session(W.Import intent) |> Result.get_ok in
  let changed=W.asset_import_intent session {source with target=client} |> Result.get_ok in
  check(Result.is_error(C.request planned.next session(W.Import changed)))
    "an accepted/pending import operation changed target under the same identity";
  let owner=fst(List.hd raw.baseline.state.sync.residents) in
  let asset=Logseq_db_types.Asset_descriptor.create ~uuid:source.asset ~source:(Managed None)
    ~current_checksum:(Some(String.make 64 '1')) ~size:(Some 4L) ~dimensions:None |> Result.get_ok in
  let receipt:Logseq_db_worker.import_receipt={operation=source.operation;graph_generation=owner.graph_generation;
    scope=owner;target=source.target;asset;file_type="png";preview=Some("held-preview-888","/tmp/synthetic-owned-preview-888.png")} in
  let reply=checked_import_reply issuer session ticket intent receipt in
  let admitted=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
  let retired=(C.step admitted(C.Forget ticket)).next in
  let done_state=C.step retired(C.Completed(ticket,reply)) in
  check(C.reply(C.view done_state.next)ticket=None) "forgotten import revived its public callback";
  check(List.exists(function C.Send(_,_,W.Release_file lease)->
    W.file_path lease="/tmp/synthetic-owned-preview-888.png"|_->false)done_state.instructions)
    "late published Import preview disappeared without an actual release instruction";
  check(C.import_progress(C.view done_state.next)intent<>None) "accepted forgotten import lost its durable operation fact";
  let lease=match reply with W.Answered(Ok(W.Imported imported))->W.import_preview imported |> Option.get|_->failwith "expected sealed imported preview" in
  let release_ticket instructions=
    let find : C.instruction -> unit C.ticket option=function C.Send(ticket,_,W.Release_file _)->Some ticket|_->None in
    List.find_map find instructions |> Option.get in
  let physical=release_ticket done_state.instructions in
  let waiter,waiting=C.request done_state.next session(W.Release_file lease) |> Result.get_ok in
  check(C.reply(C.view waiting.next)waiter=None) "lease release returned admission as physical ACK";
  let admitted=(C.step waiting.next(C.Admitted(physical,Id.Worker.Request_id.of_int64 4L))).next in
  let failed=C.step admitted(C.Completed(physical,W.Answered(Error(W.Service_failed "synthetic file release failure")))) in
  check((match C.reply(C.view failed.next)waiter with Some(W.Answered(Error _))->true|_->false)) "lease release failure disappeared";
  let retry_waiter,retry=C.request failed.next session(W.Release_file lease) |> Result.get_ok in
  let retry_physical=release_ticket retry.instructions in
  let old=(C.step retry.next(C.Completed(physical,W.Answered(Ok())))).next in
  check(C.reply(C.view old)retry_waiter=None) "old failed lease attempt settled a new release waiter";
  let admitted=(C.step old(C.Admitted(retry_physical,Id.Worker.Request_id.of_int64 5L))).next in
  let released=(C.step admitted(C.Completed(retry_physical,W.Answered(Ok())))).next in
  check(C.reply(C.view released)retry_waiter=Some(W.Answered(Ok()))) "exact physical file ACK did not settle waiter";
  check((match C.import_progress(C.view released)intent with Some(W.Imported imported)->W.import_preview imported=None|None->true|_->false))
    "import progress reissued a released preview capability"
;;

let test_import_cancelled_preview_properties () =
  let run actions =
    let issuer,raw,projection,session=fixture 889L in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let source:Logseq_db_types.Asset_import.t={operation=uuid "98000000-0000-4000-8000-000000000891";
      asset=uuid "98000000-0000-4000-8000-000000000892";target=graph;replace_reference=None;
      local_mutation=uuid "98000000-0000-4000-8000-000000000893";
      metadata_mutation=uuid "98000000-0000-4000-8000-000000000894";
      source_file="/tmp/synthetic-property-import.png";title="Synthetic property import";file_type="png"} in
    let intent=W.asset_import_intent session source |> Result.get_ok in
    let ticket,planned=C.request(ready I.binding projection)session(W.Import intent) |> Result.get_ok in
    let owner=fst(List.hd raw.baseline.state.sync.residents) in
    let asset=Logseq_db_types.Asset_descriptor.create ~uuid:source.asset ~source:(Managed None)
      ~current_checksum:(Some(String.make 64 'a')) ~size:(Some 4L) ~dimensions:None |> Result.get_ok in
    let receipt:Logseq_db_worker.import_receipt={operation=source.operation;graph_generation=owner.graph_generation;
      scope=owner;target=source.target;asset;file_type="png";preview=Some("property-lease","/tmp/synthetic-property-owned.png")} in
    let reply=checked_import_reply issuer session ticket intent receipt in
    let state=ref planned.next and releases=ref [] in
    let forgotten=ref false and admitted=ref false and success=ref false and stopped=ref false and ack=ref false in
    let apply event=
      let transition=C.step !state event in state:=transition.next;
      let release : C.instruction -> unit C.ticket option=function C.Send(ticket,_,W.Release_file _)->Some ticket|_->None in
      releases:= !releases @ List.filter_map release transition.instructions in
    List.iter(fun action->
      (match action mod 10 with
       |0->admitted:=true;apply(C.Admitted(ticket,Id.Worker.Request_id.one))
       |1|7->success:=true;apply(C.Completed(ticket,reply))
       |2->forgotten:=true;apply(C.Forget ticket)
       |3->apply(C.Cancel ticket)
       |4->stopped:=true;apply C.Shutdown_requested
       |5->apply(C.Binding_release_completed(I.binding,Ok()))
       |6->let waiting= !releases in releases:=[];List.iter(fun cleanup->
         apply(C.Admitted(cleanup,Id.Worker.Request_id.of_int64 20L));apply(C.Completed(cleanup,W.Answered(Ok())));ack:=true)waiting
       |8->apply(C.Projection_received projection)
       |_->apply C.Capacity_available);
      if !forgotten then check(C.reply(C.view !state)ticket=None) "forgotten import callback revived";
      if !stopped && !admitted && !success && not !ack
      then check(C.shutdown_state(C.view !state)<>C.Stopped) "shutdown consumed lease without its physical release ACK";
      if !admitted && (not !success || not !ack)
      then check(C.import_progress(C.view !state)intent<>None) "unsettled accepted import lost its stable recovery fact")actions
  in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions=
    let rec remove prefix=function []->actions
      | _::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      | action::rest->remove(action::prefix)rest in remove [] actions in
  let prefixes=[[0;2;1];[1;4;5;0];[0;4;1;5];[0;1;2;4];[4;1;0;5]] in
  for seed=0 to 99 do
    let random=Random.State.make[|0x1A90;seed|] in
    let actions=List.nth prefixes(seed mod List.length prefixes) @ List.init 40(fun _->Random.State.int random 10) in
    if fails actions then failwith(Printf.sprintf "import ownership seed=%d minimized=[%s]" seed
      (String.concat ";"(List.map string_of_int(shrink actions))))
  done
;;

let test_completed_imports_release_active_recovery_capacity () =
  let issuer,raw,projection,session=fixture 890L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let state=ref(ready I.binding projection) in
  let id n=uuid(Printf.sprintf "98000000-0000-4000-8000-%012d" n) in
  let source n:Logseq_db_types.Asset_import.t={operation=id(9000+4*n);asset=id(9001+4*n);target=graph;replace_reference=None;
    local_mutation=id(9002+4*n);metadata_mutation=id(9003+4*n);source_file="/tmp/synthetic-capacity.png";
    title="Synthetic capacity import";file_type="png"} in
  let owner=fst(List.hd raw.baseline.state.sync.residents) in
  for n=0 to 8199 do
    let source=source n in let intent=W.asset_import_intent session source |> Result.get_ok in
    let ticket,planned=match C.request !state session(W.Import intent) with Ok value->value
      |Error _->failwith(Printf.sprintf "returned Import proof history exhausted at operation %d" (n+1)) in
    let asset=Logseq_db_types.Asset_descriptor.create ~uuid:source.asset ~source:(Managed None)
      ~current_checksum:(Some(String.make 64 'a')) ~size:(Some 4L) ~dimensions:None |> Result.get_ok in
    let receipt:Logseq_db_worker.import_receipt={operation=source.operation;graph_generation=owner.graph_generation;
      scope=owner;target=source.target;asset;file_type="png";preview=None} in
    let reply=checked_import_reply issuer session ticket intent receipt in
    state:=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(n+1))))).next;
    state:=(C.step !state(C.Completed(ticket,reply))).next;
    state:=(C.step !state(C.Forget ticket)).next;
    if n>0 then (
      let proof=C.import_source_proof(C.view !state)intent |> Option.get in
      state:=(C.step !state(C.Import_source_proof_returned proof)).next)
  done;
  let changed=W.asset_import_intent session {(source 0)with target=client} |> Result.get_ok in
  check(Result.is_error(C.request !state session(W.Import changed))) "completed import history allowed operation payload substitution"
;;

let test_rejected_imports_release_capacity_after_fresh_readback () =
  let issuer,raw,projection,session=fixture 1890L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let state=ref(ready I.binding projection) in
  let id n=uuid(Printf.sprintf "97000000-0000-4000-8000-%012d" n) in
  let source n=
    {Logseq_db_types.Asset_import.operation=id(4*n);asset=id(4*n+1);target=graph;replace_reference=None;
     local_mutation=id(4*n+2);metadata_mutation=id(4*n+3);source_file="/tmp/synthetic-oversized.bin";
     title="Synthetic oversized input";file_type="bin"} in
  let intent n=W.asset_import_intent session(source n) |> Result.get_ok in
  let scope,_=List.hd raw.baseline.state.residents in
  let readback ticket original prepared=
    let operation=W.Confirm_import_source original in
    let request_id=match I.request session ~request_id:(C.ticket_id ticket)operation |> Result.get_ok with
      |S.Coordination_confirm_import_input{request_id;_}->request_id|_->assert false in
    I.reply session ~request_id:(C.ticket_id ticket)operation
      (S.Coordination_import_input_confirmed{registration=raw.registration;owner=scope;request_id;
       input=Some{Logseq_db_types.Asset_import.Recovery.sequence=1L;
         input=Bytes.to_string(W.encode_asset_import_intent original);prepared;acknowledged=false}}) |> Result.get_ok in
  let apply event=state:=(C.step !state event).next in
  let request operation=let ticket,planned=C.request !state session operation |> Result.get_ok in
    state:=planned.next;ticket in
  let complete : type a. a C.ticket -> a W.reply -> unit=fun ticket reply->
    apply(C.Admitted(ticket,Id.Worker.Request_id.one));apply(C.Completed(ticket,reply)) in
  let failure=W.Answered(Error(W.Service_failed "Synthetic pre-Prepared failure")) in
  for n=1 to 130 do
    let original=intent n in
    let ticket=try request(W.Import original) with _->failwith(Printf.sprintf "terminal rejected imports exhausted capacity at %d" n) in
    complete ticket failure;apply(C.Forget ticket);
    let read=request(W.Confirm_import_source original) in
    complete read(if n mod 2=0 then W.Answered(Ok None)else readback read original None);apply(C.Forget read);
    check(not(C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original)))
      "fresh absent readback after terminal failure retained a failed source"
  done;
  for n=131 to 260 do
    let ticket=request(W.Import(intent n)) in
    apply(C.Admission_refused(ticket,W.Not_ready));apply(C.Forget ticket)
  done;
  let original=intent 261 in
  let ticket=request(W.Import original) in
  complete ticket(W.Interrupted W.Transport_lost);apply(C.Forget ticket);
  let read=request(W.Confirm_import_source original) in
  complete read(W.Answered(Ok None));apply(C.Forget read);
  check(C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original))
    "absent readback after an interrupted handler discarded Unknown";
  let original=intent 262 in
  let ticket=request(W.Import original) in
  apply(C.Admitted(ticket,Id.Worker.Request_id.one));
  let old_read=request(W.Confirm_import_source original) in
  apply(C.Completed(ticket,failure));apply(C.Forget ticket);
  complete old_read(W.Answered(Ok None));apply(C.Forget old_read);
  check(C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original))
    "readback planned before terminal failure discarded possible Prepared";
  let read=request(W.Confirm_import_source original) in
  let retry=request(W.Import original) in
  complete retry failure;apply(C.Forget retry);
  complete read(W.Answered(Ok None));apply(C.Forget read);
  check(C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original))
    "old absent readback consumed a newer completed Import attempt";
  let read=request(W.Confirm_import_source original) in
  complete read(W.Answered(Ok None));apply(C.Forget read);
  check(not(C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original)))
    "new failed attempt could not obtain its own rejection readback";
  let original=intent 263 in
  let ticket=request(W.Import original) in
  complete ticket failure;apply(C.Forget ticket);
  let read=request(W.Confirm_import_source original) in
  let prepared_source=source 263 in
  let prepared=Logseq_db_types.Asset_upload_intent.prepare ~operation_id:prepared_source.operation
    ~origin:(Uri.to_string scope.account.managed_sync_origin) ~account:scope.account.user_id ~graph:scope.graph_id
    ~asset:prepared_source.asset ~version:(Logseq_db_types.Asset_descriptor.version ~checksum:(String.make 64 'a') ~file_type:"bin" |> Result.get_ok)
    ~title:prepared_source.title ~size:4L ~staged_file:"synthetic-prepared.bin" ~replace_reference:None ~target:prepared_source.target
    ~local_mutation:prepared_source.local_mutation ~metadata_mutation:prepared_source.metadata_mutation |> Result.get_ok in
  let late_absent=request(W.Confirm_import_source original) in
  complete read(readback read original(Some(Logseq_db_types.Asset_upload_intent.Pure_codec.encode prepared)));
  apply(C.Forget read);
  check(C.import_progress(C.view !state)original=Some W.Import_unknown
    && C.import_source_proof(C.view !state)original<>None)
    "normal handler error after Prepared was mistaken for a rejected import";
  complete late_absent(W.Answered(Ok None));apply(C.Forget late_absent);
  check(C.import_progress(C.view !state)original=Some W.Import_unknown
    && C.import_source_proof(C.view !state)original<>None)
    "late absent readback overrode already adopted Prepared evidence";
  List.iteri(fun i outcome->
    let original=intent(264+i) in
    let ticket=request(W.Import original) in
    complete ticket outcome;apply(C.Forget ticket);
    let read=request(W.Confirm_import_source original) in
    complete read(W.Answered(Ok None));apply(C.Forget read);
    check(C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original))
      "cancel, shutdown or protocol mismatch was treated as a terminal handler rejection")
    [W.Interrupted W.Cancelled;W.Interrupted W.Worker_stopped;
     W.Answered(Error(W.Protocol_mismatch "Synthetic unmatched response"))];
  let original=intent 268 in
  let ticket=request(W.Import original) in
  complete ticket failure;apply(C.Forget ticket);
  let substituted=W.asset_import_intent session{(source 268)with target=client} |> Result.get_ok in
  let read=request(W.Confirm_import_source substituted) in
  complete read(W.Answered(Ok None));apply(C.Forget read);
  check(C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original))
    "same UUID with a different immutable input retired the original source";
  let original=intent 269 in
  let first=request(W.Import original) in
  complete first failure;
  let read=request(W.Confirm_import_source original) in
  complete read(W.Answered(Ok None));apply(C.Forget read);
  check((match C.import_progress(C.view !state)original with Some(W.Import_rejected _)->true|_->false))
    "first terminal failure did not become an actual rejection";
  let retry=request(W.Import original) in
  complete retry failure;apply(C.Forget retry);apply(C.Forget first);
  check(C.import_progress(C.view !state)original=Some W.Import_unknown
    && C.import_source_pending(C.view !state) ~operation:(W.asset_import_intent_id original))
    "new Import attempt inherited a live previous ticket's rejection"
;;

let test_new_host_source_proof_retires_only_identical_unknown () =
  let first,_,projection,session=fixture 891L in
  let module I=(val first:Worker_effect_authority.ISSUER) in
  let source:Logseq_db_types.Asset_import.t={operation=uuid "98000000-0000-4000-8000-000000001891";
    asset=uuid "98000000-0000-4000-8000-000000001892";target=graph;replace_reference=None;
    local_mutation=uuid "98000000-0000-4000-8000-000000001893";metadata_mutation=uuid "98000000-0000-4000-8000-000000001894";
    source_file="/tmp/synthetic-original-owned-source.png";title="Synthetic source ownership";file_type="png"} in
  let intent=W.asset_import_intent session source |> Result.get_ok in
  let ticket,planned=C.request(ready I.binding projection)session(W.Import intent) |> Result.get_ok in
  let old=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
  let old=(C.step old(C.Completed(ticket,W.Interrupted W.Transport_lost))).next in
  let old=(C.step old(C.Forget ticket)).next in
  let old=(C.step old C.Shutdown_requested).next in
  let old=(C.step old(C.Binding_release_completed(I.binding,Ok()))).next in
  check(C.shutdown_state(C.view old)=C.Stopped && C.import_sources_pending(C.view old) ~owner:None)
    "old stopped host did not preserve original Unknown source";
  let second,raw,next_projection,next_session=fixture ~graph_generation:99 892L in
  let module N=(val second:Worker_effect_authority.ISSUER) in
  let next_intent=W.restore_asset_import_intent next_session(W.encode_asset_import_intent intent) |> Result.get_ok in
  let make_proof intent target=
    let ticket,plan=C.request(ready N.binding next_projection)next_session(W.Import intent) |> Result.get_ok in
    let owner=fst(List.hd raw.baseline.state.sync.residents) in
    let asset=Logseq_db_types.Asset_descriptor.create ~uuid:source.asset ~source:(Managed None)
      ~current_checksum:(Some(String.make 64 'a')) ~size:(Some 4L) ~dimensions:None |> Result.get_ok in
    let receipt:Logseq_db_worker.import_receipt={operation=source.operation;graph_generation=owner.graph_generation;scope=owner;
      target;asset;file_type="png";preview=None} in
    let reply=checked_import_reply second next_session ticket intent receipt in
    let next=(C.step plan.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
    let next=(C.step next(C.Completed(ticket,reply))).next in
    let next=(C.step next(C.Forget ticket)).next in
    C.import_source_proof(C.view next)intent |> Option.get in
  let wrong=W.asset_import_intent next_session {source with target=client} |> Result.get_ok in
  let ignored=(C.step old(C.Import_source_reconciled(make_proof wrong client))).next in
  check(C.import_sources_pending(C.view ignored) ~owner:None) "same UUID different payload retired an unrelated source";
  let proof=make_proof next_intent source.target in
  let reconciled=(C.step ignored(C.Import_source_reconciled proof)).next in
  check(not(C.import_sources_pending(C.view reconciled) ~owner:None))
    "new host's exact durable source proof stranded old Unknown source ownership";
  check(Rrbvec.is_empty(C.completed_import_source_proofs(C.view reconciled)))
    "an old recipient duplicated the provider's disposable proof history";
  check(C.import_progress(C.view reconciled)intent=Some W.Import_unknown)
    "source adoption rewrote an unknown durable import result";
  check(C.equal_view(C.view reconciled)(C.view(C.step reconciled(C.Import_source_reconciled proof)).next))
    "duplicate source proof changed the old stopped host"
;;

let test_import_proof_consumption_properties () =
  let run actions =
    let issuer,raw,projection,session=fixture 893L in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let id n=uuid(Printf.sprintf "98000000-0000-4000-8000-%012d" n) in
    let source:Logseq_db_types.Asset_import.t={operation=id 18931;asset=id 18932;target=graph;replace_reference=None;
      local_mutation=id 18933;metadata_mutation=id 18934;source_file="/tmp/synthetic-cross-host-input.png";
      title="Synthetic source proof";file_type="png"} in
    let intent=W.asset_import_intent session source |> Result.get_ok in
    let pending client_id=
      let initial=(C.step(C.initial ~client_id)(C.Worker_bound I.binding)).next in
      let initial=(C.step initial(C.Bootstrap_received(I.binding,W.Ready projection))).next in
      let ticket,planned=C.request initial session(W.Import intent) |> Result.get_ok in
      ticket,ref(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
    let first,one=pending(id 18935) and second,two=pending(id 18936) in
    let ticket,planned=C.request(ready I.binding projection)session(W.Import intent) |> Result.get_ok in
    let owner=fst(List.hd raw.baseline.state.sync.residents) in
    let asset=Logseq_db_types.Asset_descriptor.create ~uuid:source.asset ~source:(Managed None)
      ~current_checksum:(Some(String.make 64 'b')) ~size:(Some 4L) ~dimensions:None |> Result.get_ok in
    let receipt:Logseq_db_worker.import_receipt={operation=source.operation;graph_generation=owner.graph_generation;
      scope=owner;target=source.target;asset;file_type="png";preview=None} in
    let created=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
    let created=(C.step created(C.Completed(ticket,checked_import_reply issuer session ticket intent receipt))).next in
    let provider=ref(C.step created(C.Forget ticket)).next in
    let proof=C.import_source_proof(C.view !provider)intent |> Option.get in
    let delivered=Array.make 2 false and terminal=Array.make 2 false in
    let views()=Rrbvec.of_list[C.view !one;C.view !two;C.view !provider] in
    List.iter(fun action->
      let which=(action/2)mod 2 in
      let state,ticket=if which=0 then one,first else two,second in
      if action mod 2=0 && not delivered.(which) then (
        delivered.(which)<-true;state:=(C.step !state(C.Import_source_reconciled proof)).next)
      else if action mod 2=1 && not terminal.(which) then (
        terminal.(which)<-true;state:=(C.step !state(C.Completed(ticket,W.Interrupted W.Transport_lost))).next;
        state:=(C.step !state(C.Forget ticket)).next);
      let consumed=C.import_source_proof_consumed proof(views()) in
      check(consumed=(delivered.(0)&&delivered.(1))) "proof return skipped an old Host acknowledgement";
      if consumed then provider:=(C.step !provider(C.Import_source_proof_returned proof)).next;
      check((C.import_source_proof(C.view !provider)intent=None)=consumed) "provider lost an unconfirmed proof";
      List.iter(fun state->check(Rrbvec.is_empty(C.completed_import_source_proofs(C.view !state)))
        "proof recipients duplicated history")[one;two])actions;
    List.iteri(fun which state->if terminal.(which) then
      check(C.import_progress(C.view !state)intent=Some W.Import_unknown)
        "proof consumption erased an Unknown durable outcome")[one;two]
  in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions=
    let rec remove prefix=function []->actions
      |_::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      |x::rest->remove(x::prefix)rest in remove [] actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0x1A95;seed|] in
    let actions=List.init 30(fun _->Random.State.int random 4)@[0;1;2;3] in
    if fails actions then failwith(Printf.sprintf "Import proof consumption seed=%d shrunk=[%s]" seed
      (String.concat ";"(List.map string_of_int(shrink actions))))
  done
;;

(* The issuer may observe a later baseline before Core handles its queued
   event. The pure plan pins the original owner/version; no closure may retarget
   the host action at whatever happens to be latest. Physical settlement is
   proved by the real Service tests, not by this validation fixture. *)
let test_host_prepare_waits_for_exact_legacy_owner () =
  let issuer,raw,projection,session=fixture 9881L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let initial=ready I.binding projection in
  let id,waiting=C.prepare_host_change ~legacy_pending:true initial
      (W.Graph_will_close(W.graph_id session)) |> Result.get_ok in
  let sent transition=List.exists(function C.Quiesce _->true|_->false)transition.C.instructions in
  check(not(sent waiting))"legacy retirement was skipped before actual Worker quiescence";
  let owner:S.timeline_scope={startup={account_generation=(Option.get raw.baseline.state.sync.account).account_generation;
    presentation_generation=1};graph_id=W.graph_id session;graph_generation=(List.hd raw.baseline.state.residents |> fst).graph_generation} in
  check(C.host_change_blocks waiting.next ~owner)"legacy admission remained open during its join";
  check(C.validate_session waiting.next session=Error W.Host_change_in_progress)
    "waiting for legacy IO left ordinary admission open";
  let wrong=C.step waiting.next(C.Legacy_handoff_completed
    (W.handoff_id(uuid "98000000-0000-4000-8000-000000009999"),Ok())) in
  check(not(sent wrong))"foreign legacy retirement ACK unlocked a new handoff";
  let latest=match I.bootstrap(S.Coordination_registered{raw with baseline={raw.baseline with version=2L}}) |> Result.get_ok with
    |W.Ready value->value|_->assert false in
  let advanced=(C.step wrong.next(C.Projection_received latest)).next in
  let released=C.step advanced(C.Legacy_handoff_completed(id,Ok())) in
  let plan=List.find_map(function C.Quiesce plan->Some plan|_->None)released.instructions |> Option.get in
  let request=match I.handoff_request plan |> Result.get_ok with S.Coordination_prepare_host_change value->value|_->assert false in
  check(request.version=2L)"coordinator ignored the serialized metadata baseline while joining legacy IO";
  check(W.matches_asset_scope session(Rrbvec.nth request.expected 0))"legacy join retargeted the execution owner";
  let repeated=C.step released.next(C.Legacy_handoff_completed(id,Ok())) in
  check(not(sent repeated))"duplicate legacy ACK sent another backend prepare";
  let scope,physical=List.hd raw.baseline.state.residents in
  let replacement={scope with graph_generation=scope.graph_generation+1} in
  let replaced={raw with baseline={raw.baseline with version=3L;
    state={residents=[replacement,{physical with generation=replacement.graph_generation}];
      sync={raw.baseline.state.sync with selected=None;residents=List.map(fun(_,state)->replacement,
        {state with Sync.snapshot={state.Sync.snapshot with startup={state.snapshot.startup with
          graph_generation=replacement.graph_generation}}})raw.baseline.state.sync.residents}}}} in
  let replaced=match I.bootstrap(S.Coordination_registered replaced) |> Result.get_ok with
    |W.Ready value->value|_->assert false in
  let changed=(C.step waiting.next(C.Projection_received replaced)).next in
  let stale=C.step changed(C.Legacy_handoff_completed(id,Ok())) in
  check(not(sent stale))"old legacy ACK retargeted preparation to a reopened execution";
  check(match C.handoff(C.view stale.next)id with Some(W.Handoff_failed _)->true|_->false)
    "execution replacement while joining did not revoke the original round";
  let failed=C.step waiting.next(C.Legacy_handoff_completed(id,Error(W.Service_failed "cleanup failed"))) in
  check(not(sent failed))"failed real cleanup was treated as an ACK";
  check(C.host_change_blocks failed.next ~owner)"cleanup failure reopened legacy admission"
;;

let test_host_consumption_keeps_old_execution_retired () =
  let issuer,raw,projection,session=fixture 9873L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let initial=ready I.binding projection in
  let id,prepared=C.prepare_host_change initial(W.Graph_will_close(W.graph_id session)) |> Result.get_ok in
  let plan=List.find_map(function C.Quiesce plan->Some plan|_->None)prepared.instructions |> Option.get in
  let request=match I.handoff_request plan |> Result.get_ok with
    |S.Coordination_prepare_host_change value->value|_->assert false in
  let module H=Logseq_db_worker_pure_reducer.Core.Host_handoff in
  let facts:H.facts={authenticated=false;version=request.version;registration=Some request.registration;
    account=Some request.owner;scopes=request.expected;catalog=Rrbvec.singleton(W.graph_id session)} in
  let backend:H.request={version=request.version;id=request.id;registration=request.registration;
    owner=request.owner;change=request.change;expected=request.expected;captured=request.expected} in
  let pending,admission=H.prepare(H.empty ~lifetime:(uuid "98000000-0000-4000-8000-000000009873"))facts backend in
  let attempt=match admission with H.Start value->value|_->assert false in
  let safe=H.settled pending attempt ~copy_generation:None in
  let actual=match H.phase safe request.id with Some(H.Safe value)->value|_->assert false in
  let receipt=I.handoff_receipt plan(S.Coordination_host_prepared actual) |> Result.get_ok in
  let retiring=(C.step prepared.next C.Shutdown_requested).next in
  let late=(C.step retiring(C.Handoff_completed(id,W.Safe_to_proceed receipt))).next in
  check(match C.handoff(C.view late)id with Some(W.Safe_to_proceed _)->false|_->true)
    "late physical receipt published Safe after local retirement";
  let safe=(C.step prepared.next(C.Handoff_completed(id,W.Safe_to_proceed receipt))).next in
  let consuming=C.authorize_host_change safe receipt |> Result.get_ok in
  check(Result.is_error(C.authorize_host_change consuming.next receipt))"same permission planned a second consume";
  let attempt=List.find_map(function C.Consume_handoff(_,attempt)->Some attempt|_->None)consuming.instructions |> Option.get in
  let full=(C.step consuming.next(C.Handoff_apply_not_admitted(id,attempt,W.Full))).next in
  let retiring=(C.step full C.Shutdown_requested).next in
  let after_capacity=C.step retiring C.Capacity_available in
  check(not(List.exists(function C.Consume_handoff _->true|_->false)after_capacity.instructions))
    "unadmitted host action retried after retirement";
  let retry=C.step full C.Capacity_available in
  let retry_attempt=List.find_map(function C.Consume_handoff(_,attempt)->Some attempt|_->None)retry.instructions |> Option.get in
  check(W.compare_request_id attempt retry_attempt<>0)"Full retry reused the old admission attempt";
  let retry_mailbox=Id.Worker.Request_id.of_int64 9874L in
  let admitted_retry=(C.step retry.next(C.Handoff_apply_admitted(id,retry_attempt,retry_mailbox))).next in
  let old_full=(C.step admitted_retry(C.Handoff_apply_not_admitted(id,attempt,W.Full))).next in
  check(not(List.exists(function C.Consume_handoff _->true|_->false)(C.step old_full C.Capacity_available).instructions))
    "old Full retargeted an already accepted newer consume attempt";
  let early=(C.step retry.next(C.Handoff_applied(id,retry_attempt,retry_mailbox,Ok()))).next in
  check(match C.handoff(C.view early)id with Some(W.Applying_host_change _)->true|_->false)
    "early host completion fabricated admission before its mailbox ACK";
  let early_admitted=(C.step early(C.Handoff_apply_admitted(id,retry_attempt,retry_mailbox))).next in
  check(match C.handoff(C.view early_admitted)id with Some(W.Host_change_applied _)->true|_->false)
    "matching late admission lost the actual early terminal result";
  let mailbox=Id.Worker.Request_id.of_int64 9873L in
  let admitted=(C.step consuming.next(C.Handoff_apply_admitted(id,attempt,mailbox))).next in
  let applied=(C.step admitted(C.Handoff_applied(id,attempt,mailbox,Ok()))).next in
  let retiring_admitted=(C.step admitted C.Shutdown_requested).next in
  let settled_retired=(C.step retiring_admitted(C.Handoff_applied(id,attempt,mailbox,Ok()))).next in
  check(match C.handoff(C.view settled_retired)id with Some(W.Host_change_applied _)->true|_->false)
    "retirement discarded the terminal evidence of an actually admitted host action";
  check(C.validate_session applied session=Error W.Revoked_session)
    "old baseline revived its retired execution after consume ACK";
  let scope,physical=List.hd raw.baseline.state.residents in
  let next_scope={scope with graph_generation=scope.graph_generation+1} in
  let next_raw={raw with baseline={raw.baseline with version=3L;
    state={residents=[next_scope,{physical with generation=next_scope.graph_generation}];
      sync={raw.baseline.state.sync with residents=List.map(fun(_,state)->next_scope,
        {state with Sync.snapshot={state.Sync.snapshot with startup={state.snapshot.startup with graph_generation=next_scope.graph_generation}}})raw.baseline.state.sync.residents;
        selected=None}}}} in
  let reopened=match I.bootstrap(S.Coordination_registered next_raw) |> Result.get_ok with
    |W.Ready projection->projection|_->failwith "new host generation fixture" in
  let resumed=(C.step applied(C.Projection_received reopened)).next in
  let new_session=(List.hd(W.residents reopened)).session in
  check(C.validate_session resumed new_session=Ok())"completed graph close fenced a future execution forever";
  check(Result.is_error(C.authorize_host_change resumed receipt))"old safe receipt consumed against a reopened execution"
;;

(* Repeated user close/reopen uses new authoritative graph generations. The
   public pure boundary owns the admission history, so no I/O duplicate test. *)
let test_repeated_graph_close_reopen_does_not_exhaust_handoff_history () =
  let issuer,raw,projection,session=fixture 9875L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let state=ref(ready I.binding projection) in
  let old_receipts=ref [] in
  for round=0 to 95 do
    let id,prepared=match C.prepare_host_change !state(W.Graph_will_close(W.graph_id session)) with
      |Ok value->value|Error _->failwith(Printf.sprintf "ordinary close/reopen refused at round %d" round) in
    let plan=List.find_map(function C.Quiesce plan->Some plan|_->None)prepared.instructions |> Option.get in
    let receipt=pure_host_receipt_fixture issuer plan in
    let safe=(C.step prepared.next(C.Handoff_completed(id,W.Safe_to_proceed receipt))).next in
    let consuming=C.authorize_host_change safe receipt |> Result.get_ok in
    let attempt=List.find_map(function C.Consume_handoff(_,attempt)->Some attempt|_->None)consuming.instructions |> Option.get in
    let mailbox=Id.Worker.Request_id.of_int64(Int64.of_int(10000+round)) in
    let admitted=(C.step consuming.next(C.Handoff_apply_admitted(id,attempt,mailbox))).next in
    let applied=(C.step admitted(C.Handoff_applied(id,attempt,mailbox,Ok()))).next in
    let current=(List.hd(W.residents(Option.get(C.projection(C.view admitted))))).session in
    check(C.validate_session applied current=Error W.Revoked_session) "close ACK revived its old execution";
    let scope,physical=List.hd raw.baseline.state.residents in
    let generation=scope.graph_generation+round+1 in
    let scope={scope with graph_generation=generation} in
    let next_raw={raw with baseline={raw.baseline with version=Int64.of_int(3+round);
      state={residents=[scope,{physical with generation}];sync={raw.baseline.state.sync with
        residents=List.map(fun(_,s)->scope,{s with Sync.snapshot={s.Sync.snapshot with
          startup={s.snapshot.startup with graph_generation=generation}}})raw.baseline.state.sync.residents;
        selected=None}}}} in
    let reopened=match I.bootstrap(S.Coordination_registered next_raw) |> Result.get_ok with
      |W.Ready projection->projection|_->failwith "invalid reopened fixture" in
    state:=(C.step applied(C.Projection_received reopened)).next;
    let current=(List.hd(W.residents reopened)).session in
    check(C.validate_session !state current=Ok()) "new graph generation remained fenced";
    List.iter(fun old->check(Result.is_error(C.authorize_host_change !state old))
      "retired success receipt acquired another round") (receipt::!old_receipts);
    old_receipts:=receipt::!old_receipts
  done
;;

let test_determined_failed_handoff_retires_when_user_retries () =
  let issuer,_,projection,session=fixture 9876L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  List.iter(fun legacy->
    let state=ref(ready I.binding projection) and previous=ref None in
    for _round=0 to 95 do
      let change=W.Graph_will_close(W.graph_id session) in
      let id,prepared=C.prepare_host_change ~legacy_pending:legacy !state change |> Result.get_ok in
      Option.iter(fun old->check(C.handoff(C.view prepared.next)old=None)
        "new Retry retained a determined inactive failure forever")!previous;
      let error=W.Service_failed "synthetic actual cleanup failed" in
      let failed=C.step prepared.next(if legacy then C.Legacy_handoff_completed(id,Error error)
        else C.Handoff_completed(id,W.Handoff_failed(change,error))) in
      check(C.handoff(C.view failed.next)id=Some(W.Handoff_failed(change,error)))
        "cleanup failure disappeared before its observer";
      state:=failed.next;previous:=Some id
    done)[false;true];
  let bound=(C.step(C.initial ~client_id:(uuid "98000000-0000-4000-8000-000000009876"))
    (C.Worker_bound I.binding)).next in
  let change=W.Connection_will_stop in
  let error=W.Service_failed "Synthetic registration terminated before its first baseline" in
  List.iter(fun terminal->
    let stopped=(C.step bound(C.Bootstrap_received(I.binding,terminal))).next in
    check(C.prepare_host_change stopped change=Error error)
      "terminal registration without Ready admitted an unfinishable host handoff";
    let id,waiting=C.prepare_host_change ~legacy_pending:true bound change |> Result.get_ok in
    check(not(List.exists(function C.Quiesce _->true|_->false)waiting.instructions))
      "Awaiting registration fabricated an authoritative host plan";
    let failed=C.step waiting.next(C.Bootstrap_received(I.binding,terminal)) in
    check(C.handoff(C.view failed.next)id=Some(W.Handoff_failed(change,error)))
      "registration terminal left an existing quit handoff Quiescing forever";
    check(not(List.exists(function C.Quiesce _|Consume_handoff _->true|_->false)failed.instructions))
      "registration failure fabricated a cleanup ACK or host permission")
    [W.Bootstrap_failed error;W.Binding_revoked error];
  let id,waiting=C.prepare_host_change bound change |> Result.get_ok in
  let resumed=C.step waiting.next(C.Bootstrap_received(I.binding,W.Ready projection)) in
  check(C.handoff(C.view resumed.next)id=Some(W.Quiescing change)
    && List.exists(function C.Quiesce _->true|_->false)resumed.instructions)
    "a healthy delayed first baseline could not complete its original handoff plan"

;;

let test_account_host_unknown_requires_original_consumption_readback () =
  let issuer,_,projection,_=fixture 9878L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let module H=Logseq_db_worker_pure_reducer.Core.Host_handoff in
  List.iter(fun change->
    let id,prepared=C.prepare_host_change(ready I.binding projection)change |> Result.get_ok in
    let plan=List.find_map(function C.Quiesce plan->Some plan|_->None)prepared.instructions |> Option.get in
    let request=match I.handoff_request plan |> Result.get_ok with
      |S.Coordination_prepare_host_change value->value|_->assert false in
    let facts:H.facts={authenticated=true;version=request.version;registration=Some request.registration;
      account=Some request.owner;scopes=request.expected;catalog=Rrbvec.empty} in
    let backend:H.request={version=request.version;id=request.id;registration=request.registration;
      owner=request.owner;change=request.change;expected=request.expected;captured=request.expected} in
    let pending,admission=H.prepare(H.empty ~lifetime:(uuid "98000000-0000-4000-8000-000000009878"))facts backend in
    let safe=H.settled pending (match admission with H.Start value->value|_->assert false) ~copy_generation:None in
    let actual=match H.phase safe request.id with Some(H.Safe value)->value|_->assert false in
    let receipt=I.handoff_receipt plan(S.Coordination_host_prepared actual) |> Result.get_ok in
    let safe=(C.step prepared.next(C.Handoff_completed(id,W.Safe_to_proceed receipt))).next in
    let consuming=C.authorize_host_change safe receipt |> Result.get_ok in
    let attempt=List.find_map(function C.Consume_handoff(_,attempt)->Some attempt|_->None)consuming.instructions |> Option.get in
    let mailbox=Id.Worker.Request_id.of_int64 9878L in
    let admitted=(C.step consuming.next(C.Handoff_apply_admitted(id,attempt,mailbox))).next in
    let unknown=C.step admitted(C.Handoff_applied(id,attempt,mailbox,Error(W.Service_failed "transport outcome unknown"))) in
    check(match C.handoff(C.view unknown.next)id with Some(W.Applying_host_change _)->true|_->false)
      "unknown accepted account/stop action ended before authoritative consumption readback";
    check(not(List.exists(function C.Consume_handoff _->true|_->false)unknown.instructions))
      "accepted unknown host action replayed its permission";
    let original,confirmation=List.find_map(function C.Confirm_handoff(receipt,attempt)->Some(receipt,attempt)|_->None)
      unknown.instructions |> Option.get in
    check(original=receipt)"readback lost the exact original opaque receipt";
    let readback=Id.Worker.Request_id.of_int64 9879L in
    let confirmed=(C.step unknown.next(C.Handoff_confirm_admitted(id,confirmation,readback))).next in
    let foreign=(C.step confirmed(C.Handoff_confirmed(id,confirmation,Some mailbox,Ok true))).next in
    check(match C.handoff(C.view foreign)id with Some(W.Applying_host_change _)->true|_->false)
      "foreign readback mailbox completed the host action";
    let applied=(C.step foreign(C.Handoff_confirmed(id,confirmation,Some readback,Ok true))).next in
    check(match C.handoff(C.view applied)id with Some(W.Host_change_applied _)->true|_->false)
      "actual consumed readback did not finish the original host action";
    let duplicate=(C.step applied(C.Handoff_confirmed(id,confirmation,Some readback,Ok false))).next in
    check(match C.handoff(C.view duplicate)id with Some(W.Host_change_applied _)->true|_->false)
      "late false readback erased the real consumed fact";
    let absent=(C.step confirmed(C.Handoff_confirmed(id,confirmation,Some readback,Ok false))).next in
    check(C.handoff_restartable(C.view absent)id)"definitely unconsumed action could not retire its binding";
    check(not(C.handoff_restartable(C.view applied)id))"consumed host action became restartable";
    let unavailable=(C.step confirmed(C.Handoff_confirmed(id,confirmation,Some readback,Error W.Revoked_session))).next in
    check(not(C.handoff_restartable(C.view unavailable)id))"unavailable readback was treated as absence";
    let same,retry=C.prepare_host_change unavailable change |> Result.get_ok in
    check(W.equal_handoff_id id same)"unknown readback retry minted a different permission round";
    check(List.exists(function C.Confirm_handoff(actual,_)->actual=receipt|_->false)retry.instructions)
      "unknown retry did not query the exact original receipt";
    check(not(List.exists(function C.Quiesce _|Consume_handoff _->true|_->false)retry.instructions))
      "unknown host retry prepared or consumed another permission";
    let full=(C.step unknown.next(C.Handoff_confirm_not_admitted(id,confirmation,W.Full))).next in
    let retry=C.step full C.Capacity_available in
    let newer=List.find_map(function C.Confirm_handoff(_,attempt)->Some attempt|_->None)retry.instructions |> Option.get in
    check(W.compare_request_id newer confirmation<>0)"readback capacity retry reused its old attempt";
    let stale=(C.step retry.next(C.Handoff_confirmed(id,confirmation,Some readback,Ok false))).next in
    check(not(C.handoff_restartable(C.view stale)id))"old false readback overrode a newer pending attempt")
    [W.Account_will_change;W.Connection_will_stop]
;;

let test_host_plan_pins_original_authoritative_frame () =
  let issuer,raw,projection,session=fixture 9871L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let id=W.handoff_id(uuid "98000000-0000-4000-8000-000000009871") in
  let plan=W.host_change_plan projection ~handoff_id:id
    ~change:(W.Graph_will_close(W.graph_id session)) ~sessions:(Rrbvec.singleton session) |> Result.get_ok in
  let _=I.bootstrap(S.Coordination_registered{raw with baseline={raw.baseline with version=2L}}) |> Result.get_ok in
  let request=match I.handoff_request plan |> Result.get_ok with
    |S.Coordination_prepare_host_change request->request|_->failwith "host plan bypassed actual Service" in
  check(request.version=raw.baseline.version)"issuer retargeted host preparation at a later version";
  check(Rrbvec.length request.expected=1 && W.matches_asset_scope session(Rrbvec.nth request.expected 0))
    "issuer replaced planned execution owner";
  let module H=Logseq_db_worker_pure_reducer.Core.Host_handoff in
  let facts:H.facts={authenticated=false;version=request.version;registration=Some request.registration;
    account=Some request.owner;scopes=request.expected;catalog=Rrbvec.singleton(W.graph_id session)} in
  let backend:H.request={version=request.version;id=request.id;registration=request.registration;
    owner=request.owner;change=request.change;expected=request.expected;captured=request.expected} in
  let pending,admission=H.prepare(H.empty ~lifetime:(uuid "98000000-0000-4000-8000-000000009870"))facts backend in
  let attempt=match admission with H.Start value->value|_->failwith "invalid pure host validation fixture" in
  let safe=H.settled pending attempt ~copy_generation:None in
  let actual=match H.phase safe request.id with Some(H.Safe value)->value|_->assert false in
  let receipt=I.handoff_receipt plan(S.Coordination_host_prepared actual) |> Result.get_ok in
  check(W.valid_handoff_receipt plan receipt)"matching actual backend receipt was rejected";
  check(W.equal_handoff_id id(W.handoff_receipt_id receipt))"handoff identity drifted";
  let foreign=W.host_change_plan projection
    ~handoff_id:(W.handoff_id(uuid "98000000-0000-4000-8000-000000009872"))
    ~change:(W.Graph_will_close(W.graph_id session)) ~sessions:(Rrbvec.singleton session) |> Result.get_ok in
  check(not(W.valid_handoff_receipt foreign receipt))"foreign round accepted a retained safe receipt";
  check(Result.is_error(I.handoff_receipt foreign(S.Coordination_host_prepared actual)))
    "issuer reassociated an old physical receipt with a fresh round"
;;

let test_query_origin_boundary () =
  let issuer, raw, projection, session = fixture 310L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let owner = Option.get raw.baseline.state.sync.selected in
  let ticket, waiting =
    C.plan_query state ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  check
    (C.query_origin (C.view waiting.next) ticket = None)
    "queued read fabricated execution origin";
  let sent = C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection)) in
  (match C.query_origin (C.view sent.next) ticket with
   | Some (actual, budget) ->
     check (W.equal_session actual session) "queued read origin changed session";
     check
       (W.validate_request actual (W.Query (budget, W.Graph_info)) = Ok ())
       "origin budget differs from actual Send"
   | None -> failwith "actual Send lost execution origin");
  check
    (C.validate_session
       ~owner:{ owner with graph_id = uuid "98000000-0000-4000-8000-000000000099" }
       sent.next
       session
     = Error W.Revoked_session)
    "foreign business graph accepted cached execution origin";
  check
    (C.validate_session sent.next session = Ok ())
    "Open origin cannot resume cached data";
  let _, closing =
    C.prepare_host_change sent.next (W.Graph_will_close (W.graph_id session))
    |> Result.get_ok
  in
  check
    (C.validate_session closing.next session = Error W.Host_change_in_progress)
    "handoff fence allowed cached read";
  let forgotten = C.step sent.next (C.Forget ticket) in
  check
    (C.query_origin (C.view forgotten.next) ticket = None)
    "forgotten ticket retained public origin";
  check
    (C.query_origin (C.view sent.next) ticket <> None)
    "origin lookup mutated preceding state"
;;

let test_bootstrap_validation () =
  let issuer, raw, projection, _ = fixture 101L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let empty =
    { raw with
      baseline =
        { raw.baseline with
          version = 0L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  account = None
                ; desired_residents = []
                ; residents = []
                ; selected = None
                }
            ; residents = []
            }
        }
    }
  in
  (match I.bootstrap (S.Coordination_registered empty) with
   | Ok (W.Ready current) ->
     check (W.equal_projection current projection) "old baseline replaced Ready"
   | _ -> failwith "old not-ready/revocation beat newer Ready");
  let malformed =
    [ (fun (b : S.coordination_baseline) ->
        { b with limits = { b.limits with change_max_bytes = 0 } })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  residents = b.baseline.state.residents @ b.baseline.state.residents
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  sync = { b.baseline.state.sync with desired_residents = [] }
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  residents =
                    List.map
                      (fun (scope, g) ->
                         scope, { g with Logseq_db_worker.generation = 8 })
                      b.baseline.state.residents
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  sync =
                    { b.baseline.state.sync with
                      selected =
                        Option.map
                          (fun (owner : S.timeline_scope) ->
                             { owner with graph_generation = 8 })
                          b.baseline.state.sync.selected
                    }
                }
            }
        })
    ]
  in
  List.iteri
    (fun n corrupt ->
       let issuer, raw, _, _ = fixture (Int64.of_int (200 + n)) in
       let module I = (val issuer : Worker_effect_authority.ISSUER) in
       let bad = corrupt { raw with baseline = { raw.baseline with version = 2L } } in
       match I.bootstrap (S.Coordination_registered bad) with
       | Error (W.Protocol_mismatch _) -> ()
       | _ -> failwith "malformed baseline issued authority")
    malformed
;;

type action =
  | Plan
  | Admit of int
  | Answer of int
  | Cancel of int
  | Forget of int
  | Refuse of int
  | Retry
  | Old_baseline
  | Stop
  | Release_ack

let show = function
  | Plan -> "plan"
  | Admit n -> "admit" ^ string_of_int n
  | Answer n -> "answer" ^ string_of_int n
  | Cancel n -> "cancel" ^ string_of_int n
  | Forget n -> "forget" ^ string_of_int n
  | Refuse n -> "refuse" ^ string_of_int n
  | Retry -> "retry"
  | Old_baseline -> "old"
  | Stop -> "stop"
  | Release_ack -> "release-ack"
;;

let remove_chunk values start count =
  List.filteri (fun i _ -> i < start || i >= start + count) values
;;

let shrink fails trace =
  let rec go trace chunk =
    if chunk = 0
    then trace
    else (
      let rec find offset =
        if offset >= List.length trace
        then go trace (chunk / 2)
        else (
          let candidate = remove_chunk trace offset chunk in
          if fails candidate then go candidate chunk else find (offset + 1))
      in
      find 0)
  in
  go trace (max 1 (List.length trace / 2))
;;

let test_pure_properties () =
  let issuer, _, projection, session = fixture 400L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:10 ~maximum_bytes:65536 |> Result.get_ok
  in
  let run trace =
    let state = ref (ready I.binding projection)
    and tickets = ref [] in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "same pure input produced different state";
      check (C.equal_view before (C.view !state)) "step mutated its input snapshot";
      check (List.length a.instructions < 1000) "unbounded instruction batch";
      state := a.next
    in
    let with_ticket n f =
      match List.nth_opt !tickets (n mod 8) with
      | None -> ()
      | Some ticket -> f ticket
    in
    List.iter
      (function
        | Plan ->
          (match C.request !state session (W.Query (budget, W.Graph_info)) with
           | Error _ -> ()
           | Ok (ticket, a) ->
             let _, b =
               C.request !state session (W.Query (budget, W.Graph_info)) |> Result.get_ok
             in
             check
               (C.equal_view (C.view a.next) (C.view b.next))
               "planning is nondeterministic";
             tickets := ticket :: List.filteri (fun i _ -> i < 7) !tickets;
             state := a.next)
        | Admit n ->
          with_ticket n (fun ticket ->
            step
              (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
        | Answer n ->
          with_ticket n (fun ticket ->
            step (C.Completed (ticket, W.Interrupted W.Cancelled));
            let once = C.view !state in
            step (C.Completed (ticket, W.Answered (Error (W.Service_failed "duplicate"))));
            check (C.equal_view once (C.view !state)) "terminal delivered more than once")
        | Cancel n -> with_ticket n (fun ticket -> step (C.Cancel ticket))
        | Forget n ->
          with_ticket n (fun ticket ->
            step (C.Forget ticket);
            check (C.reply (C.view !state) ticket = None) "forgotten result resurfaced")
        | Refuse n ->
          with_ticket n (fun ticket -> step (C.Admission_refused (ticket, W.Full)))
        | Retry ->
          step C.Retry_bootstrap;
          check
            (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
            "retry retained session admission"
        | Old_baseline ->
          step (C.Bootstrap_received (I.binding, W.Ready projection));
          if C.shutdown_state (C.view !state) <> C.Active
          then
            check
              (C.projection (C.view !state) = None)
              "old baseline revived draining session"
        | Stop ->
          step C.Shutdown_requested;
          check
            (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
            "shutdown retained admission"
        | Release_ack -> step (C.Binding_release_completed (I.binding, Ok ())))
      trace
  in
  let fails trace =
    try
      run trace;
      false
    with
    | _ -> true
  in
  (* Prefixes exercise valid admission, reversed delivery and cancellation races.
     The suffix generator also injects duplicate/foreign/obsolete orderings. *)
  let prefixes =
    [ [ Plan; Admit 0; Answer 0 ]
    ; [ Plan; Answer 0; Admit 0 ]
    ; [ Plan; Cancel 0; Admit 0; Answer 0 ]
    ; [ Plan; Forget 0; Admit 0; Answer 0; Stop; Release_ack ]
    ; [ Plan; Answer 0; Refuse 0; Stop; Release_ack ]
    ]
  in
  List.iter run prefixes;
  for seed = 0 to 499 do
    let random = Random.State.make [| 0x51ec; seed |] in
    let pick () =
      let n = Random.State.int random 8 in
      match Random.State.int random 11 with
      | 0 -> Plan
      | 1 -> Admit n
      | 2 -> Answer n
      | 3 -> Cancel n
      | 4 -> Forget n
      | 5 -> Refuse n
      | 6 -> Retry
      | 7 -> Old_baseline
      | 8 -> Stop
      | 9 -> Release_ack
      | _ -> Plan
    in
    let trace =
      List.nth prefixes (seed mod List.length prefixes) @ List.init 60 (fun _ -> pick ())
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      failwith
        (Printf.sprintf
           "property seed=%d minimal=[%s]"
           seed
           (String.concat ";" (List.map show reduced))))
  done
;;

let test_retry_binding_release_error_is_observable () =
  let issuer,_,projection,_=fixture 504L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let retry=(C.step(ready I.binding projection)C.Retry_bootstrap).next in
  let error=W.Service_failed "Synthetic registration cleanup failed" in
  let failed=C.step retry(C.Binding_release_completed(I.binding,Error error)) in
  check(C.bootstrap(C.view failed.next)=W.Bootstrap_failed error)
    "retry binding cleanup failure remained silently Awaiting_baseline";
  check(not(List.exists(function C.Bind_replacement->true|_->false)failed.instructions))
    "failed physical cleanup fabricated a replacement binding";
  let explicit=C.step failed.next C.Retry_bootstrap in
  check(List.exists(function C.Release_binding binding->W.equal_binding binding I.binding|_->false)explicit.instructions)
    "explicit retry lost the original binding cleanup obligation";
  let acknowledged=C.step explicit.next(C.Binding_release_completed(I.binding,Ok())) in
  check(List.exists(function C.Bind_replacement->true|_->false)acknowledged.instructions)
    "actual original cleanup ACK did not allow a fresh binding"
;;

let test_cleanup_admission_edges () =
  let issuer, _, projection, session = fixture 500L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let bound = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let admitted =
    (C.step bound (C.Bootstrap_admitted (I.binding, Id.Worker.Request_id.one))).next
  in
  let stopping = (C.step admitted C.Shutdown_requested).next in
  let acknowledged =
    (C.step stopping (C.Binding_release_completed (I.binding, Ok ()))).next
  in
  check
    (C.shutdown_state (C.view acknowledged) = C.Draining)
    "shutdown ignored an outstanding bootstrap reply";
  let done_state =
    (C.step acknowledged (C.Bootstrap_received (I.binding, W.Ready projection))).next
  in
  check
    (C.shutdown_state (C.view done_state) = C.Stopped)
    "bootstrap completion did not settle draining owner";
  let stopping = (C.step (ready I.binding projection) C.Shutdown_requested).next in
  let failed =
    (C.step stopping (C.Binding_release_not_admitted (I.binding, W.Stopping))).next
  in
  check
    (match C.shutdown_state (C.view failed) with
     | C.Shutdown_failed _ -> true
     | _ -> false)
    "stopping transport left cleanup silently Draining";
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let ticket, planned =
    C.request (ready I.binding projection) session (W.Query (budget, W.Graph_info))
    |> Result.get_ok
  in
  let early =
    (C.step planned.next (C.Completed (ticket, W.Interrupted W.Cancelled))).next
  in
  let refused = (C.step early (C.Admission_refused (ticket, W.Full))).next in
  let stopping = (C.step refused C.Shutdown_requested).next in
  let stopped = (C.step stopping (C.Binding_release_completed (I.binding, Ok ()))).next in
  check
    (C.shutdown_state (C.view stopped) = C.Stopped)
    "refused request retained an unowned early result"
;;

let test_reads_wait_for_verified_baseline () =
  let issuer, raw, projection, _ = fixture 301L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let bound = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let ticket, waiting =
    C.plan_query
      bound
      ~owner
      ~maximum_items:64
      ~maximum_bytes:Worker_pure_data.maximum_response_bytes
      W.Graph_info
    |> Result.get_ok
  in
  let sends instructions =
    List.fold_left
      (fun n -> function
         | C.Send _ -> n + 1
         | _ -> n)
      0
      instructions
  in
  check (sends waiting.instructions = 0) "query sent before verified baseline";
  let opened =
    C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends opened.instructions = 1) "verified Open did not dispatch queued query";
  let duplicate = C.step opened.next (C.Projection_received projection) in
  check (sends duplicate.instructions = 0) "duplicate baseline dispatched query twice";
  (* Host messages may run while a newer baseline is only queued. Absence
     from the old snapshot is not evidence that the new generation retired. *)
  let future_owner = { owner with graph_generation = owner.graph_generation + 1 } in
  let future, future_waiting =
    C.plan_query
      (ready I.binding projection)
      ~owner:future_owner
      ~maximum_items:1
      ~maximum_bytes:65536
      W.Graph_info
    |> Result.get_ok
  in
  check
    (C.reply (C.view future_waiting.next) future = None)
    "future owner was rejected by stale baseline";
  let drained = C.step future_waiting.next C.Drain in
  check
    (sends drained.instructions = 0 && C.reply (C.view drained.next) future = None)
    "a queued future owner either sent early or was falsely retired";
  let update_scope (scope : S.asset_scope) =
    { scope with graph_generation = future_owner.graph_generation }
  in
  let raw_future =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  selected = Some future_owner
                ; residents =
                    List.map
                      (fun (scope, state) -> update_scope scope, state)
                      raw.baseline.state.sync.residents
                }
            ; residents =
                List.map
                  (fun (scope, state) ->
                     ( update_scope scope
                     , { state with
                         Logseq_db_worker.generation = future_owner.graph_generation
                       } ))
                  raw.baseline.state.residents
            }
        }
    }
  in
  let future_projection =
    match I.bootstrap (S.Coordination_registered raw_future) with
    | Ok (W.Ready projection) -> projection
    | _ -> failwith "future fixture baseline rejected"
  in
  let arrived = C.step drained.next (C.Projection_received future_projection) in
  check
    (sends arrived.instructions = 1)
    "future owner did not send after matching baseline";
  let cancelled = C.step waiting.next (C.Cancel ticket) in
  check
    (C.reply (C.view cancelled.next) ticket = Some (W.Interrupted W.Cancelled))
    "unsent cancellation did not settle locally";
  let late =
    C.step cancelled.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends late.instructions = 0) "cancelled waiting query was resurrected";
  let wrong = { owner with graph_generation = owner.graph_generation - 1 } in
  let stale, waiting =
    C.plan_query bound ~owner:wrong ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  let opened =
    C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends opened.instructions = 0) "stale host identity minted a session";
  check
    (C.reply (C.view opened.next) stale = Some (W.Answered (Error W.Revoked_session)))
    "replaced scope left queued read waiting forever";
  let waiting =
    snd
      (C.plan_query bound ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
       |> Result.get_ok)
  in
  let shutdown = C.step waiting.next C.Shutdown_requested in
  let stopped = C.step shutdown.next (C.Binding_release_completed (I.binding, Ok ())) in
  let stopped =
    C.step stopped.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check
    (C.shutdown_state (C.view stopped.next) = C.Stopped)
    "unsent query prevented registration cleanup";
  check (sends stopped.instructions = 0) "shutdown sent a queued query"
;;

let test_opening_query_retires_on_removal () =
  let issuer, raw, _, _ = fixture 303L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let opening =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { raw.baseline.state with
              residents =
                List.map
                  (fun (scope, state) ->
                     scope, { state with Logseq_db_worker.phase = Graph_opening })
                  raw.baseline.state.residents
            }
        }
    }
  in
  let project value =
    match I.bootstrap (S.Coordination_registered value) with
    | Ok (W.Ready projection) -> projection
    | _ -> failwith "opening/removal baseline fixture failed"
  in
  let opening = project opening in
  let ticket, waiting =
    C.plan_query
      (ready I.binding opening)
      ~owner
      ~maximum_items:1
      ~maximum_bytes:65536
      W.Graph_info
    |> Result.get_ok
  in
  check (C.reply (C.view waiting.next) ticket = None) "Opening query did not wait";
  let empty =
    project
      { raw with
        baseline =
          { raw.baseline with
            version = 3L
          ; state =
              { sync =
                  { raw.baseline.state.sync with
                    desired_residents = []
                  ; residents = []
                  ; selected = None
                  }
              ; residents = []
              }
          }
      }
  in
  let removed = C.step waiting.next (C.Projection_received empty) in
  check
    (C.reply (C.view removed.next) ticket = Some (W.Answered (Error W.Revoked_session)))
    "removed Opening owner retained its waiting query";
  let late, planned =
    C.plan_query removed.next ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  check
    (C.reply (C.view planned.next) late = Some (W.Answered (Error W.Revoked_session)))
    "late request for a known removed owner waited forever"
;;

let test_queued_query_properties () =
  let issuer, raw, first, _ = fixture 302L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let later_owner = { owner with graph_generation = owner.graph_generation + 1 } in
  let later_scope (scope : S.asset_scope) =
    { scope with graph_generation = later_owner.graph_generation }
  in
  let later_raw =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  selected = Some later_owner
                ; residents =
                    List.map
                      (fun (scope, state) -> later_scope scope, state)
                      raw.baseline.state.sync.residents
                }
            ; residents =
                List.map
                  (fun (scope, state) ->
                     ( later_scope scope
                     , { state with
                         Logseq_db_worker.generation = later_owner.graph_generation
                       } ))
                  raw.baseline.state.residents
            }
        }
    }
  in
  let later =
    match I.bootstrap (S.Coordination_registered later_raw) with
    | Ok (W.Ready value) -> value
    | _ -> failwith "later queued-query fixture rejected"
  in
  let run trace =
    let state =
      ref (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next
    in
    let tickets = ref []
    and expected = Hashtbl.create 128
    and sends = Hashtbl.create 128
    and forbidden = Hashtbl.create 128 in
    let apply (transition : C.transition) =
      List.iter
        (function
          | C.Send (ticket, session, operation) ->
            (match operation with
             | W.Query (budget,_) ->
               (match C.query_origin (C.view transition.next) ticket with
                | Some (actual,actual_budget) -> check (W.equal_session actual session && actual_budget=budget)
                    "queued property: origin differs from actual Send"
                | None->failwith "queued property: dispatched read lacks origin")
             | _ -> ());
            check (C.validate_session transition.next session=Ok ()) "dispatched query session is fenced";
            let id = C.ticket_id ticket in
            check (not (Hashtbl.mem forbidden id)) "cancelled unsent read was dispatched";
            check (not (Hashtbl.mem sends id)) "queued read sent more than once";
            check
              (W.matches_scope session (Hashtbl.find expected id))
              "queued read used foreign scope";
            check
              (Option.fold
                 ~none:false
                 ~some:(fun projection ->
                   List.exists
                     (fun resident ->
                        resident.W.phase = W.Open
                        && W.equal_session session resident.session)
                     (W.residents projection))
                 (C.projection (C.view transition.next)))
              "queued read bypassed verified Open session";
            Hashtbl.replace sends id ()
          | _ -> ())
        transition.C.instructions;
      check
        (List.length transition.instructions < 1000)
        "queued read emitted unbounded batch";
      state := transition.next
    in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "queued steps were nondeterministic";
      check (C.equal_view before (C.view !state)) "queued step mutated prior state";
      apply a
    in
    let ticket n f =
      match List.nth_opt !tickets (n mod 8) with
      | None -> ()
      | Some value -> f value
    in
    List.iter
      (fun (op, n) ->
         match op with
         | 0 ->
           let target =
             match n mod 3 with
             | 0 -> owner
             | 1 -> later_owner
             | _ -> { owner with graph_generation = owner.graph_generation - 1 }
           in
           (match
              C.plan_query
                !state
                ~owner:target
                ~maximum_items:1
                ~maximum_bytes:65536
                W.Graph_info
            with
            | Error _ -> ()
            | Ok (ticket, transition) ->
              Hashtbl.replace expected (C.ticket_id ticket) target;
              tickets := ticket :: List.filteri (fun i _ -> i < 7) !tickets;
              apply transition)
         | 1 -> step (C.Projection_received (if n mod 2 = 0 then first else later))
         | 2 ->
           ticket n (fun value ->
             step
               (C.Admitted (value, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
         | 3 ->
           ticket n (fun value ->
             step (C.Completed (value, W.Interrupted W.Cancelled));
             let once = C.view !state in
             step (C.Completed (value, W.Answered (Error (W.Service_failed "duplicate"))));
             check (C.equal_view once (C.view !state)) "queued terminal consumed twice")
         | 4 | 5 ->
           ticket n (fun value ->
             if not (Hashtbl.mem sends (C.ticket_id value))
             then Hashtbl.replace forbidden (C.ticket_id value) ();
             step (if op = 4 then C.Cancel value else C.Forget value))
         | 6 -> step C.Drain
         | 7 -> step C.Shutdown_requested
         | 8 -> step C.Retry_bootstrap
         | 9 -> step (C.Binding_release_completed (I.binding, Ok ()))
         | 10 -> ticket n (fun value -> step (C.Admission_refused (value, W.Full)))
         | _ ->
           step
             (C.Bootstrap_received
                (I.binding, W.Ready (if n mod 2 = 0 then first else later))))
      trace
  in
  let prefixes =
    [ [ 0, 1; 1, 0; 6, 0; 2, 0; 3, 0; 1, 1; 2, 0; 3, 0 ]
    ; [ 0, 0; 4, 0; 1, 0 ]
    ; [ 0, 1; 5, 0; 1, 1 ]
    ; [ 0, 1; 7, 0; 9, 0; 11, 1 ]
    ]
  in
  List.iter run prefixes;
  for seed = 0 to 249 do
    let random = Random.State.make [| 0x0c001; seed |] in
    let prefix = List.nth prefixes (seed mod List.length prefixes) in
    let trace =
      prefix
      @ List.init 96 (fun _ -> Random.State.int random 16, Random.State.int random 8)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let minimal = shrink fails trace in
      failwith
        (Printf.sprintf
           "queued-query seed=%d shrunk=%s"
           seed
           (String.concat
              ","
              (List.map (fun (op, n) -> Printf.sprintf "%d:%d" op n) minimal))))
  done
;;

let test_durable_mutation_properties ?(append=false) () =
  let issuer, _, projection, session = fixture 1901L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let append_intent=if not append then None else Some(
    W.append_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000000091")
      ~block_id:graph ~day:(W.journal_day 20261102 |> Result.get_ok) ~title:"stable durable Append"
      ~task_status:(Some(uuid "98000000-0000-4000-8000-000000000096"))
      ~children:(Rrbvec.singleton Worker_pure_data.{block_id=uuid "98000000-0000-4000-8000-000000000095";
        title="complete child";task_status=None;children=Rrbvec.empty}) |> Result.get_ok) in
  let intent = match append_intent with
  | Some intent->W.Append_intent intent
  | None->W.mutation_intent
      session
      ~mutation_id:(uuid "98000000-0000-4000-8000-000000000091")
      (W.Save_block
         { block = graph
         ; title = "stable durable choice"
         ; preconditions =
             { blocks = [ graph, "block-state:v1:synthetic" ]; pages = []; scopes = [] }
         })
    |> Result.get_ok |> fun intent->W.Mutation_intent intent
  in
  let operation=match append_intent with Some intent->W.Append intent|None->(match intent with W.Mutation_intent intent->W.Mutate intent|Append_intent intent->W.Append intent) in
  let wire = W.encode_durable_intent intent in
  let run trace =
    let state = ref (ready I.binding projection)
    and tickets = ref []
    and committed = ref false
    and original_point = ref None in
    let apply event =
      let before = C.view !state in
      let first = C.step !state event
      and second = C.step !state event in
      check
        (C.equal_view (C.view first.next) (C.view second.next))
        "durable step is nondeterministic";
      check (C.equal_view before (C.view !state)) "durable step modified shared input";
      state := first.next;
      check
        (W.encode_durable_intent intent = wire)
        "unknown write changed durable payload";
      (match C.intent_progress (C.view !state) intent with
       | Some (W.Committed_pending_presentation receipt) ->
         check
           (W.encode_durable_intent (W.receipt_intent receipt) = wire)
           "foreign receipt poisoned durable identity";
         let point = W.receipt_revisions receipt in
         (match !original_point with
          | None -> original_point := Some point
          | Some original ->
            check (point = original) "later completion replaced original commit point")
       | _ -> ());
      if !committed
      then (
        match C.intent_progress (C.view !state) intent with
        | Some (W.Committed_pending_presentation _ | W.Confirmed _) -> ()
        | _ -> failwith "committed evidence regressed or vanished")
    in
    let with_ticket n f = Option.iter f (List.nth_opt !tickets (n mod 8)) in
    List.iter
      (fun (action, n) ->
         match action with
         | 0 ->
           (match C.request !state session operation with
            | Ok (ticket, transition) ->
              state := transition.next;
              tickets := ticket :: List.take 7 !tickets
            | Error _ -> ())
         | 1 ->
           with_ticket n (fun ticket ->
             apply
               (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 100)))))
         | 2 ->
           with_ticket n (fun ticket ->
             apply (C.Completed (ticket, W.Interrupted W.Cancelled)))
         | 3 -> with_ticket n (fun ticket -> apply (C.Cancel ticket))
         | 4 -> with_ticket n (fun ticket -> apply (C.Forget ticket))
         | 5 -> with_ticket n (fun ticket -> apply (C.Admission_refused (ticket, W.Full)))
         | 6 ->
           with_ticket n (fun ticket ->
             apply (C.Completed (ticket, W.Answered (Ok W.Submission_unknown))))
         | 7 | 9 | 10 ->
           with_ticket n (fun ticket ->
             let receipt_intent =
               if action <> 9
               then intent
               else
                 W.mutation_intent
                   session
                   ~mutation_id:(uuid "98000000-0000-4000-8000-000000000092")
                   (W.Save_block
                      { block = graph
                      ; title = "unrelated durable choice"
                      ; preconditions =
                          { blocks = [ graph, "block-state:v1:synthetic" ]
                          ; pages = []
                          ; scopes = []
                          }
                      })
                 |> Result.get_ok |> fun intent->W.Mutation_intent intent
             in
             let request_id =
               match
                 I.request session ~request_id:(C.ticket_id ticket) operation
               with
               | Ok (S.Coordination_mutation { request_id; _ }) -> request_id
               | _ -> assert false
             in
             let response =
               (Logseq_db_worker_contract.Worker_pure_mutation.For_worker.commit ~mutation_id:(W.durable_intent_id receipt_intent) ~status:(Worker_pure_data.V2_applied) ~generation:("generation:v1:1:1") ~before:("projection:v1:0") ~after:((if action = 10 then "projection:v1:2" else "projection:v1:1")))
             in
             let receipt =
               (let packet = response in
      match I.reply session ~request_id:(C.ticket_id ticket) (match receipt_intent with W.Append_intent intent->W.Append intent|Mutation_intent intent->W.Mutate intent)
        (Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_mutation_result
          {request_id=request_id;
           outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed packet}) with
      | Ok(W.Answered(Ok(W.Submission_committed proof))) -> proof
      | _ -> failwith "Production mutation receipt was rejected")
             in
             apply
               (C.Completed
                  (ticket, W.Answered (Ok (W.Submission_committed receipt))));
             match C.intent_progress (C.view !state) intent with
             | Some (W.Committed_pending_presentation _ | W.Confirmed _) ->
               committed := true
             | _ -> ())
         | _ ->
           with_ticket n (fun ticket ->
             apply
               (C.Completed
                  ( ticket
                  , W.Answered (Ok (W.Submission_rejected (W.Invalid_input "known rejection"))) ))))
      trace
  in
  let prefixes =
    [ [ 0, 0; 1, 0; 9, 0 ]
    ; [ 0, 0; 1, 0; 7, 0; 0, 0; 1, 0; 10, 0 ]
    ; [ 0, 0; 1, 0; 3, 0; 7, 0; 4, 0 ]
    ; [ 0, 0; 7, 0; 1, 0; 6, 0 ]
    ; [ 0, 0; 1, 0; 7, 0; 0, 0; 1, 0; 8, 0; 7, 1 ]
    ; [ 0, 0; 4, 0; 1, 0; 7, 0 ]
    ]
  in
  let fails trace =
    try
      run trace;
      false
    with
    | _ -> true
  in
  List.iter run prefixes;
  for seed = 0 to 249 do
    let random = Random.State.make [| 0xd0a; (if append then 1 else 0); seed |] in
    let trace =
      List.nth prefixes (seed mod List.length prefixes)
      @ List.init 80 (fun _ -> Random.State.int random 11, Random.State.int random 8)
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      failwith
        (Printf.sprintf
           "durable append=%b seed=%d shrunk=%s"
           append seed
           (String.concat
              ";"
              (List.map (fun (a, n) -> Printf.sprintf "%d/%d" a n) reduced))))
  done
;;

let test_durable_readback_reservation () =
  let issuer, _, projection, session = fixture 1902L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ref (ready I.binding projection)
  and admitted = ref 0 in
  for n = 1 to 128 do
    let intent =
      W.mutation_intent
        session
        ~mutation_id:(uuid (Printf.sprintf "98000000-0000-4000-8000-%012d" (1000 + n)))
        (W.Save_block
           { block = graph
           ; title = "bounded readback reservation"
           ; preconditions =
               { blocks = [ graph, "block-state:v1:synthetic" ]; pages = []; scopes = [] }
           })
      |> Result.get_ok
    in
    match C.request !state session (W.Mutate intent) with
    | Error _ -> ()
    | Ok (_, transition) ->
      incr admitted;
      state := transition.next
  done;
  check (!admitted > 0) "durable capacity admitted no legitimate operation";
  check
    (!admitted * Worker_pure_data.maximum_response_bytes <= 16777216)
    "bounded intent keys admitted unreserved confirmation snapshots"
;;

let test_recovery_cursor_and_capacity_bounds () =
  let module Wire=Logseq_db_worker_contract.Worker_pure_mutation in
  let issuer,_,projection,session=fixture 1906L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let make n=W.mutation_intent session ~mutation_id:(uuid(Printf.sprintf "98000000-0000-4000-8000-%012d" (2000+n)))
    (W.Save_block{block=graph;title="bounded recovered item";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let item n=Wire.{intent=((W.Mutation_intent(make n)));outcome=Unknown} in
  let id=W.request_id(uuid "98000000-0000-4000-8000-000000001906") in
  let request_id=uuid "98000000-0000-4000-8000-000000001906" in
  let operation=W.Recover_mutations{after=None;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  let raw items next=S.Coordination_mutations_recovered{request_id;page=Wire.{items;next}} in
  let page=match I.reply session ~request_id:id operation(raw(Rrbvec.singleton(item 1))(Some 1L)) with
    | Ok(W.Answered(Ok page))->page|_->failwith "valid recovery cursor codec failed" in
  check(W.validate_request session(W.Recover_mutations{after=page.next;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes})=Ok())
    "sealed recovery cursor lost same-budget ownership";
  check(Result.is_error(W.validate_request session(W.Recover_mutations{after=page.next;maximum_items=2;
    maximum_bytes=W.maximum_mutation_recovery_bytes}))) "recovery cursor adopted a new item budget";
  let _,_,_,other=fixture 1907L in
  check(Result.is_error(W.validate_request other(W.Recover_mutations{after=page.next;maximum_items=1;
    maximum_bytes=W.maximum_mutation_recovery_bytes}))) "foreign session adopted recovery cursor";
  check(Result.is_error(I.reply session ~request_id:id operation(raw Rrbvec.empty(Some 1L)))) "empty More became recovery completeness";
  let after=W.Recover_mutations{after=page.next;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  check(Result.is_error(I.reply session ~request_id:id after(raw(Rrbvec.singleton(item 1))(Some 1L))))
    "recovery cursor repeated without progress";
  let many=W.Recover_mutations{after=None;maximum_items=70;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  check(Result.is_error(I.reply session ~request_id:id many(raw(Rrbvec.of_list[item 1;item 1])None)))
    "duplicate recovered mutation identity was accepted";
  let oversized=Wire.{intent=(item 1).intent;outcome=Rejected((Logseq_db_worker.Error.create ~code:Conflict ~message:("Known not applied") ~details:[] |> Result.get_ok))} in
  check(Result.is_error(I.reply session ~request_id:id (W.Recover_mutations{after=None;maximum_items=1;maximum_bytes=1})(raw(Rrbvec.singleton oversized)None)))
    "recovered rejection bypassed its reserved protocol-result budget";
  let ticket,planned=C.request(ready I.binding projection)session many |> Result.get_ok in
  let request_id=match I.request session ~request_id:(C.ticket_id ticket)many with
    | Ok(S.Coordination_recover_mutations{request_id;_})->request_id|_->assert false in
  let page=match I.reply session ~request_id:(C.ticket_id ticket)many
    (S.Coordination_mutations_recovered{request_id;page=Wire.{items=Rrbvec.init 70 item;next=None}}) with
    | Ok(W.Answered(Ok page))->page|_->failwith "valid bounded storage page failed codec" in
  let state=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.of_int64 30L))).next in
  let state=(C.step state(C.Completed(ticket,W.Answered(Ok page)))).next in
  check(match C.reply(C.view state)ticket with Some(W.Answered(Error _))->true|_->false)
    "over-capacity recovery silently skipped entries";
  for n=0 to 69 do check(C.intent_progress(C.view state)(W.Mutation_intent(make n))=None) "failed recovery partially adopted its page" done
;;

let test_durable_recovery_and_ack_purity () =
  let module Wire=Logseq_db_worker_contract.Worker_pure_mutation in
  let issuer,_,projection,session=fixture 1903L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let intent=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001903")
    (W.Save_block{block=graph;title="recovered choice";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let append=W.append_intent session
    ~mutation_id:(uuid "98000000-0000-4000-8000-000000001904")
    ~block_id:graph ~day:(W.journal_day 20261102 |> Result.get_ok)
    ~title:"recovered atomic Append" ~task_status:None ~children:Rrbvec.empty
    |> Result.get_ok in
  List.iter(fun intent->
  let operation=W.Recover_mutations{after=None;maximum_items=8;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  let answer ticket progress =
    let request_id=match I.request session ~request_id:(C.ticket_id ticket) operation with
      | Ok(S.Coordination_recover_mutations{request_id;_})->request_id|_->failwith "recovery codec request" in
    let outcome=if progress then Wire.Rejected((Logseq_db_worker.Error.create ~code:Conflict ~message:("known not applied") ~details:[] |> Result.get_ok)) else Wire.Unknown in
    match I.reply session ~request_id:(C.ticket_id ticket) operation
      (S.Coordination_mutations_recovered{request_id;page=Wire.{items=Rrbvec.singleton
        {intent=(intent);outcome};next=None}}) with
    | Ok(W.Answered(Ok page))->page|_->failwith "recovery codec response" in
  let state=ref(ready I.binding projection) in
  check(Result.is_error(C.request !state session(W.Acknowledge_intent intent))) "unknown intent admitted ACK";
  let ticket,planned=match C.request !state session operation with
    | Ok value->value|Error _->failwith "typed durable recovery has no pure planning" in
  state:=planned.next;
  check(Result.is_error(C.request !state session operation)) "parallel recovery bypassed response retention bound";
  state:=(C.step !state(C.Admitted(ticket,Id.Worker.Request_id.of_int64 10L))).next;
  state:=(C.step !state(C.Completed(ticket,W.Answered(Ok(answer ticket false))))).next;
  check(C.intent_progress(C.view !state)intent=Some W.Outcome_unknown) "recovery did not retain Unknown";
  check(Result.is_error(C.request !state session(W.Acknowledge_intent intent))) "recovered Unknown admitted ACK";
  state:=(C.step !state(C.Forget ticket)).next;
  let ticket,planned=C.request !state session operation |> Result.get_ok in
  state:=planned.next;
  state:=(C.step !state(C.Admitted(ticket,Id.Worker.Request_id.of_int64 11L))).next;
  state:=(C.step !state(C.Completed(ticket,W.Answered(Ok(answer ticket true))))).next;
  check(match C.intent_progress(C.view !state)intent with Some(W.Rejected _)->true|_->false)
    "known rejection was lost during recovery";
  state:=(C.step !state(C.Forget ticket)).next;
  let stale,planned=C.request !state session operation |> Result.get_ok in
  state:=planned.next;
  state:=(C.step !state(C.Admitted(stale,Id.Worker.Request_id.of_int64 12L))).next;
  let ack,planned=C.request !state session(W.Acknowledge_intent intent) |> Result.get_ok in
  check(match C.ticket_acknowledgement ack with Some(_,None)->true|_->false)
    "known rejection ACK did not carry the pure no-commit decision";
  state:=planned.next;
  state:=(C.step !state(C.Admitted(ack,Id.Worker.Request_id.of_int64 13L))).next;
  state:=(C.step !state(C.Completed(ack,W.Interrupted W.Transport_lost))).next;
  check(C.intent_progress(C.view !state)intent<>None) "interrupted ACK erased durable ownership";
  state:=(C.step !state(C.Forget ack)).next;
  let ack,planned=C.request !state session(W.Acknowledge_intent intent) |> Result.get_ok in
  state:=planned.next;
  state:=(C.step !state(C.Admitted(ack,Id.Worker.Request_id.of_int64 14L))).next;
  state:=(C.step !state(C.Completed(ack,W.Answered(Ok())))).next;
  check(C.intent_progress(C.view !state)intent=None) "true durable ACK did not free coordination capacity";
  state:=(C.step !state(C.Completed(stale,W.Answered(Ok(answer stale true))))).next;
  check(C.intent_progress(C.view !state)intent=None) "old recovery resurrected an acknowledged intent";
  check(match C.reply(C.view !state)stale with Some(W.Answered(Error _))->true|_->false)
    "stale recovery was exposed as a current pending page"
) [W.Mutation_intent intent;W.Append_intent append]
;;

let test_committed_ack_requires_current_confirmation () =
  let issuer,raw,projection,session=fixture 1905L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let presentation=Option.get(W.selected projection) in
  let owner=Option.get raw.baseline.state.sync.selected in
  check(C.current_presentation ~owner (C.view(ready I.binding projection))presentation)
    "current UI presentation was rejected";
  let independent,independent_raw,_,_=fixture 1915L in
  let module J=(val independent:Worker_effect_authority.ISSUER) in
  let divergent=match J.bootstrap(S.Coordination_registered{independent_raw with
      baseline={independent_raw.baseline with version=2L;presentation=17L}}) with
    | Ok(W.Ready value)->value|_->failwith "independent presentation counter fixture" in
  let divergent_presentation=Option.get(W.selected divergent) in
  check(C.current_presentation ~owner(C.view(ready J.binding divergent))divergent_presentation)
    "Worker token counter was confused with UI presentation generation";
  let future={owner with startup={owner.startup with presentation_generation=owner.startup.presentation_generation+2}} in
  check(not(C.current_presentation ~owner:future(C.view(ready I.binding projection))presentation))
    "lagging Worker baseline authorized a newer UI presentation";
  let intent=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001905")
    (W.Save_block{block=graph;title="confirmed choice";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let ticket,planned=C.request(ready I.binding projection)session(W.Mutate intent) |> Result.get_ok in
  let request_id=match I.request session ~request_id:(C.ticket_id ticket)(W.Mutate intent) with
    | Ok(S.Coordination_mutation{request_id;_})->request_id|_->assert false in
  let receipt=(let packet = ((Logseq_db_worker_contract.Worker_pure_mutation.For_worker.commit ~mutation_id:(W.mutation_intent_id intent) ~status:(Worker_pure_data.V2_applied) ~generation:("generation:v1:1:1") ~before:("projection:v1:0") ~after:("projection:v1:1"))) in
      match I.reply session ~request_id:(C.ticket_id ticket) (W.Mutate intent)
        (Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_mutation_result
          {request_id=request_id;
           outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed packet}) with
      | Ok(W.Answered(Ok(W.Submission_committed proof))) -> proof
      | _ -> failwith "Production mutation receipt was rejected") in
  let state=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.of_int64 20L))).next in
  let state=(C.step state(C.Completed(ticket,W.Answered(Ok(W.Submission_committed receipt))))).next in
  check(Result.is_error(C.request state session(W.Acknowledge_intent(W.Mutation_intent intent)))) "unconfirmed commit admitted ACK";
  let _,resumed=C.reconcile_mutation state ~presentation (W.Mutation_intent intent) |> Result.get_ok in
  check(List.exists(function C.Send(_,_,W.Confirm(actual,proof))->
    actual=presentation && W.receipt_revisions proof=W.receipt_revisions receipt|_->false)resumed.instructions)
    "reconciliation rewrote a known committed intent";
  check(C.intent_progress(C.view state)(W.Mutation_intent intent)=Some(W.Committed_pending_presentation receipt))
    "reconciliation mutated its previous state";
  let confirmation=Coordination_test_fixture.confirmed_summary issuer session presentation receipt (W.request_id request_id)
    ~lookup:(Worker_pure_data.V2_missing_block{uuid=graph;revision="block-state:v1:missing"})
    ~page:None ~items:[] ~scope_revision:"scope-revision:v1:missing" ~generation:"generation:v1:1:1"
    ~projection_revision:"projection:v1:1" in
  let confirm,planned=C.request state session(W.Confirm(presentation,receipt)) |> Result.get_ok in
  let state=(C.step planned.next(C.Admitted(confirm,Id.Worker.Request_id.of_int64 21L))).next in
  let state=(C.step state(C.Completed(confirm,W.Answered(Ok confirmation)))).next in
  let captured=W.Answered(Ok confirmation) in
  let forgotten=(C.step state(C.Forget confirm)).next in
  check(C.revalidate_reply(C.view forgotten)confirm captured=captured)
    "Forget alone revoked a valid queued confirmation";
  let focused=match I.bootstrap(S.Coordination_registered{raw with baseline={raw.baseline with
      version=3L;presentation=3L}}) with
    | Ok(W.Ready projection)->projection|_->failwith "focus roundtrip fixture" in
  let focused=(C.step forgotten(C.Projection_received focused)).next in
  check(C.revalidate_reply(C.view focused)confirm captured=W.Answered(Error W.Revoked_session))
    "queued confirmation settled a later focus after Forget";
  check(C.revalidate_reply(C.view forgotten)confirm captured=captured)
    "delivery validation mutated preceding state";
  check(Result.is_error(C.reconcile_mutation focused ~presentation (W.Mutation_intent intent)))
    "explicit retry reused stale presentation";
  let latest=Option.get(W.selected(Option.get(C.projection(C.view focused)))) in
  check(match C.settle_applied_mutation state ~presentation ~applied_presentation:presentation (W.Mutation_intent intent) with
    | Ok(C.Acknowledgement _,_)->true|_->false) "current applied intent rewrote instead of ACK";
  check(match C.settle_applied_mutation focused ~presentation:latest ~applied_presentation:presentation (W.Mutation_intent intent) with
    | Ok(C.Reconciliation _,transition)->List.exists(function
        C.Send(_,_,W.Confirm(actual,proof))->actual=latest && W.receipt_revisions proof=W.receipt_revisions receipt
        | _->false)transition.instructions|_->false)
    "cleanup retry across focus did not re-confirm original proof";
  let next_confirmation=Coordination_test_fixture.confirmed_summary issuer session latest receipt (W.request_id request_id)
    ~lookup:(Worker_pure_data.V2_missing_block{uuid=graph;revision="block-state:v1:missing"})
    ~page:None ~items:[] ~scope_revision:"scope-revision:v1:missing" ~generation:"generation:v1:1:1"
    ~projection_revision:"projection:v1:1" in
  let next_ticket,next_plan=C.request focused session(W.Confirm(latest,receipt)) |> Result.get_ok in
  let next_admitted=(C.step next_plan.next(C.Admitted(next_ticket,Id.Worker.Request_id.of_int64 24L))).next in
  let next_state=(C.step next_admitted(C.Completed(next_ticket,W.Answered(Ok next_confirmation)))).next in
  check(match C.settle_applied_mutation next_state ~presentation:latest ~applied_presentation:presentation (W.Mutation_intent intent) with
    | Ok(C.Reconciliation _,_)->true|_->false)
    "new first DTO ACKed using old presentation's applied proof";
  check(match C.settle_applied_mutation next_state ~presentation:latest ~applied_presentation:latest (W.Mutation_intent intent) with
    | Ok(C.Acknowledgement _,_)->true|_->false)
    "new applied canonical projection could not ACK";
  let run_delivery_trace trace =
    let current=ref forgotten and round=ref 1L and version=ref 1L in
    let advance n =
      round:=Int64.add !round(Int64.of_int(n+1));version:=Int64.succ !version;
      let projected=match I.bootstrap(S.Coordination_registered{raw with baseline={raw.baseline with
          version= !version;presentation= !round}}) with
        | Ok(W.Ready value)->value|_->failwith "generated presentation baseline" in
      current:=(C.step !current(C.Projection_received projected)).next in
    List.iter(fun(op,n)->
      (match op with
       | 0->advance n
       | 1->current:=(C.step !current(C.Projection_received projection)).next
       | 2->current:=(C.step !current(C.Forget confirm)).next
       | 3->current:=(C.step !current C.Drain).next
       | 4->current:=(C.step !current(C.Cancel confirm)).next
       | 5->current:=(C.step !current C.Capacity_available).next
       | 6->current:=(C.step !current(C.Completed(confirm,captured))).next
       | _->());
      let view=C.view !current in
      let latest=Option.get(W.selected(Option.get(C.projection view))) in
      let same=latest=presentation in
      check((C.revalidate_reply view confirm captured=captured)=same)
        "queued callback crossed a focus generation";
      let before=C.intent_progress view (W.Mutation_intent intent) in
      let plan=C.settle_applied_mutation !current ~presentation:latest ~applied_presentation:presentation (W.Mutation_intent intent) |> Result.get_ok in
      check(match fst plan with
        | C.Acknowledgement _->same
        | C.Reconciliation _->not same && List.exists(function
          C.Send(_,_,W.Confirm(actual,proof))->actual=latest && W.receipt_revisions proof=W.receipt_revisions receipt
          | _->false)(snd plan).instructions)
        "applied cleanup invented a new write or reused old presentation";
      check(C.intent_progress(C.view !current)(W.Mutation_intent intent)=before) "planning mutated its input";
      check(C.revalidate_reply(C.view forgotten)confirm captured=captured) "trace mutated retained old state")trace in
  for seed=0 to 199 do
    let random=Random.State.make[|0xdda1905;seed|] in
    let trace=(if seed mod 2=0 then [2,0;0,1;6,0] else [6,0;2,0]) @
      List.init 64(fun _->Random.State.int random 9,Random.State.int random 4) in
    let fails trace=try run_delivery_trace trace;false with _->true in
    if fails trace then (
      let minimal=shrink fails trace in
      try run_delivery_trace minimal with error->failwith(Printf.sprintf
        "delivery property seed=%d minimal=[%s] %s" seed
        (String.concat ";"(List.map(fun(op,n)->Printf.sprintf "%d:%d" op n)minimal))(Printexc.to_string error)))
  done;
  let ack,planned=match C.request state session(W.Acknowledge_intent(W.Mutation_intent intent)) with
    | Ok value->value|Error _->failwith "current Confirmed intent could not plan ACK" in
  check(match C.ticket_acknowledgement ack with Some(actual,Some proof)->
    actual=presentation && W.receipt_revisions proof=W.receipt_revisions receipt|_->false)
    "ACK did not capture exact presentation and original proof";
  let full=C.step planned.next(C.Admission_refused(ack,W.Full)) in
  check(C.reply(C.view full.next)ack=None) "durable ACK lost its obligation on pre-admission Full";
  let passive=C.step full.next C.Drain in
  check(not(List.exists(function C.Send _->true|_->false)passive.instructions))
    "durable ACK busy retried without capacity";
  let available=C.step full.next C.Capacity_available in
  check(List.exists(function C.Send(_,_,W.Acknowledge_intent actual)->
    W.encode_durable_intent actual=W.encode_durable_intent(W.Mutation_intent intent)|_->false)available.instructions)
    "real capacity did not retry the original durable ACK";
  let other_ack,other_plan=C.request full.next session(W.Acknowledge_intent(W.Mutation_intent intent)) |> Result.get_ok in
  let other_admitted=(C.step other_plan.next(C.Admitted(other_ack,Id.Worker.Request_id.of_int64 23L))).next in
  let other_done=(C.step other_admitted(C.Completed(other_ack,W.Answered(Ok())))).next in
  let old_retry=C.step other_done C.Capacity_available in
  check(not(List.exists(function C.Send(_,_,W.Acknowledge_intent _)->true|_->false)old_retry.instructions))
    "capacity resent an ACK retired by a later settled lifecycle";
  let admitted=(C.step planned.next(C.Admitted(ack,Id.Worker.Request_id.of_int64 22L))).next in
  let retired=(C.step admitted C.Shutdown_requested).next in
  let late=(C.step retired(C.Completed(ack,W.Answered(Ok())))).next in
  check(C.intent_progress(C.view late)(W.Mutation_intent intent)<>None) "old execution ACK erased current recovery ownership";
  let completed=(C.step admitted(C.Completed(ack,W.Answered(Ok())))).next in
  check(C.intent_progress(C.view completed)(W.Mutation_intent intent)=None) "confirmed ACK retained completed intent";
  let retry,planned=C.request state session(W.Mutate intent) |> Result.get_ok in
  let again,planned=C.request planned.next session(W.Confirm(presentation,receipt)) |> Result.get_ok in
  let other=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001908")
    (W.Save_block{block=graph;title="independent accepted write";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let independent,planned=C.request planned.next session(W.Mutate other) |> Result.get_ok in
  let old_ack,planned=C.request planned.next session(W.Acknowledge_intent(W.Mutation_intent intent)) |> Result.get_ok in
  let ack,planned=C.request planned.next session(W.Acknowledge_intent(W.Mutation_intent intent)) |> Result.get_ok in
  let state=(C.step planned.next(C.Admitted(retry,Id.Worker.Request_id.of_int64 23L))).next in
  let state=(C.step state(C.Admitted(again,Id.Worker.Request_id.of_int64 24L))).next in
  let state=(C.step state(C.Admitted(independent,Id.Worker.Request_id.of_int64 25L))).next in
  let state=(C.step state(C.Admitted(old_ack,Id.Worker.Request_id.of_int64 28L))).next in
  let state=(C.step state(C.Admitted(ack,Id.Worker.Request_id.of_int64 26L))).next in
  let acknowledged=(C.step state(C.Completed(ack,W.Answered(Ok())))).next in
  let late=(C.step acknowledged(C.Completed(retry,W.Answered(Ok(W.Submission_committed receipt))))).next in
  check(C.intent_progress(C.view late)(W.Mutation_intent intent)=None) "pre-ACK mutation completion resurrected settled intent";
  check(match C.reply(C.view late)retry with Some(W.Answered(Error _))->true|_->false)
    "pre-ACK mutation completion was published as fresh ownership";
  let late=(C.step acknowledged(C.Completed(retry,W.Interrupted W.Transport_lost))).next in
  check(C.intent_progress(C.view late)(W.Mutation_intent intent)=None) "pre-ACK interruption resurrected Unknown intent";
  let late=(C.step acknowledged(C.Completed(again,W.Answered(Ok confirmation)))).next in
  check(C.intent_progress(C.view late)(W.Mutation_intent intent)=None) "pre-ACK confirmation resurrected settled intent";
  let request_id=match I.request session ~request_id:(C.ticket_id independent)(W.Mutate other) with
    | Ok(S.Coordination_mutation{request_id;_})->request_id|_->assert false in
  let other_receipt=(let packet = ((Logseq_db_worker_contract.Worker_pure_mutation.For_worker.commit ~mutation_id:(W.mutation_intent_id other) ~status:(Worker_pure_data.V2_applied) ~generation:("generation:v1:1:1") ~before:("projection:v1:1") ~after:("projection:v1:2"))) in
      match I.reply session ~request_id:(C.ticket_id independent) (W.Mutate other)
        (Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_mutation_result
          {request_id=request_id;
           outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed packet}) with
      | Ok(W.Answered(Ok(W.Submission_committed proof))) -> proof
      | _ -> failwith "Production mutation receipt was rejected") in
  let other_done=(C.step acknowledged(C.Completed(independent,W.Answered(Ok(W.Submission_committed other_receipt))))).next in
  check(match C.intent_progress(C.view other_done)(W.Mutation_intent other) with Some(W.Committed_pending_presentation _)->true|_->false)
    "ACK of another intent discarded an independent accepted write";
  let fresh,planned=C.request acknowledged session(W.Mutate intent) |> Result.get_ok in
  let fresh_admitted=(C.step planned.next(C.Admitted(fresh,Id.Worker.Request_id.of_int64 27L))).next in
  let fresh_done=(C.step fresh_admitted(C.Completed(fresh,W.Answered(Ok(W.Submission_committed receipt))))).next in
  check(C.intent_progress(C.view fresh_done)(W.Mutation_intent intent)<>None) "explicit request planned after ACK was confused with an old completion";
  let stale_ack=(C.step fresh_done(C.Completed(old_ack,W.Answered(Ok())))).next in
  check(C.intent_progress(C.view stale_ack)(W.Mutation_intent intent)<>None) "old ACK retired a newly reconciled intent lifecycle";
  check(match C.reply(C.view stale_ack)old_ack with Some(W.Answered(Error _))->true|_->false)
    "old ACK was published as the current lifecycle settlement";
  let run actions =
    let state=ref fresh_done in
    List.iter(fun action->
      let event=match action with
        | 0->C.Completed(retry,W.Answered(Ok(W.Submission_committed receipt)))
        | 1->C.Completed(retry,W.Interrupted W.Transport_lost)
        | 2->C.Cancel retry | 3->C.Forget retry
        | 4->C.Completed(again,W.Answered(Ok confirmation))
        | 5->C.Completed(again,W.Interrupted W.Transport_lost)
        | 6->C.Cancel again | 7->C.Forget again
        | 8->C.Completed(old_ack,W.Answered(Ok()))
        | 9->C.Completed(old_ack,W.Interrupted W.Transport_lost)
        | 10->C.Cancel old_ack | 11->C.Forget old_ack
        | 12->C.Completed(independent,W.Answered(Ok(W.Submission_committed other_receipt)))
        | _->C.Drain in
      let before=C.view !state in
      let first=C.step !state event and second=C.step !state event in
      check(C.equal_view before(C.view !state)) "retired intent step mutated old view";
      check(C.equal_view(C.view first.next)(C.view second.next)) "retired intent step nondeterministic";
      state:=first.next;
      check(C.intent_progress(C.view !state)(W.Mutation_intent intent)=Some(W.Committed_pending_presentation receipt))
        "late pre-ACK event replaced the explicitly rebuilt lifecycle";
      check(C.intent_progress(C.view !state)(W.Mutation_intent other)<>None) "retirement of another intent lost accepted evidence")actions in
  for seed=0 to 199 do
    let random=Random.State.make[|0xAC20;seed|] in
    let prefix=Array.of_list(if seed mod 2=0 then [0;4;8;12] else [1;5;9;12]) in
    for n=Array.length prefix-1 downto 1 do let j=Random.State.int random(n+1) in
      let old=prefix.(n) in prefix.(n)<-prefix.(j);prefix.(j)<-old done;
    let actions=Array.to_list prefix@List.init 64(fun _->Random.State.int random 14) in
    let fails actions=try run actions;false with _->true in
    if fails actions then let minimal=shrink fails actions in
      failwith(Printf.sprintf "retired-intent seed=%d shrunk=%s" seed
        (String.concat ","(List.map string_of_int minimal)))
  done
;;

let test_durable_recovery_ack_properties () =
  let module Wire=Logseq_db_worker_contract.Worker_pure_mutation in
  let issuer,_,projection,session=fixture 1904L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let intent=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001904")
    (W.Save_block{block=graph;title="property choice";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let operation=W.Recover_mutations{after=None;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  let run trace =
    let state=ref(ready I.binding projection) and reads=ref [] and acks=ref [] and settled=ref false in
    let step event =
      let before=C.view !state in
      let first=C.step !state event and again=C.step !state event in
      check(C.equal_view(C.view first.next)(C.view again.next)) "lifecycle step nondeterministic";
      check(C.equal_view before(C.view !state)) "lifecycle step mutated previous state";
      state:=first.next;
      List.iter(fun ticket->if C.reply(C.view !state)ticket=Some(W.Answered(Ok())) then settled:=true)!acks;
      if !settled then check(C.intent_progress(C.view !state)(W.Mutation_intent intent)=None) "late event revived acknowledged intent" in
    let read n f=Option.iter f(List.nth_opt !reads(n mod max 1(List.length !reads))) in
    let ack n f=Option.iter f(List.nth_opt !acks(n mod max 1(List.length !acks))) in
    List.iter(fun(op,n)->match op with
      | 0->(match C.request !state session operation with Error _->()|Ok(ticket,next)->
          state:=next.next;reads:=(ticket,!settled)::List.take 7 !reads)
      | 1->read n(fun(ticket,_)->step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(100+n)))))
      | 2 | 3->read n(fun(ticket,after_ack)->
          let request_id=match I.request session ~request_id:(C.ticket_id ticket)operation with
            | Ok(S.Coordination_recover_mutations{request_id;_})->request_id|_->assert false in
          let items=if after_ack then Rrbvec.empty else Rrbvec.singleton Wire.{intent=((W.Mutation_intent intent));
            outcome=(if op=2 then Unknown else Rejected((Logseq_db_worker.Error.create ~code:Conflict ~message:("known rejection") ~details:[] |> Result.get_ok)))} in
          let reply=I.reply session ~request_id:(C.ticket_id ticket)operation
            (S.Coordination_mutations_recovered{request_id;page=Wire.{items;next=None}}) |> Result.get_ok in
          step(C.Completed(ticket,reply)))
      | 4->read n(fun(ticket,_)->step(C.Forget ticket))
      | 5->(match C.request !state session(W.Acknowledge_intent(W.Mutation_intent intent)) with Error _->()|Ok(ticket,next)->
          check(match C.intent_progress(C.view !state)(W.Mutation_intent intent) with Some(W.Rejected _)->true|_->false)
            "ACK admitted without known settled evidence";
          state:=next.next;acks:=ticket::List.take 7 !acks)
      | 6->ack n(fun ticket->step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(200+n)))))
      | 7->ack n(fun ticket->step(C.Completed(ticket,W.Answered(Ok()))))
      | 8->ack n(fun ticket->step(C.Completed(ticket,W.Interrupted W.Transport_lost)))
      | 9->ack n(fun ticket->step(C.Cancel ticket))
      | 10->ack n(fun ticket->step(C.Forget ticket))
      | _->step C.Drain)trace in
  let prefix=[0,0;1,0;3,0;4,0;0,0;1,0;5,0;6,0;7,0;3,0] in
  for seed=0 to 199 do
    let random=Random.State.make[|0xAC19;seed|] in
    let trace=prefix@List.init 64(fun _->Random.State.int random 12,Random.State.int random 8) in
    let fails trace=try run trace;false with _->true in
    if fails trace then let minimal=shrink fails trace in
      failwith(Printf.sprintf "recovery-ack seed=%d shrunk=%s" seed
        (String.concat ","(List.map(fun(op,n)->Printf.sprintf "%d:%d" op n)minimal)))
  done
;;

let test_observation_planning_is_pure () =
  let issuer, _, projection, session = fixture 720L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let ticket, planned =
    match C.request state session (W.Observe (budget, W.Graph_info)) with
    | Ok value -> value
    | Error _ -> failwith "supported observation was rejected before pure planning"
  in
  check
    (List.exists
       (function
         | C.Send (actual, _, W.Observe _) ->
           W.equal_request_id (C.ticket_id actual) (C.ticket_id ticket)
         | _ -> false)
       planned.instructions)
    "observation planning did not issue its exact typed ticket";
  check
    (C.equal_view (C.view state) (C.view (ready I.binding projection)))
    "observation planning mutated the previous state";
  check
    (C.reply (C.view planned.next) ticket = None)
    "planned registration fabricated a sampled observation"
;;

let pure_observation_response issuer raw session ticket operation epoch revision =
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let registration, owner, observation_id, request_id, read =
    match I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok with
    |S.Coordination_observe value->value.registration,value.owner,value.observation_id,value.request_id,value.read
    |Coordination_refresh_observation value->
      (match operation with
       |W.Refresh handle->value.registration,value.owner,value.observation_id,value.request_id,
          Worker_pure_read.For_worker.pack_query (W.observation_budget handle) (W.observation_query handle)
       |_->assert false)
    |_->failwith "expected a real observation request" in
  let Worker_pure_read.Read_query(budget,query)=read in
  let answer=match query with
    |Worker_pure_read.Graph_info->Worker_pure_read.For_worker.answer budget query
      (Ok(Worker_pure_read.For_worker.graph_info ~graph_uuid:graph ~graph_name:"Pure observation"
        ~schema:{major=1;minor=0} ~admission_facts:[] ~journal_title_format:None ~limits:raw.S.limits
        ~generation:"generation:v1:synthetic" ~projection_revision:revision))
    |_->failwith "this source fixture owns only Graph_info samples" in
  S.Coordination_observed{registration;owner;observation_id;request_id;epoch;answer}
;;

let test_host_candidate_waits_for_own_observation_ack () =
  let issuer,raw,projection,session=fixture 9876L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let initial=ready I.binding projection in
  let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
  let operation=W.Observe(budget,W.Graph_info) in
  let ticket,planned=C.request initial session operation |> Result.get_ok in
  let response=pure_observation_response issuer raw session ticket operation 0L "host-observation" in
  let observed=match I.reply session ~request_id:(C.ticket_id ticket)operation response |> Result.get_ok with
    |W.Answered(Ok value)->value|_->assert false in
  let admitted=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
  let sampled=(C.step admitted(C.Completed(ticket,W.Answered(Ok observed)))).next in
  let id,preparing=C.prepare_host_change sampled(W.Graph_will_close(W.graph_id session)) |> Result.get_ok in
  let plan=List.find_map(function C.Quiesce plan->Some plan|_->None)preparing.instructions |> Option.get in
  let receipt=pure_host_receipt_fixture issuer plan in
  let candidate=(C.step preparing.next(C.Handoff_completed(id,W.Safe_to_proceed receipt))).next in
  check(match C.handoff(C.view candidate)id with Some(W.Quiescing _)->true|_->false)
    "backend receipt bypassed the coordinator's own pending release ACK";
  check(Result.is_error(C.authorize_host_change candidate receipt))"candidate receipt admitted consume before local cleanup ACK";
  let released=(C.step candidate(C.Observation_release_completed(session,W.observation_id observed.observation,Ok()))).next in
  check(match C.handoff(C.view released)id with Some(W.Safe_to_proceed _)->true|_->false)
    "original release ACK did not expose the already captured exact backend receipt"
;;

let test_observation_retains_typed_value () =
  let issuer, raw, projection, session = fixture 721L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let observed =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok observed)) -> observed
    | _ -> failwith "valid observed DTO was rejected"
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ticket, W.Answered (Ok observed))) in
  check
    (C.observed (C.view completed.next) observed.observation = Some observed)
    "coordinator did not retain the exact observed value";
  check
    (C.observed (C.view admitted.next) observed.observation = None)
    "completion changed an earlier immutable observation state";
  let duplicate =
    C.step completed.next (C.Completed (ticket, W.Answered (Ok observed)))
  in
  check
    (C.equal_view (C.view completed.next) (C.view duplicate.next))
    "duplicate observed terminal response was consumed twice"
;;

let test_observation_cancel_requires_ack () =
  let issuer, raw, projection, session = fixture 722L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let observed =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "observation fixture"
  in
  let registered = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed =
    C.step registered.next (C.Completed (ticket, W.Answered (Ok observed)))
  in
  let forgotten = C.step completed.next (C.Forget ticket) in
  check
    (C.observed (C.view forgotten.next) observed.observation = Some observed)
    "Forget unregistered an observation interest";
  let cancelled = C.step forgotten.next (C.Cancel ticket) in
  check
    (C.observed (C.view cancelled.next) observed.observation = None)
    "Cancel left a retired observation visible";
  check
    (List.exists
       (function
         | C.Release_observation_registration (owner, id) ->
           W.equal_session owner session && W.equal_request_id id (C.ticket_id ticket)
         | _ -> false)
       cancelled.instructions)
    "Cancel did not plan exact resource cleanup";
  let duplicate = C.step cancelled.next (C.Cancel ticket) in
  check
    (not
       (List.exists
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          duplicate.instructions))
    "Cancel duplicated an in-flight cleanup";
  let acknowledged =
    C.step
      duplicate.next
      (C.Observation_release_completed (session, C.ticket_id ticket, Ok ()))
  in
  let late = C.step acknowledged.next (C.Completed (ticket, W.Answered (Ok observed))) in
  check
    (C.observed (C.view late.next) observed.observation = None)
    "late result revived an acknowledged retired observation"
;;

let test_observation_read_failure_and_refresh () =
  let issuer, raw, projection, session = fixture 723L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let handle, epoch =
    I.observation_registration session ~request_id:(C.ticket_id ticket) operation response
    |> Result.get_ok
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let registered =
    C.step admitted.next (C.Observation_registered (ticket, handle, epoch))
  in
  let failed =
    C.step
      registered.next
      (C.Completed (ticket, W.Answered (Error W.Response_budget_exceeded)))
  in
  check
    (C.observation_handle (C.view failed.next) ticket = Some handle)
    "sample failure erased the acknowledged interest";
  check
    (C.observation_error (C.view failed.next) handle = Some W.Response_budget_exceeded)
    "sample failure disappeared from observation state";
  let forgotten = C.step failed.next (C.Forget ticket) in
  let refreshed, refresh =
    C.request forgotten.next session (W.Refresh handle) |> Result.get_ok
  in
  let response =
    pure_observation_response
      issuer
      raw
      session
      refreshed
      (W.Refresh handle)
      1L
      "projection-1"
  in
  let value =
    match
      I.reply session ~request_id:(C.ticket_id refreshed) (W.Refresh handle) response
    with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "refresh fixture"
  in
  let admitted = C.step refresh.next (C.Admitted (refreshed, Id.Worker.Request_id.one)) in
  let registered =
    C.step admitted.next (C.Observation_registered (refreshed, handle, value.epoch))
  in
  let completed =
    C.step registered.next (C.Completed (refreshed, W.Answered (Ok value)))
  in
  check
    (C.observed (C.view completed.next) handle = Some value)
    "Refresh failed to update the retained observation";
  check
    (C.observation_error (C.view completed.next) handle = None)
    "successful Refresh retained an obsolete sample error";
  let release, planned =
    match C.request completed.next session (W.Release handle) with
    | Ok value -> value
    | _ -> failwith "registered observation Release was rejected"
  in
  check (C.reply (C.view planned.next) release = None) "Release fabricated an ACK";
  check
    (C.observed (C.view planned.next) handle = None)
    "Release still presented retired data";
  let ack =
    C.step
      planned.next
      (C.Observation_release_completed (session, W.observation_id handle, Ok ()))
  in
  check
    (C.reply (C.view ack.next) release = Some (W.Answered (Ok ())))
    "actual release ACK did not settle its unit ticket";
  let again, again_state =
    C.request ack.next session (W.Release handle) |> Result.get_ok
  in
  check
    (C.reply (C.view again_state.next) again = Some (W.Answered (Ok ())))
    "idempotent Release forgot the actual retired-resource ACK"
;;

let test_observation_notice_plans_one_refresh () =
  let issuer, raw, projection, session = fixture 724L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let operation =
    W.Observe
      ( W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
      , W.Graph_info )
  in
  let ticket, planned =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let value =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "observation fixture"
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ticket, W.Answered (Ok value))) in
  let logical =
    match response with
    | S.Coordination_observed v -> v.observation_id
    | _ -> assert false
  in
  let notice epoch =
    I.observation_notices
      (S.Coordination_observations
         (Rrbvec.singleton
            (S.Observation_invalidated
               { registration_id = raw.registration
               ; owner = Option.get raw.baseline.state.sync.selected
               ; observation_id = logical
               ; epoch
               })))
    |> Result.get_ok
    |> fun values -> Option.get (Rrbvec.nth_opt values 0)
  in
  let invalidated = C.step completed.next (C.Observation_notice (notice 1L)) in
  let count transition =
    List.fold_left
      (fun n -> function
         | C.Send (_, _, W.Refresh _) -> n + 1
         | _ -> n)
      0
      transition.C.instructions
  in
  check (count invalidated = 1) "invalidation did not plan one scoped Refresh";
  List.iter
    (function
      | C.Send (refresh, _, W.Refresh _) ->
        let admitted =
          C.step invalidated.next (C.Admitted (refresh, Id.Worker.Request_id.one))
        in
        let failed =
          C.step
            admitted.next
            (C.Completed (refresh, W.Answered (Error W.Response_budget_exceeded)))
        in
        check
          (C.observed (C.view failed.next) value.observation = Some value)
          "Refresh error erased the last good sample";
        check
          (C.observation_error (C.view failed.next) value.observation
           = Some W.Response_budget_exceeded)
          "internal Refresh failure disappeared with its forgotten ticket";
        let stale = C.step failed.next (C.Observation_received value) in
        check
          (C.observation_error (C.view stale.next) value.observation
           = Some W.Response_budget_exceeded)
          "an old retained sample cleared the newer refresh failure";
        check
          (count (C.step failed.next C.Capacity_available) = 0)
          "sample failure busy-retried without a newer invalidation";
        let busy=Logseq_db_worker.Error.create ~code:Storage_busy
          ~message:"local refresh busy" ~details:[] |> Result.get_ok in
        let transient=C.step admitted.next(C.Completed(refresh,W.Answered(Error(W.Db_error busy))))in
        check(count transient=1) "transient observation failure did not recover in the same epoch";
        List.iter(function
          |C.Send(again,_,W.Refresh same)->
            check(W.equal_request_id(W.observation_id same)(W.observation_id value.observation))
              "background recovery replaced the registered observation";
            let admitted=C.step transient.next(C.Admitted(again,Id.Worker.Request_id.one))in
            let failed=C.step admitted.next(C.Completed(again,W.Answered(Error(W.Service_failed "still unavailable"))))in
            check(count failed=0 && count(C.step failed.next C.Capacity_available)=0)
              "persistent observation failure restarted an automatic loop"
          |_->())transient.instructions
      | _ -> ())
    invalidated.instructions;
  let duplicate = C.step invalidated.next (C.Observation_notice (notice 1L)) in
  check (count duplicate = 0) "duplicate invalidation duplicated a Refresh";
  let newer = C.step duplicate.next (C.Observation_notice (notice 2L)) in
  check (count newer = 0) "in-flight refresh was duplicated instead of coalesced";
  let released = C.step newer.next (C.Release value.observation) in
  let late = C.step released.next (C.Observation_notice (notice 3L)) in
  check (count late = 0) "retired interest accepted a late invalidation"
;;

let test_observation_cleanup_failure_waits_for_explicit_retry () =
  let issuer, _, projection, session = fixture 725L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let operation =
    W.Observe
      ( W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
      , W.Graph_info )
  in
  let ticket, planned =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let admitted=C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one)) in
  let canceled=C.step admitted.next(C.Cancel ticket) in
  check(not(List.exists(function C.Release_observation_registration _->true|_->false)canceled.instructions))
    "cleanup preceded its accepted creator's actual exit";
  let canceled=C.step canceled.next(C.Completed(ticket,W.Interrupted W.Cancelled)) in
  let refused =
    C.step
      canceled.next
      (C.Observation_release_not_admitted (session, C.ticket_id ticket, W.Full))
  in
  check
    (not
       (List.exists
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          refused.instructions))
    "Full cleanup immediately retried without a capacity wakeup";
  let capacity = C.step refused.next C.Capacity_available in
  check
    (List.length
       (List.filter
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          capacity.instructions)
     = 1)
    "capacity wakeup did not retry exactly one pending cleanup";
  let error = W.Service_failed "physical cleanup is unavailable" in
  let failed =
    C.step
      canceled.next
      (C.Observation_release_completed (session, C.ticket_id ticket, Error error))
  in
  let capacity = C.step failed.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          capacity.instructions))
    "a failed cleanup busy-retried on the runner's own capacity notification";
  let retried = C.step capacity.next (C.Cancel ticket) in
  check
    (List.exists
       (function
         | C.Release_observation_registration _ -> true
         | _ -> false)
       retried.instructions)
    "explicit cleanup retry did not resume the retained resource"
;;

let test_observation_full_batch_does_not_self_wake () =
  let issuer, _, projection, session = fixture 727L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let state = ref (ready I.binding projection)
  and tickets = ref [] in
  for _ = 1 to 256 do
    let ticket, tr =
      C.request !state session (W.Observe (budget, W.Graph_info)) |> Result.get_ok
    in
    state := tr.next;
    tickets := ticket :: !tickets
  done;
  let count tr =
    List.length
      (List.filter
         (function
           | C.Release_observation_registration _ -> true
           | _ -> false)
         tr.C.instructions)
  in
  List.iter (fun ticket ->
    state := (C.step !state (C.Admitted(ticket,Id.Worker.Request_id.one))).next;
    state := (C.step !state (C.Cancel ticket)).next;
    state := (C.step !state (C.Completed(ticket,W.Interrupted W.Cancelled))).next) !tickets;
  let refuse () =
    List.iter
      (fun ticket ->
         let tr =
           C.step
             !state
             (C.Observation_release_not_admitted (session, C.ticket_id ticket, W.Full))
         in
         check (count tr = 0) "Full cleanup immediately re-entered its own batch";
         state := tr.next)
      !tickets
  in
  refuse ();
  let capacity = C.step !state C.Capacity_available in
  check (count capacity = 128) "cleanup did not bound its capacity-woken retry batch";
  state := capacity.next;
  refuse ();
  let drain = C.step !state C.Drain in
  check
    (count drain = 0
     && not
          (List.exists
             (function
               | C.Schedule_drain -> true
               | _ -> false)
             drain.instructions))
    "internally scheduled Drain repeatedly retried a Full batch without capacity"
;;

let test_observation_focus_and_reopen_fences () =
  let issuer, raw, projection, session = fixture 728L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let project raw =
    match I.bootstrap (S.Coordination_registered raw) with
    | Ok (W.Ready p) -> p
    | _ -> failwith "scope fixture"
  in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "initial"
  in
  let value =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok v)) -> v
    | _ -> failwith "scope observed fixture"
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let done_ = C.step admitted.next (C.Completed (ticket, W.Answered (Ok value))) in
  let focused =
    project { raw with baseline = { raw.baseline with version = 2L; presentation = 2L } }
  in
  let focused = C.step done_.next (C.Projection_received focused) in
  check
    (C.observed (C.view focused.next) value.observation = Some value)
    "presentation change revoked a resident observation";
  let closed =
    project
      { raw with
        baseline =
          { version = 3L
          ; presentation = 3L
          ; state =
              { sync =
                  { raw.baseline.state.sync with
                    desired_residents = []
                  ; residents = []
                  ; selected = None
                  }
              ; residents = []
              }
          }
      }
  in
  let closed = C.step focused.next (C.Projection_received closed) in
  check
    (C.observed (C.view closed.next) value.observation = None)
    "closed graph retained an observed value";
  check
    (List.exists
       (function
         | C.Release_observation_registration (owner, id) ->
           W.equal_session owner session && W.equal_request_id id (C.ticket_id ticket)
         | _ -> false)
       closed.instructions)
    "close did not retain the exact old resource cleanup owner";
  let bump (scope : S.asset_scope) =
    { scope with graph_generation = scope.graph_generation + 1 }
  in
  let owner = Option.get raw.baseline.state.sync.selected in
  let reopened =
    project
      { raw with
        baseline =
          { version = 4L
          ; presentation = 4L
          ; state =
              { sync =
                  { raw.baseline.state.sync with
                    selected =
                      Some { owner with graph_generation = owner.graph_generation + 1 }
                  ; residents =
                      List.map
                        (fun (scope, state) -> bump scope, state)
                        raw.baseline.state.sync.residents
                  }
              ; residents =
                  List.map
                    (fun (scope, state) ->
                       ( bump scope
                       , { state with
                           Logseq_db_worker.generation =
                             state.Logseq_db_worker.generation + 1
                         } ))
                    raw.baseline.state.residents
              }
          }
      }
  in
  let reopened = C.step closed.next (C.Projection_received reopened) in
  let late = C.step reopened.next (C.Observation_received value) in
  check
    (C.observed (C.view late.next) value.observation = None)
    "old value revived a reopened graph";
  check
    (Result.is_error (C.request late.next session (W.Refresh value.observation)))
    "old observation refreshed the reopened graph";
  let new_session =
    (List.hd (W.residents (Option.get (C.projection (C.view late.next))))).session
  in
  let new_budget =
    W.read_budget new_session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  check
    (Result.is_ok
       (C.request late.next new_session (W.Observe (new_budget, W.Graph_info))))
    "old observation cleanup incorrectly fenced a new graph generation";
  let acknowledged =
    C.step
      late.next
      (C.Observation_release_completed (session, C.ticket_id ticket, Ok ()))
  in
  let repeated = C.step acknowledged.next (C.Observation_received value) in
  check
    (C.observed (C.view repeated.next) value.observation = None)
    "old released value resurfaced"
;;

let test_observation_retirement_capacity_resets_only_after_binding_ack () =
  let issuer, raw, projection, session = fixture 729L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let state = ref (ready I.binding projection)
  and old_value = ref None in
  let step event = state := (C.step !state event).next in
  for n = 1 to 8192 do
    let ticket, tr =
      C.request !state session (W.Observe (budget, W.Graph_info)) |> Result.get_ok
    in
    if n = 1
    then (
      let operation = W.Observe (budget, W.Graph_info) in
      let response =
        pure_observation_response issuer raw session ticket operation 0L "old-binding"
      in
      old_value
      := match I.reply session ~request_id:(C.ticket_id ticket) operation response with
         | Ok (W.Answered (Ok value)) -> Some value
         | _ -> assert false);
    state := tr.next;
    step (C.Admitted (ticket, Id.Worker.Request_id.one));
    step (C.Cancel ticket);
    step (C.Completed (ticket, W.Interrupted W.Cancelled));
    step (C.Forget ticket);
    step (C.Observation_release_completed (session, C.ticket_id ticket, Ok ()));
    step (C.Observation_finalize_completed (session, C.ticket_id ticket, Ok ()))
  done;
  check
    (Result.is_ok (C.request !state session (W.Observe (budget, W.Graph_info))))
    "returned observation identities exhausted normal browsing";
  step C.Retry_bootstrap;
  step (C.Binding_release_completed (I.binding, Ok ()));
  let next_issuer, _, next_projection, next_session = fixture 730L in
  let module Next = (val next_issuer : Worker_effect_authority.ISSUER) in
  step (C.Worker_bound Next.binding);
  step (C.Bootstrap_received (Next.binding, W.Ready next_projection));
  let budget =
    W.read_budget next_session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let _, fresh =
    match C.request !state next_session (W.Observe (budget, W.Graph_info)) with
    | Ok value -> value
    | _ ->
      failwith
        "retired IDs from an acknowledged old binding permanently exhausted new \
         observation capacity"
  in
  state := fresh.next;
  let before = C.view !state in
  let old = Option.get !old_value in
  step (C.Observation_received old);
  step (C.Release old.observation);
  step
    (C.Observation_release_completed (session, W.observation_id old.observation, Ok ()));
  check
    (C.equal_view before (C.view !state))
    "old binding callbacks affected a new interest";
  check
    (Result.is_error (C.request !state next_session (W.Release old.observation)))
    "old handle claimed cleanup authority in the replacement binding"
;;

(* Generate admitted histories plus adversarial delivery orders through the public
   pure boundary. No implementation tables or private handle constructors. *)
let test_observation_properties () =
  let issuer, raw, projection, session = fixture 726L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let run trace =
    let state = ref (ready I.binding projection) in
    let attempts : (W.graph_info W.observed C.ticket * W.graph_info W.observed) list ref =
      ref []
    in
    let interests
      : (W.graph_info W.observed C.ticket * W.graph_info W.observation) list ref
      =
      ref []
    in
    let retired = ref []
    and seen = ref []
    and accepted = ref [] in
    let next_epoch = ref 0L in
    let forbid id =
      if not (List.exists (W.equal_request_id id) !retired) then retired := id :: !retired
    in
    let verify () =
      List.iter
        (fun (ticket, handle) ->
           let id = C.ticket_id ticket in
           let value = C.observed (C.view !state) handle in
           if List.exists (W.equal_request_id id) !retired
           then check (value = None) "retired observation revived";
           match value with
           | None -> ()
           | Some value ->
             check
               (W.same_observation value.observation handle <> None)
               "observation changed its sealed owner";
             let previous =
               List.find_map
                 (fun (actual, epoch) ->
                    if W.equal_request_id actual id then Some epoch else None)
                 !seen
             in
             check
               (Option.fold
                  ~none:true
                  ~some:(fun epoch -> W.compare_observation_epoch value.epoch epoch >= 0)
                  previous)
               "observation epoch moved backwards";
             seen
             := (id, value.epoch)
                :: List.filter
                     (fun (actual, _) -> not (W.equal_request_id actual id))
                     !seen)
        !interests
    in
    let record : type a. a C.ticket -> a W.request -> unit =
      fun ticket operation ->
      match operation with
      | W.Observe (_, W.Graph_info) ->
        let response =
          pure_observation_response issuer raw session ticket operation 0L "initial"
        in
        let value =
          match I.reply session ~request_id:(C.ticket_id ticket) operation response with
          | Ok (W.Answered (Ok value)) -> value
          | _ -> failwith "property initial codec"
        in
        attempts := (ticket, value) :: !attempts;
        interests := (ticket, value.observation) :: !interests
      | W.Refresh handle ->
        (match W.observation_query handle with
         | W.Graph_info ->
           next_epoch := Int64.succ !next_epoch;
           let response =
             pure_observation_response
               issuer
               raw
               session
               ticket
               operation
               !next_epoch
               (Int64.to_string !next_epoch)
           in
           let value =
             match
               I.reply session ~request_id:(C.ticket_id ticket) operation response
             with
             | Ok (W.Answered (Ok value)) -> value
             | _ -> failwith "property refresh codec"
           in
           attempts := (ticket, value) :: !attempts
         | _ -> ())
      | _ -> ()
    in
    let apply transition =
      state := transition.C.next;
      List.iter
        (function
          | C.Send (ticket, owner, operation) ->
            check (W.equal_session owner session) "refresh switched its execution owner";
            record ticket operation
          | C.Release_observation_registration (owner, id) ->
            check
              (W.equal_session owner session
               && List.exists
                    (fun (ticket, _) -> W.equal_request_id id (C.ticket_id ticket))
                    !interests)
              "cleanup adopted an unplanned/foreign observation"
          | _ -> ())
        transition.instructions;
      check (List.length transition.instructions < 1000) "observation batch overflow";
      verify ()
    in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "observation step is nondeterministic";
      check (C.equal_view before (C.view !state)) "observation mutated its input view";
      apply a
    in
    let attempt n f =
      match List.nth_opt !attempts (n mod max 1 (List.length !attempts)) with
      | Some x -> f x
      | None -> ()
    in
    let interest n f =
      match List.nth_opt !interests (n mod max 1 (List.length !interests)) with
      | Some x -> f x
      | None -> ()
    in
    List.iter
      (fun (op, n) ->
         match op with
         | 0 ->
           (match C.request !state session (W.Observe (budget, W.Graph_info)) with
            | Ok (_, transition) -> apply transition
            | _ -> ())
         | 1 ->
           attempt n (fun (ticket, _) ->
             accepted := C.ticket_id ticket :: !accepted;
             step
               (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
         | 2 ->
           attempt n (fun (ticket, value) ->
             step (C.Observation_registered (ticket, value.observation, value.epoch)))
         | 3 ->
           attempt n (fun (ticket, value) ->
             step (C.Completed (ticket, W.Answered (Ok value)));
             let once = C.reply (C.view !state) ticket in
             step (C.Completed (ticket, W.Answered (Ok value)));
             check
               (C.reply (C.view !state) ticket = once)
               "observation terminal consumed twice")
         | 4 ->
           interest n (fun (ticket, _) ->
             forbid (C.ticket_id ticket);
             step (C.Cancel ticket))
         | 5 -> interest n (fun (ticket, _) -> step (C.Forget ticket))
         | 6 ->
           interest n (fun (ticket, _) ->
             let owner = Option.get raw.baseline.state.sync.selected in
             let owner =
               if n mod 4 = 0
               then { owner with graph_generation = owner.graph_generation + 1 }
               else owner
             in
             let wire =
               match
                 I.request
                   session
                   ~request_id:(C.ticket_id ticket)
                   (W.Observe (budget, W.Graph_info))
                 |> Result.get_ok
               with
               | S.Coordination_observe v -> v.observation_id
               | _ -> assert false
             in
             let notices =
               I.observation_notices
                 (S.Coordination_observations
                    (Rrbvec.singleton
                       (S.Observation_invalidated
                          { registration_id = raw.registration
                          ; owner
                          ; observation_id = wire
                          ; epoch = Int64.of_int (n mod 9)
                          })))
               |> Result.get_ok
             in
             Rrbvec.iter (fun notice -> step (C.Observation_notice notice)) notices)
         | 7 ->
           interest n (fun (ticket, handle) ->
             forbid (C.ticket_id ticket);
             step (C.Release handle))
         | 8 ->
           interest n (fun (ticket, _) ->
             step (C.Observation_release_completed (session, C.ticket_id ticket, Ok ())))
         | 9 ->
           attempt n (fun (ticket, _) ->
             if
               List.exists
                 (fun (original, _) ->
                    W.equal_request_id (C.ticket_id original) (C.ticket_id ticket))
                 !interests
               && (not (List.exists (W.equal_request_id (C.ticket_id ticket)) !accepted))
               && C.reply (C.view !state) ticket = None
             then forbid (C.ticket_id ticket);
             step (C.Admission_refused (ticket, W.Full)))
         | 10 ->
           attempt n (fun (ticket, _) ->
             step (C.Completed (ticket, W.Answered (Error W.Response_budget_exceeded))))
         | 11 -> step C.Capacity_available
         | 12 ->
           List.iter (fun (ticket, _) -> forbid (C.ticket_id ticket)) !interests;
           step C.Shutdown_requested
         | 13 -> step (C.Binding_release_completed (I.binding, Ok ()))
         | 14 -> step (C.Bootstrap_received (I.binding, W.Ready projection))
         | 15 ->
           interest n (fun (ticket, _) ->
             step
               (C.Observation_release_not_admitted (session, C.ticket_id ticket, W.Full)))
         | 16 ->
           interest n (fun (ticket, _) ->
             step
               (C.Observation_release_completed
                  (session, C.ticket_id ticket, Error (W.Service_failed "held"))))
         | 17 ->
           interest n (fun (_, handle) ->
             match C.request !state session (W.Refresh handle) with
             | Ok (_, tr) -> apply tr
             | _ -> ())
         | _ -> attempt n (fun (_, value) -> step (C.Observation_received value)))
      trace
  in
  let prefixes =
    [ [ 0, 0; 1, 0; 2, 0; 3, 0; 6, 1; 1, 0; 2, 0; 3, 0 ]
    ; [ 0, 0; 3, 0; 4, 0; 1, 0; 2, 0; 8, 0 ]
    ; [ 0, 0; 2, 0; 10, 0; 1, 0; 5, 0; 17, 0 ]
    ; [ 0, 0; 3, 0; 9, 0; 2, 0; 8, 0 ]
    ; [ 0, 0; 5, 0; 2, 0; 1, 0; 3, 0; 7, 0; 15, 0; 11, 0; 8, 0 ]
    ; [ 0, 0; 1, 0; 2, 0; 3, 0; 12, 0; 13, 0; 14, 0; 3, 0 ]
    ]
  in
  for seed = 0 to 299 do
    let random = Random.State.make [| 0x0b5e7; seed |] in
    let trace =
      List.nth prefixes (seed mod List.length prefixes)
      @ List.init 80 (fun _ ->
        let op = Random.State.int random 19 in
        (if op = 12 && seed mod 3 <> 0 then 6 else op), Random.State.int random 24)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let minimal = shrink fails trace in
      try run minimal with
      | exn ->
        failwith
          (Printf.sprintf
             "observation property seed=%d minimal=[%s]: %s"
             seed
             (String.concat
                ";"
                (List.map (fun (op, n) -> Printf.sprintf "%d:%d" op n) minimal))
             (Printexc.to_string exn)))
  done
;;

let test_dependency_read_waits_for_capacity () =
  let issuer, raw, projection, session = fixture 745L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let state = ready I.binding projection in
  let ticket, planned =
    C.plan_query_when_available
      state
      ~owner
      ~maximum_items:1
      ~maximum_bytes:65536
      (W.Outline_block { uuid = graph; revision = None })
    |> Result.get_ok
  in
  let full = C.step planned.next (C.Admission_refused (ticket, W.Full)) in
  check
    (C.reply (C.view full.next) ticket = None)
    "Full terminated a logical dependency read";
  let ignored =
    C.step
      full.next
      (C.Completed
         (ticket, W.Answered (Error (W.Service_failed "impossible unadmitted completion"))))
  in
  check
    (C.reply (C.view ignored.next) ticket = None)
    "unadmitted completion escaped capacity waiting";
  let drain = C.step ignored.next C.Drain in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          drain.instructions))
    "Full dependency self-retried on Drain";
  let capacity = C.step drain.next C.Capacity_available in
  check
    (List.exists
       (function
         | C.Send (actual, actual_session, W.Query (_, W.Outline_block _)) ->
           W.equal_request_id (C.ticket_id actual) (C.ticket_id ticket)
           && W.equal_session actual_session session
         | _ -> false)
       capacity.instructions)
    "capacity did not retry the exact dependency ticket and session";
  let duplicate = C.step capacity.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          duplicate.instructions))
    "capacity duplicated an active dependency read";
  let admitted = C.step duplicate.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let contradictory = C.step admitted.next (C.Admission_refused (ticket, W.Full)) in
  check
    (C.reply (C.view contradictory.next) ticket = None)
    "late Full replaced an admitted read";
  let completed =
    C.step
      contradictory.next
      (C.Completed (ticket, W.Answered (Error (W.Service_failed "actual read failure"))))
  in
  check
    (C.reply (C.view completed.next) ticket
     = Some (W.Answered (Error (W.Service_failed "actual read failure"))))
    "capacity waiting hid an actual terminal read failure";
  let cancelled = C.step full.next (C.Cancel ticket) in
  let capacity = C.step cancelled.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          capacity.instructions))
    "cancelled waiting dependency was resent";
  let unavailable = C.step planned.next (C.Admission_refused (ticket, W.Not_ready)) in
  check
    (C.reply (C.view unavailable.next) ticket = Some (W.Not_admitted W.Not_ready))
    "capacity planner hid a non-Full refusal";
  let bump (scope : S.asset_scope) =
    { scope with
      account =
        { scope.account with
          lifecycle_generation = Int64.succ scope.account.lifecycle_generation
        }
    }
  in
  let baseline =
    { raw.baseline with
      version = 2L
    ; state =
        { sync =
            { raw.baseline.state.sync with
              account =
                Option.map
                  (fun (account : Sync.account_scope) ->
                     { account with
                       lifecycle_generation = Int64.succ account.lifecycle_generation
                     })
                  raw.baseline.state.sync.account
            ; residents =
                List.map
                  (fun (scope, value) -> bump scope, value)
                  raw.baseline.state.sync.residents
            }
        ; residents =
            List.map
              (fun (scope, value) -> bump scope, value)
              raw.baseline.state.residents
        }
    }
  in
  let changed =
    match I.bootstrap (S.Coordination_registered { raw with baseline }) with
    | Ok (W.Ready value) -> value
    | _ -> failwith "capacity lifecycle fixture"
  in
  let retired = C.step full.next (C.Projection_received changed) in
  let capacity = C.step retired.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          capacity.instructions))
    "capacity retry borrowed a replacement lifecycle";
  check
    (C.reply (C.view capacity.next) ticket = Some (W.Answered (Error W.Revoked_session)))
    "capacity retry retained a stale execution origin";
  let ordinary, planned =
    C.plan_query state ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  let refused = C.step planned.next (C.Admission_refused (ordinary, W.Full)) in
  check
    (C.reply (C.view refused.next) ordinary = Some (W.Not_admitted W.Full))
    "ordinary planner lost its explicit refusal semantics"
;;

let test_live_binding_invalidation_is_pure () =
  let old_issuer, _, old_projection, old_session = fixture 741L in
  let new_issuer, _, new_projection, new_session = fixture 742L in
  let module Old = (val old_issuer : Worker_effect_authority.ISSUER) in
  let module New = (val new_issuer : Worker_effect_authority.ISSUER) in
  let initial = ready Old.binding old_projection in
  let invalidated = C.step initial (C.Binding_invalidated Old.binding) in
  check
    (C.validate_session invalidated.next old_session = Error W.Revoked_session)
    "live invalidation left old session data admission open";
  check
    (List.exists
       (function
         | C.Release_binding binding -> W.equal_binding binding Old.binding
         | _ -> false)
       invalidated.instructions)
    "live invalidation did not require actual old registration release";
  let released =
    C.step invalidated.next (C.Binding_release_completed (Old.binding, Ok ()))
  in
  let bound = C.step released.next (C.Worker_bound New.binding) in
  let denied =
    C.step
      bound.next
      (C.Bootstrap_received (New.binding, W.Binding_revoked W.Revoked_session))
  in
  let capacity = C.step denied.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Bind_replacement | C.Bootstrap -> true
            | _ -> false)
          capacity.instructions))
    "replacement authority denial created an automatic registration loop";
  let run trace =
    let state = ref invalidated.next
    and released = ref false
    and replaced = ref false in
    List.iter
      (fun op ->
         let event =
           match op with
           | 0 -> C.Binding_invalidated Old.binding
           | 1 -> C.Projection_received old_projection
           | 2 -> C.Bootstrap_received (Old.binding, W.Ready old_projection)
           | 3 -> C.Capacity_available
           | 4 -> C.Drain
           | 5 -> C.Binding_release_completed (Old.binding, Ok ())
           | 6 -> C.Binding_release_not_admitted (Old.binding, W.Full)
           | 7 -> C.Worker_bound New.binding
           | _ -> C.Bootstrap_received (New.binding, W.Ready new_projection)
         in
         let before = C.view !state in
         let tr = C.step !state event in
         check
           (C.equal_view (C.view !state) before)
           "live invalidation mutated a prior view";
         check
           (C.equal_view (C.view tr.next) (C.view (C.step !state event).next))
           "invalidation ceased to be deterministic";
         List.iter
           (function
             | C.Bind_replacement ->
               check
                 (!released && not !replaced)
                 "replacement escaped one real release ACK";
               replaced := true
             | _ -> ())
           (if op = 5
            then (
              released := true;
              tr.instructions)
            else tr.instructions);
         state := tr.next;
         check
           (C.validate_session !state old_session = Error W.Revoked_session)
           "late old binding revived its session";
         if C.validate_session !state new_session = Ok ()
         then check (!released && !replaced) "fresh session preceded actual replacement")
      trace
  in
  for seed = 0 to 199 do
    let random = Random.State.make [| 0xb1d; seed |] in
    let trace =
      [ 0; 1; 2; 6; 3; 5; 7; 8 ] @ List.init 64 (fun _ -> Random.State.int random 9)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let minimal = shrink fails trace in
      try run minimal with
      | error ->
        failwith
          (Printf.sprintf
             "binding invalidation seed=%d minimal=[%s]: %s"
             seed
             (String.concat "," (List.map string_of_int minimal))
             (Printexc.to_string error)))
  done
;;

let test_changefeed_planning_owns_its_typed_ticket () =
  let issuer, _, projection, session = fixture 731L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let ticket, planned =
    match
      C.request
        state
        session
        (W.Query
           (budget, W.Changes { generation = "generation:v1:synthetic"; after = None }))
    with
    | Ok value -> value
    | Error _ -> failwith "typed changefeed pull is still rejected before owned planning"
  in
  check
    (List.exists
       (function
         | C.Send (actual, owner, W.Query (_, W.Changes _)) ->
           W.equal_session owner session
           && W.equal_request_id (C.ticket_id actual) (C.ticket_id ticket)
         | _ -> false)
       planned.instructions)
    "Changes did not use its exact pure coordinator ticket";
  check (C.reply (C.view planned.next) ticket = None) "planned Changes fabricated a batch"
;;

let test_changes_serial_and_ack_capacity () =
  let issuer, _, projection, session = fixture 736L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ref (ready I.binding projection) in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Query (budget, W.Changes { generation = "g"; after = None }) in
  let first, planned = C.request !state session operation |> Result.get_ok in
  let second, queued = C.request planned.next session operation |> Result.get_ok in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          queued.instructions))
    "same-session Changes dispatched concurrently";
  let failed = C.step queued.next (C.Admission_refused (first, W.Full)) in
  let retry = C.step failed.next C.Capacity_available in
  check
    (List.exists
       (function
         | C.Send (ticket, _, W.Query (_, W.Changes _)) ->
           W.equal_request_id (C.ticket_id ticket) (C.ticket_id second)
         | _ -> false)
       retry.instructions)
    "queued Changes did not progress after the earlier request terminated";
  state := retry.next;
  let request_id =
    match
      I.request session ~request_id:(C.ticket_id second) operation |> Result.get_ok
    with
    | S.Coordination_query value -> value.request_id
    | _ -> assert false
  in
  let batch =
    match
      I.reply
        session
        ~request_id:(C.ticket_id second)
        operation
        ((changes_answer session (request_id) budget ~generation:("g") ~after:(None) ~through:("zero") ~windows:([]) ~next:(None)))
    with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "serial Changes fixture"
  in
  state := (C.step !state (C.Admitted (second, Id.Worker.Request_id.one))).next;
  state := (C.step !state (C.Completed (second, W.Answered (Ok batch)))).next;
  let root = uuid "98000000-0000-4000-8000-000000007361" in
  let token, begun = C.begin_change_application !state batch ~root |> Result.get_ok in
  state
  := (C.step begun.next (C.Change_consumer_expanded (token, root, Rrbvec.empty))).next;
  state := (C.step !state (C.Change_consumer_applied (token, root, Ok ()))).next;
  let ack, planned =
    C.request !state session (W.Acknowledge_changes batch) |> Result.get_ok
  in
  let full = C.step planned.next (C.Admission_refused (ack, W.Full)) in
  check
    (C.reply (C.view full.next) ack = None)
    "Full terminated an ACK while retaining its only unapplied chain";
  let drained = C.step full.next C.Drain in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          drained.instructions))
    "Full ACK self-retried without a capacity notification";
  let available = C.step drained.next C.Capacity_available in
  check
    (List.exists
       (function
         | C.Send (ticket, _, W.Acknowledge_changes _) ->
           W.equal_request_id (C.ticket_id ticket) (C.ticket_id ack)
         | _ -> false)
       available.instructions)
    "capacity did not retry the exact unapplied ACK";
  let duplicate = C.step available.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          duplicate.instructions))
    "capacity duplicated an in-flight ACK";
  let admitted =
    C.step duplicate.next (C.Admitted (ack, Id.Worker.Request_id.of_int64 2L))
  in
  let failed =
    C.step
      admitted.next
      (C.Completed (ack, W.Answered (Error (W.Service_failed "transient ACK failure"))))
  in
  check
    (C.change_application_error (C.view failed.next) batch
     = Some (W.Service_failed "transient ACK failure"))
    "failed ACK left the unapplied chain permanently ready but unrepeatable";
  let retry, planned = C.request failed.next session operation |> Result.get_ok in
  check
    (List.exists
       (function
         | C.Send (ticket, _, W.Query (_, W.Changes _)) ->
           W.equal_request_id (C.ticket_id ticket) (C.ticket_id retry)
         | _ -> false)
       planned.instructions)
    "later refresh could not reread the exact failed ACK chain"
;;

let test_changefeed_ack_requires_owned_delivered_batch () =
  let issuer, _, projection, session = fixture 732L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation =
    W.Query (budget, W.Changes { generation = "generation:v1:synthetic"; after = None })
  in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let window : Worker_pure_data.change_window =
    { id = "window-1"
    ; predecessor = "projection-0"
    ; successor = "projection-1"
    ; block_uuids = [ graph ]
    ; page_uuids = []
    ; structure_interests = []
    }
  in
  let response =
    (changes_answer session ((match
                I.request session ~request_id:(C.ticket_id ticket) operation
                |> Result.get_ok
              with
              | S.Coordination_query v -> v.request_id
              | _ -> assert false)) budget ~generation:("generation:v1:synthetic") ~after:(None) ~through:("window-1") ~windows:([ window ]) ~next:(None))
  in
  let batch =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok batch)) -> batch
    | _ -> failwith "checked Changes batch codec"
  in
  check
    (Result.is_error (C.request planned.next session (W.Acknowledge_changes batch)))
    "a decoded batch was ACKed before coordinator delivery/admission";
  let late, late_plan = C.request planned.next session operation |> Result.get_ok in
  let admitted = C.step late_plan.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ticket, W.Answered (Ok batch))) in
  let forgotten = C.step completed.next (C.Forget ticket) in
  let root = uuid "98000000-0000-4000-8000-000000007321" in
  let application, begun =
    C.begin_change_application forgotten.next batch ~root |> Result.get_ok
  in
  let pending_ack, pending_plan =
    C.request begun.next session (W.Acknowledge_changes batch) |> Result.get_ok
  in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          pending_plan.instructions))
    "Changes ACK was sent before its consumer root was applied";
  let child = uuid "98000000-0000-4000-8000-000000007322" in
  let early =
    C.step pending_plan.next (C.Change_consumer_applied (application, root, Ok ()))
  in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          early.instructions))
    "UI completion ACKed before the full causal work set was sealed";
  let root_applied =
    C.step
      early.next
      (C.Change_consumer_expanded (application, root, Rrbvec.singleton child))
  in
  check
    (not (C.change_application_ready (C.view root_applied.next) batch))
    "root application ignored its child";
  let failed =
    C.step
      root_applied.next
      (C.Change_consumer_applied (application, child, Error W.Response_budget_exceeded))
  in
  check
    (C.change_application_error (C.view failed.next) batch
     = Some W.Response_budget_exceeded)
    "failed consumer discarded its change window";
  let retry_root = uuid "98000000-0000-4000-8000-000000007323" in
  let retry, restarted =
    C.begin_change_application failed.next batch ~root:retry_root |> Result.get_ok
  in
  let old =
    C.step restarted.next (C.Change_consumer_applied (application, child, Ok ()))
  in
  check
    (not (C.change_application_ready (C.view old.next) batch))
    "old callback applied a retried consumer window";
  let expanded =
    C.step old.next (C.Change_consumer_expanded (retry, retry_root, Rrbvec.empty))
  in
  let applied =
    C.step expanded.next (C.Change_consumer_applied (retry, retry_root, Ok ()))
  in
  check
    (C.change_application_ready (C.view applied.next) batch)
    "complete consumer state was not eligible for ACK";
  check
    (List.exists
       (function
         | C.Send (actual, _, W.Acknowledge_changes _) ->
           W.equal_request_id (C.ticket_id actual) (C.ticket_id pending_ack)
         | _ -> false)
       applied.instructions)
    "queued ACK did not wait for the actual consumer application barrier";
  let forgotten = applied in
  let ack, ack_plan =
    match C.request forgotten.next session (W.Acknowledge_changes batch) with
    | Ok value -> value
    | _ -> failwith "owned delivered batch cannot plan its typed ACK"
  in
  let resync_admitted =
    C.step ack_plan.next (C.Admitted (ack, Id.Worker.Request_id.one))
  in
  let resync =
    C.step
      resync_admitted.next
      (C.Completed
         (ack, W.Answered (Error (W.Resync_required "authoritative generation changed"))))
  in
  check
    (Result.is_ok
       (C.request
          resync.next
          session
          (W.Query (budget, W.Changes { generation = "fresh-generation"; after = None }))))
    "ACK resync retained an old batch and blocked a fresh baseline";
  let response=match I.request session ~request_id:(C.ticket_id ack) (W.Acknowledge_changes batch)
    |> Result.get_ok with
    |S.Coordination_acknowledge_changes value->
      check(value.batch=batch) "ACK changed the original delivered batch";
      changes_ack_answer session value.request_id batch
    |_->failwith "ACK did not use the original delivered batch" in
  let receipt =
    match
      I.reply session ~request_id:(C.ticket_id ack) (W.Acknowledge_changes batch) response
    with
    | Ok (W.Answered (Ok receipt)) -> receipt
    | _ -> failwith "actual ACK receipt codec"
  in
  let admitted = C.step ack_plan.next (C.Admitted (ack, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ack, W.Answered (Ok receipt))) in
  let forgotten = C.step completed.next (C.Forget ack) in
  check
    (Result.is_ok (C.request forgotten.next session (W.Acknowledge_changes batch)))
    "duplicate ACK lost the exact consumed-window proof";
  let late_admitted =
    C.step forgotten.next (C.Admitted (late, Id.Worker.Request_id.one))
  in
  let stale = C.step late_admitted.next (C.Completed (late, W.Answered (Ok batch))) in
  check
    (match C.reply (C.view stale.next) late with
     | None | Some (W.Answered (Error (W.Stale_read _))) -> true
     | _ -> false)
    "a late pull reintroduced a batch after its ACK completed";
  check
    (Result.is_error
       (C.request
          forgotten.next
          session
          (W.Query
             ( budget
             , W.Changes { generation = batch.generation; after = Some "foreign-window" }
             ))))
    "arbitrary Changes cursor escaped the owned chain"
;;

let test_empty_change_batch_ack_retires_old_reads () =
  let issuer, _, projection, session = fixture 733L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let state = ref (ready I.binding projection) in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let apply tr = state := tr.C.next in
  let step event = apply (C.step !state event) in
  let pull after through windows =
    let operation = W.Query (budget, W.Changes { generation = "g"; after }) in
    let ticket, tr = C.request !state session operation |> Result.get_ok in
    apply tr;
    let request_id =
      match
        I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok
      with
      | S.Coordination_query value -> value.request_id
      | _ -> assert false
    in
    let batch =
      match
        I.reply
          session
          ~request_id:(C.ticket_id ticket)
          operation
          ((changes_answer session (request_id) budget ~generation:("g") ~after:(after) ~through:(through) ~windows:(windows) ~next:(None)))
      with
      | Ok (W.Answered (Ok value)) -> value
      | _ -> failwith "empty batch fixture"
    in
    ticket, batch
  in
  let complete (ticket, batch) =
    step (C.Admitted (ticket, Id.Worker.Request_id.one));
    step (C.Completed (ticket, W.Answered (Ok batch)))
  in
  let ack n batch =
    let root = uuid (Printf.sprintf "98000000-0000-4000-8000-%012d" (7330 + n)) in
    let token, tr = C.begin_change_application !state batch ~root |> Result.get_ok in
    apply tr;
    step (C.Change_consumer_expanded (token, root, Rrbvec.empty));
    step (C.Change_consumer_applied (token, root, Ok ()));
    let ticket, tr =
      C.request !state session (W.Acknowledge_changes batch) |> Result.get_ok
    in
    apply tr;
    let request_id =
      match
        I.request session ~request_id:(C.ticket_id ticket) (W.Acknowledge_changes batch)
        |> Result.get_ok
      with
      | S.Coordination_acknowledge_changes value -> value.request_id
      | _ -> assert false
    in
    let receipt =
      match
        I.reply
          session
          ~request_id:(C.ticket_id ticket)
          (W.Acknowledge_changes batch)
          ((changes_ack_answer session (request_id) batch))
      with
      | Ok (W.Answered (Ok value)) -> value
      | _ -> failwith "empty batch ACK fixture"
    in
    step (C.Admitted (ticket, Id.Worker.Request_id.one));
    step (C.Completed (ticket, W.Answered (Ok receipt)))
  in
  let window id before after : Worker_pure_data.change_window =
    { id
    ; predecessor = before
    ; successor = after
    ; block_uuids = [ graph ]
    ; page_uuids = []
    ; structure_interests = []
    }
  in
  let a = pull None "a" [ window "a" "p0" "p1" ] in
  complete a;
  ack 1 (snd a);
  let b = pull (Some "a") "a" [] in
  let late = pull (Some "a") "a" [] in
  complete b;
  ack 2 (snd b);
  let c = pull (Some "a") "c" [ window "c" "p1" "p2" ] in
  complete c;
  complete late;
  check
    (match C.reply (C.view !state) (fst late) with
     | None | Some (W.Answered (Error (W.Stale_read _))) -> true
     | _ -> false)
    "empty batch ACK did not fence its old read epoch";
  check
    (Result.is_ok (C.request !state session (W.Acknowledge_changes (snd c))))
    "a late empty batch overwrote the later nonempty batch";
  ack 3 (snd c);
  step C.Capacity_available;
  check
    (match C.reply (C.view !state) (fst late) with
     | Some (W.Answered (Error (W.Stale_read _))) -> true
     | _ -> false)
    "obsolete queued continuation demanded a fresh graph baseline instead of retiring \
     only its read";
  let gap = pull (Some "c") "gap" [ window "gap" "unrelated-projection" "p3" ] in
  complete gap;
  check
    (match C.reply (C.view !state) (fst gap) with
     | Some (W.Answered (Error (W.Resync_required _))) -> true
     | _ -> false)
    "cross-batch projection gap was treated as a continuous change chain";
  check
    (Result.is_ok
       (C.request
          !state
          session
          (W.Query (budget, W.Changes { generation = "fresh-generation"; after = None }))))
    "projection gap did not retire its proof for a fresh baseline"
;;

let test_scoped_change_notices_and_lifecycle () =
  let issuer, raw, projection, session = fixture 735L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let scope = fst (List.hd raw.baseline.state.residents) in
  let available =
    Worker_pure_data.Changes_available {generation="g";through="w"}
  in
  let resync =
    Worker_pure_data.Resync_required {generation="g";reason="history gap"}
  in
  let decode scope push =
    I.changefeed_notices (S.Graph_pushes [ scope, push ]) |> Result.get_ok
  in
  let fact = Option.get (Rrbvec.nth_opt (decode scope available) 0) in
  let reset = Option.get (Rrbvec.nth_opt (decode scope resync) 0) in
  let state = ready I.binding projection in
  let seen =
    C.step state (C.Changefeed_notice (fact, Id.Worker.Push_sequence.of_int64 2L))
  in
  let old = C.step seen.next (C.Changefeed_notice (reset, Id.Worker.Push_sequence.one)) in
  check
    (W.changefeed_notice_scope fact = scope
     && Rrbvec.to_list (C.changefeed_updates ~previous:(Some (C.view state)) (C.view seen.next)) = [fact]
     && Rrbvec.is_empty (C.changefeed_updates ~previous:(Some (C.view seen.next)) (C.view old.next)))
    "business changefeed outlet lost its checked notice or repeated a stale notice";
  check
    (C.equal_view (C.view seen.next) (C.view old.next))
    "stale scoped resync reset a newer producer sequence";
  let bad = { scope with account = { scope.account with user_id = "another-user" } } in
  check
    (Rrbvec.is_empty (decode bad resync))
    "foreign account manufactured a checked change notice";
  let other_life =
    { scope with
      account =
        { scope.account with
          lifecycle_generation = Int64.succ scope.account.lifecycle_generation
        }
    }
  in
  check
    (Rrbvec.is_empty (decode other_life resync))
    "unregistered lifecycle manufactured a checked change notice";
  check
    (I.changefeed_notices (S.Graph_push available) = Ok Rrbvec.empty)
    "unscoped broadcast borrowed the selected session's authority";
  let bump (scope : S.asset_scope) =
    { scope with
      account =
        { scope.account with
          lifecycle_generation = Int64.succ scope.account.lifecycle_generation
        }
    }
  in
  let baseline =
    { raw.baseline with
      version = 2L
    ; state =
        { sync =
            { raw.baseline.state.sync with
              account =
                Option.map
                  (fun (account : Sync.account_scope) ->
                     { account with
                       lifecycle_generation = Int64.succ account.lifecycle_generation
                     })
                  raw.baseline.state.sync.account
            ; residents =
                List.map
                  (fun (scope, state) -> bump scope, state)
                  raw.baseline.state.sync.residents
            }
        ; residents =
            List.map
              (fun (scope, state) -> bump scope, state)
              raw.baseline.state.residents
        }
    }
  in
  let next =
    match I.bootstrap (S.Coordination_registered { raw with baseline }) with
    | Ok (W.Ready value) -> value
    | _ -> failwith "new lifecycle baseline"
  in
  let current = (List.hd (W.residents next)).session in
  check
    ((not (W.equal_session session current)) && W.same_logical_graph session current)
    "physical lifecycle was conflated with durable logical graph identity";
  let changed = C.step seen.next (C.Projection_received next) in
  let late =
    C.step
      changed.next
      (C.Changefeed_notice (reset, Id.Worker.Push_sequence.of_int64 100L))
  in
  check
    (C.equal_view (C.view changed.next) (C.view late.next))
    "old lifecycle notice changed the reopened owner";
  check
    (Rrbvec.is_empty (decode scope resync))
    "old lifecycle decoded under the replacement resident";
  check
    (match
       I.request
         session
         ~request_id:(W.request_id graph)
         (W.Query
            ( W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
            , W.Graph_info ))
     with
     | Error W.Revoked_session -> true
     | _ -> false)
    "old lifecycle retained data admission"
;;

let test_change_application_properties () =
  let issuer, raw, projection, session = fixture 734L in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Query (budget, W.Changes { generation = "g"; after = None }) in
  let ticket, tr =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let request_id =
    match
      I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok
    with
    | S.Coordination_query value -> value.request_id
    | _ -> assert false
  in
  let batch =
    match
      I.reply
        session
        ~request_id:(C.ticket_id ticket)
        operation
        ((changes_answer session (request_id) budget ~generation:("g") ~after:(None) ~through:("w") ~windows:([ { id = "w"
                          ; predecessor = "p0"
                          ; successor = "p1"
                          ; block_uuids = [ graph ]
                          ; page_uuids = []
                          ; structure_interests = []
                          }
                        ]) ~next:(None)))
    with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "application property batch fixture"
  in
  let admitted = (C.step tr.next (C.Admitted (ticket, Id.Worker.Request_id.one))).next in
  let start = (C.step admitted (C.Completed (ticket, W.Answered (Ok batch)))).next in
  let closed =
    match
      I.bootstrap
        (S.Coordination_registered
           { raw with
             baseline =
               { version = 2L
               ; presentation = 2L
               ; state =
                   { sync =
                       { raw.baseline.state.sync with
                         desired_residents = []
                       ; residents = []
                       ; selected = None
                       }
                   ; residents = []
                   }
               }
           })
    with
    | Ok (W.Ready value) -> value
    | _ -> failwith "application property close fixture"
  in
  let node n = uuid (Printf.sprintf "98000000-0000-4000-8000-%012d" (7340 + n)) in
  let run trace =
    let state = ref start
    and live = ref true
    and current = ref None
    and serial = ref 0
    and tokens = ref [] in
    let nodes : (bool * bool * bool) option array = Array.make 9 None
    and seen = Array.make 9 false in
    let failed () =
      Array.exists
        (function
          | Some (_, _, true) -> true
          | _ -> false)
        nodes
    in
    let ready () = !current <> None && Array.for_all Option.is_none nodes in
    let verify () =
      check
        (C.change_application_started (C.view !state) batch = (!current <> None))
        "application token was lost or revived";
      check
        (C.change_application_ready (C.view !state) batch = ready ())
        "consumer phase barrier disagrees with independent model";
      check
        (Option.is_some (C.change_application_error (C.view !state) batch) = failed ())
        "consumer failure was lost or invented"
    in
    let apply tr =
      check
        (List.length tr.C.instructions < 1000)
        "unbounded change application instruction batch";
      List.iter
        (function
          | C.Send (_, _, W.Acknowledge_changes _) ->
            check
              (!live && ready ())
              "ACK sent before every consumer expanded and applied/retired"
          | _ -> ())
        tr.instructions;
      state := tr.next;
      verify ()
    in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next) && a.instructions = b.instructions)
        "change application step is nondeterministic";
      check
        (C.equal_view before (C.view !state))
        "change application mutated a prior immutable view";
      apply a
    in
    let selected n f =
      match List.nth_opt !tokens (n mod max 1 (List.length !tokens)) with
      | Some (token, index) -> f token (!current = Some index)
      | _ -> ()
    in
    List.iter
      (fun (op, n) ->
         let parent = n mod 9 in
         match op with
         | 0 ->
           let allowed = !live && (!current = None || failed ()) in
           let planned = C.begin_change_application !state batch ~root:(node parent) in
           check
             (Result.is_ok planned = allowed)
             "duplicate/failed application admission disagrees with model";
           (match planned with
            | Ok (token, tr) ->
              let again =
                C.begin_change_application !state batch ~root:(node parent)
                |> Result.get_ok
              in
              check
                (token = fst again
                 && tr.instructions = (snd again).instructions
                 && C.equal_view (C.view tr.next) (C.view (snd again).next))
                "application planning is nondeterministic";
              incr serial;
              current := Some !serial;
              tokens := (token, !serial) :: !tokens;
              Array.fill nodes 0 9 None;
              Array.fill seen 0 9 false;
              nodes.(parent) <- Some (false, false, false);
              seen.(parent) <- true;
              apply tr
            | _ -> ())
         | 1 | 8 ->
           selected n (fun token valid ->
             let children =
               if op = 8 then [] else [ (parent + 1) mod 9; (parent + 2) mod 9 ]
             in
             if valid
             then (
               match nodes.(parent) with
               | Some (false, applied, error) ->
                 List.iter
                   (fun child ->
                      if not seen.(child)
                      then (
                        seen.(child) <- true;
                        nodes.(child) <- Some (false, false, false)))
                   children;
                 nodes.(parent)
                 <- (if applied && not error then None else Some (true, applied, error))
               | _ -> ());
             step
               (C.Change_consumer_expanded
                  (token, node parent, Rrbvec.of_list (List.map node children))))
         | 2 | 3 ->
           selected n (fun token valid ->
             if valid
             then (
               match nodes.(parent) with
               | Some (expanded, applied, error) ->
                 nodes.(parent)
                 <- (if op = 3
                     then Some (expanded, applied, true)
                     else if error
                     then Some (expanded, applied, error)
                     else if expanded
                     then None
                     else Some (false, true, false))
               | _ -> ());
             step
               (C.Change_consumer_applied
                  ( token
                  , node parent
                  , if op = 3 then Error W.Response_budget_exceeded else Ok () )))
         | 4 ->
           selected n (fun token valid ->
             if valid then nodes.(parent) <- None;
             step (C.Change_consumer_retired (token, node parent)))
         | 5 ->
           selected n (fun token valid ->
             if valid then Array.fill nodes 0 9 None;
             step (C.Change_application_retired token))
         | 6 ->
           let planned = C.request !state session (W.Acknowledge_changes batch) in
           check (Result.is_ok planned = !live) "ACK planning borrowed a closed owner";
           (match planned with
            | Ok (_, tr) -> apply tr
            | _ -> ())
         | 7 -> step C.Capacity_available
         | _ ->
           live := false;
           current := None;
           Array.fill nodes 0 9 None;
           step (C.Projection_received closed))
      trace
  in
  let prefixes =
    [ [ 0, 0; 6, 0; 2, 0; 8, 0 ]
    ; [ 0, 0; 1, 0; 3, 1; 0, 2; 2, 1; 8, 2; 2, 2 ]
    ; [ 0, 0; 1, 0; 4, 1; 4, 2; 2, 0; 6, 0 ]
    ; [ 0, 0; 1, 0; 9, 0; 2, 0; 5, 0; 6, 0 ]
    ]
  in
  for seed = 0 to 249 do
    let random = Random.State.make [| 0xa9911; seed |] in
    let trace =
      List.nth prefixes (seed mod List.length prefixes)
      @ List.init 96 (fun _ ->
        let op = Random.State.int random 10 in
        (if op = 9 && seed mod 5 <> 0 then 8 else op), Random.State.int random 27)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      try run reduced with
      | error ->
        failwith
          (Printf.sprintf
             "application property seed=%d minimal=[%s] %s"
             seed
             (String.concat
                ";"
                (List.map (fun (op, n) -> Printf.sprintf "%d:%d" op n) reduced))
             (Printexc.to_string error)))
  done
;;

let test_atomic_append_intent_and_admission () =
  let issuer,_,projection,session=fixture 6050L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let intent=match W.append_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000006051")
    ~block_id:(uuid "98000000-0000-4000-8000-000000006052")
    ~day:(W.journal_day 20261102 |> Result.get_ok) ~title:"Atomic typed source"
    ~task_status:(Some(uuid "98000000-0000-4000-8000-000000006053"))
    ~children:(Rrbvec.singleton Worker_pure_data.{block_id=uuid "98000000-0000-4000-8000-000000006054";
      title="Nested status";task_status=Some(uuid "98000000-0000-4000-8000-000000006055");children=Rrbvec.empty}) with
    | Ok intent->intent|Error _->failwith "atomic Append constructor is unavailable after the real backend contract" in
  let bytes=W.encode_durable_intent(W.Append_intent intent) in
  check(W.encode_durable_intent(W.restore_durable_intent session bytes |> Result.get_ok)=bytes)
    "restored Append changed its complete payload";
  let _,_,_,reopened=fixture 6051L in
  check(W.encode_durable_intent(W.restore_durable_intent reopened bytes |> Result.get_ok)=bytes)
    "fresh execution lost stable logical Append identity";
  let _,_,_,foreign=fixture ~graph:(uuid "98000000-0000-4000-8000-000000006056") 6052L in
  check(Result.is_error(W.restore_durable_intent foreign bytes)) "foreign graph restored an Append";
  let initial=ready I.binding projection in
  let ticket,planned=C.request initial session(W.Append intent) |> Result.get_ok in
  check(C.validate_session initial session=Ok()) "Append mutated the previous pure state";
  check(List.exists(function C.Send(sent,owner,operation)->
    W.equal_request_id(C.ticket_id sent)(C.ticket_id ticket) && W.equal_session owner session
    && (match I.request owner ~request_id:(C.ticket_id sent)operation with
      |Ok(S.Coordination_mutation{intent=encoded;_})->W.encode_durable_intent encoded=bytes
      |_->false)|_->false)planned.instructions)
    "Append bypassed the existing durable Service channel"
;;

let test_host_handoff_properties () =
  let issuer,raw,projection,session=fixture 9879L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let scope,physical=List.hd raw.baseline.state.residents in
  let projections=Array.init 16(fun n->
    let scope={scope with graph_generation=scope.graph_generation+n+1} in
    let sync={raw.baseline.state.sync with selected=None;
      residents=List.map(fun(_,(state:Sync.state))->scope,{state with Sync.snapshot={state.snapshot with
        startup={state.snapshot.startup with graph_generation=scope.graph_generation}}})raw.baseline.state.sync.residents} in
    let raw={raw with baseline={raw.baseline with version=Int64.of_int(n+2);
      state={sync;residents=[scope,{physical with generation=scope.graph_generation}]}}} in
    match I.bootstrap(S.Coordination_registered raw) |> Result.get_ok with W.Ready value->value|_->assert false) in
  let run trace=
    let state=ref(ready I.binding projection) and preparations=ref [] and attempts=ref []
      and receipts=ref [] and accepted=ref [] and rejected=ref [] and applied=ref [] and retired=ref []
      and legacy_waiting=ref [] in
    let consume instructions=List.iter(function
      |C.Quiesce plan->
        check(not(List.exists(W.equal_handoff_id(W.handoff_plan_id plan))!legacy_waiting))
          "backend prepare ran before the original legacy ACK";
        check(not(List.exists(fun(id,_)->W.equal_handoff_id id(W.handoff_plan_id plan))!preparations))
          "duplicate legacy event dispatched another prepare";
        let receipt=pure_host_receipt_fixture issuer plan in
        preparations:=(W.handoff_plan_id plan,receipt)::!preparations;receipts:=receipt::!receipts
      |C.Consume_handoff(receipt,attempt)->
        let mailbox=Id.Worker.Request_id.of_int64(Int64.of_int(10000+List.length !attempts)) in
        attempts:=(W.handoff_receipt_id receipt,attempt,mailbox)::!attempts
      |_->())instructions in
    let event value=let transition=C.step !state value in state:=transition.next;consume transition.instructions in
    let pick values n=if values=[]then None else Some(List.nth values(n mod List.length values)) in
    let equal_attempt a b=W.compare_request_id a b=0 in
    List.iteri(fun index action->
      let before= !state and before_view=C.view !state in
      let old_facts=List.map(fun(id,_)->id,C.handoff before_view id)!preparations in
      (match action mod 15 with
       |0|1->(match C.prepare_host_change ~legacy_pending:(action mod 15=1) !state(W.Graph_will_close(W.graph_id session))with
         |Error _->()|Ok(id,transition)->
           if action mod 15=1 then legacy_waiting:=id::!legacy_waiting;
           (match C.projection before_view with None->()|Some projection->
             retired:=List.map(fun resident->resident.W.session)(W.residents projection) @ !retired);
           state:=transition.next;consume transition.instructions)
       |2->(match pick !preparations(action/15)with Some(id,receipt)->event(C.Handoff_completed(id,W.Safe_to_proceed receipt))|_->())
       |3->(match pick !receipts(action/15)with Some receipt->
         (match C.authorize_host_change !state receipt with Error _->()|Ok transition->state:=transition.next;consume transition.instructions)|_->())
       |4->(match pick !attempts(action/15)with Some(id,attempt,_)->
         if not(List.exists(fun(_,actual,_)->equal_attempt actual attempt)!accepted)then rejected:=attempt::!rejected;
         event(C.Handoff_apply_not_admitted(id,attempt,W.Full))|_->())
       |5->event C.Capacity_available
       |6->(match pick !attempts(action/15)with Some(id,attempt,mailbox)->
         if not(List.exists(equal_attempt attempt)!rejected)then accepted:=(id,attempt,mailbox)::!accepted;
         event(C.Handoff_apply_admitted(id,attempt,mailbox))|_->())
       |7->(match pick !attempts(action/15)with Some(id,attempt,mailbox)->event(C.Handoff_applied(id,attempt,mailbox,Ok()))|_->())
       |8->event(C.Projection_received projections.((action/15)mod Array.length projections))
       |9 when index>=List.length trace-8->event C.Shutdown_requested
       |10->(match pick !attempts(action/15)with Some(id,attempt,_)->
         event(C.Handoff_applied(id,attempt,Id.Worker.Request_id.of_int64 999999L,Ok()))|_->())
       |11->(match pick !receipts(action/15)with Some receipt when List.exists(W.equal_handoff_id(W.handoff_receipt_id receipt))!applied->
         check(Result.is_error(C.authorize_host_change !state receipt))"applied permission planned another action"|_->())
       |12 when index>=List.length trace-4->event(C.Binding_invalidated I.binding)
       |13->(match pick !legacy_waiting(action/15)with None->()|Some id->
         legacy_waiting:=List.filter(fun actual->not(W.equal_handoff_id actual id))!legacy_waiting;
         event(C.Legacy_handoff_completed(id,Ok())))
       |14->event(C.Legacy_handoff_completed(W.handoff_id(uuid "98000000-0000-4000-8000-000000009999"),Ok()))
       |_->event C.Capacity_available);
      List.iter(fun(id,value)->check(C.handoff(C.view before)id=value)"handoff step mutated its prior immutable state")old_facts;
      List.iter(fun(id,_)->match C.handoff(C.view !state)id with
        |Some(W.Host_change_applied _)->
          check(List.exists(fun(actual,_,_)->W.equal_handoff_id actual id)!accepted)
            "terminal host success has no admitted mailbox owner";
          if not(List.exists(W.equal_handoff_id id)!applied)then applied:=id::!applied
        |Some(W.Safe_to_proceed receipt)->
          check(not(List.exists(W.equal_handoff_id id)!applied))"old Safe revived a terminal permission";
          check(W.equal_handoff_id(W.handoff_receipt_id receipt)id)"foreign receipt completed another round"
        |_->())!preparations;
      List.iter(fun session->check(Result.is_error(C.validate_session !state session))
        "retired original execution became eligible again")!retired)trace in
  let prefixes=[[1;13;2;3;6;7];[1;8;13;2;3;6;7];[0;2;3;4;5;6;7];[0;2;3;7;6];[0;2;3;4;5;6;4;5;7];[0;8;2;3;6;7];[0;2;3;6;10;7]] in
  let fails trace=try run trace;false with _->true in
  List.iter run prefixes;
  for seed=0 to 99 do
    let random=Random.State.make[|0x484F5354;seed|] in
    let trace=List.nth prefixes(seed mod List.length prefixes) @ List.init 80(fun _->Random.State.int random 1500) in
    if fails trace then failwith(Printf.sprintf "host handoff seed=%d shrunk=[%s]" seed
      (String.concat ";"(List.map string_of_int(shrink fails trace))))
  done
;;

(* The public pure boundary owns admission, actual completion and UI return.
   Backend Service tests separately prove the resource/finalization acknowledgements. *)
let test_returned_observations_reuse_capacity () =
  let issuer,raw,projection,session=fixture 731L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
  let operation=W.Observe(budget,W.Graph_info) in
  let state=ref(ready I.binding projection) in
  let step event=let transition=C.step !state event in state:=transition.next;transition.instructions in
  for n=1 to 8200 do
    let ticket,planned=match C.request !state session operation with Ok x->x
      |Error _->failwith(Printf.sprintf "returned Detail capacity exhausted after %d views" n) in
    state:=planned.next;
    ignore(step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int n))));
    let response=pure_observation_response issuer raw session ticket operation 0L "projection:v1:0" in
    let value=match I.reply session ~request_id:(C.ticket_id ticket) operation response |> Result.get_ok with
      |W.Answered(Ok value)->value|_->assert false in
    ignore(step(C.Completed(ticket,W.Answered(Ok value))));ignore(step(C.Forget ticket));
    let commands=step(if n mod 2=0 then C.Observation_returned value.observation else C.Release value.observation) in
    check(List.exists(function C.Release_observation_registration _->true|_->false)commands)
      "returning a shown observation did not plan its actual cleanup";
    let commands=step(C.Observation_release_completed(session,W.observation_id value.observation,Ok())) in
    let commands=if n mod 2=0 then commands else step(C.Observation_returned value.observation) in
    check(List.exists(function C.Finalize_observation_registration _->true|_->false)commands)
      "released and returned observation did not finalize its registry identity";
    if n=1 then (
      ignore(step(C.Observation_finalize_not_admitted(session,W.observation_id value.observation,W.Full)));
      check(not(List.exists(function C.Finalize_observation_registration _->true|_->false)(step C.Drain)))
        "finalization busy-retried Full without capacity";
      let retry=step C.Capacity_available in
      check(List.exists(function C.Finalize_observation_registration _->true|_->false)retry
        && not(List.exists(function C.Release_observation_registration _->true|_->false)retry))
        "finalization Full regressed to a fresh physical release");
    ignore(step(C.Observation_finalize_completed(session,W.observation_id value.observation,Ok())));
    check(C.observed(C.view !state)value.observation=None) "returned observation regained presentation"
  done
;;

let test_resource_return_finalization_properties () =
  let run scenarios =
    let issuer,raw,projection,session=fixture 733L in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
    let operation=W.Observe(budget,W.Graph_info) in
    let state=ref(ready I.binding projection) in
    let step event=let tr=C.step !state event in state:=tr.next;tr.instructions in
    let releases xs=List.filter(function C.Release_observation_registration _->true|_->false)xs in
    let finalizers xs=List.filter(function C.Finalize_observation_registration _->true|_->false)xs in
    List.iteri(fun n scenario->
      let ticket,planned=C.request !state session operation |> Result.get_ok in state:=planned.next;
      let response=pure_observation_response issuer raw session ticket operation 0L "current" in
      let value=match I.reply session ~request_id:(C.ticket_id ticket) operation response |> Result.get_ok with
        |W.Answered(Ok value)->value|_->assert false in
      let cancelled=scenario land 1<>0 in
      let returned_first=scenario land 2<>0 in
      let initial_reply=W.Answered(Ok value) in
      if cancelled then (
        ignore(step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(n+1)))));
        check(releases(step(C.Cancel ticket))=[]) "cancel cleaned before creator exit";
        check(List.length(releases(step(C.Completed(ticket,initial_reply))))=1) "canceled creator lost cleanup")
      else (
        if scenario land 4<>0 then (
          ignore(step(C.Completed(ticket,initial_reply)));
          ignore(step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(n+1))))))
        else (
          ignore(step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(n+1)))));
          ignore(step(C.Completed(ticket,initial_reply))));
        let commands=step(if returned_first then C.Observation_returned value.observation else C.Release value.observation) in
        check(List.length(releases commands)=1) "shown capability lost cleanup");
      ignore(step(C.Forget ticket));
      let id=C.ticket_id ticket in
      if scenario land 8<>0 then (
        ignore(step(C.Observation_release_not_admitted(session,id,W.Full)));
        check(releases(step C.Drain)=[]) "Full release self-retried";
        check(List.length(releases(step C.Capacity_available))=1) "release capacity retry lost");
      if scenario land 16<>0 then (
        ignore(step(C.Observation_release_completed(session,id,Error(W.Service_failed "actual I/O failed"))));
        check(releases(step C.Capacity_available)=[]) "failed release auto-retried";
        let retry=step(if cancelled then C.Cancel ticket else C.Release value.observation) in
        check(List.length(releases retry)=1) "explicit release retry lost");
      let released=step(C.Observation_release_completed(session,id,Ok())) in
      let finalize=if cancelled || returned_first then released else (
        check(finalizers released=[]) "unreturned UI capability was forgotten";
        step(C.Observation_returned value.observation)) in
      check(List.length(finalizers finalize)=1) "actual returned cleanup did not finalize";
      if scenario land 32<>0 then (
        ignore(step(C.Observation_finalize_not_admitted(session,id,W.Full)));
        check(finalizers(step C.Drain)=[]) "Full finalizer self-retried";
        let retry=step C.Capacity_available in
        check(List.length(finalizers retry)=1 && releases retry=[]) "finalizer reallocated physical tombstone");
      if scenario land 64<>0 then (
        ignore(step(C.Observation_finalize_completed(session,id,Error(W.Service_failed "finalization outcome unknown"))));
        check(finalizers(step C.Capacity_available)=[]) "unknown finalizer auto-retried";
        let retry=step(if cancelled then C.Cancel ticket else C.Observation_returned value.observation) in
        check(List.length(finalizers retry)=1 && releases retry=[]) "finalizer retry regressed to physical release");
      ignore(step(C.Observation_finalize_completed(session,id,Ok())));
      check(C.observed(C.view !state)value.observation=None) "returned interest revived")scenarios
  in
  let fails trace=try run trace;false with _->true in
  let rec shrink trace=
    let rec remove prefix=function
      |[]->trace
      |_::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      |x::rest->remove(x::prefix)rest in remove [] trace in
  for seed=0 to 99 do
    let random=Random.State.make[|0xC1EA;seed|] in
    let trace=List.init 40(fun _->Random.State.int random 128) in
    if fails trace then failwith(Printf.sprintf "resource return seed=%d shrunk=[%s]" seed
      (String.concat ";"(List.map string_of_int(shrink trace))))
  done
;;

let test_returned_files_reuse_capacity () =
  let issuer,_,projection,session=fixture 732L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let state=ref(ready I.binding projection) in
  let step event=let t=C.step !state event in state:=t.next;t.instructions in
  let consumer=W.asset_consumer session ~name:"ordinary-visible-image" |> Result.get_ok in
  let asset=Logseq_db_types.Asset_descriptor.create ~uuid:graph ~source:(Managed None)
    ~current_checksum:None ~size:None ~dimensions:None |> Result.get_ok in
  let operation=W.Replace_asset_demand(consumer,W.Foreground,[asset]) in
  let ticket,planned=C.request !state session operation |> Result.get_ok in state:=planned.next;
  let wire=match I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok with
    |S.Coordination_asset_demand{consumer;_}->consumer|_->assert false in
  let demand=checked_demand issuer session ticket consumer [asset] in
  ignore(step(C.Admitted(ticket,Id.Worker.Request_id.one)));ignore(step(C.Completed(ticket,W.Answered(Ok demand))));ignore(step(C.Forget ticket));
  let notice=I.asset_notice session(S.Asset_availability{consumer=wire;asset=asset.uuid;descriptor=asset;availability=Ready "current-file"}) |> Result.get_ok in
  ignore(step(C.Asset_received(notice,Id.Worker.Push_sequence.one)));
  let file=W.ready_asset_file notice |> Option.get in
  let physical instructions=let find:C.instruction->unit C.ticket option=function
    |C.Send(ticket,_,W.Release_file _)->Some ticket|_->None in List.find_map find instructions |> Option.get in
  for n=1 to 8200 do
    let operation=W.Acquire_asset_file file in
    let ticket,planned=match C.request !state session operation with Ok x->x
      |Error _->failwith(Printf.sprintf "ordinary file capacity exhausted after %d views" n) in
    state:=planned.next;
    ignore(step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(n*3)))));
    let reply=I.reply session ~request_id:(C.ticket_id ticket) operation
      (S.Asset_file(Some(Printf.sprintf "lease-%d" n,"/tmp/isolated-current.png"))) |> Result.get_ok in
    let lease=match reply with W.Answered(Ok(Some x))->x|_->assert false in
    ignore(step(C.Completed(ticket,reply)));ignore(step(C.Forget ticket));
    let waiter,planned=C.request !state session(W.Release_file lease) |> Result.get_ok in state:=planned.next;
    let cleanup=physical planned.instructions in
    if n mod 2=0 then ignore(step(C.File_lease_returned lease));
    ignore(step(C.Admitted(cleanup,Id.Worker.Request_id.of_int64(Int64.of_int(n*3+1)))));
    ignore(step(C.Completed(cleanup,W.Answered(Ok()))));ignore(step(C.Forget waiter));
    if n mod 2<>0 then ignore(step(C.File_lease_returned lease))
  done
;;

(* Expected-owner reads survive a live authority handover, but their old
   execution attempts do not. All transitions here are public Core events. *)
let test_live_binding_replans_ordinary_reads () =
  let run mode =
    let old_issuer,raw,projection,session=fixture (Int64.add 9300L (Int64.of_int mode)) in
    let next_issuer,_,next_projection,next_session=fixture (Int64.add 9400L (Int64.of_int mode)) in
    let module Old=(val old_issuer:Worker_effect_authority.ISSUER) in
    let module Next=(val next_issuer:Worker_effect_authority.ISSUER) in
    let owner=Option.get raw.S.baseline.state.sync.selected in
    let ticket,planned=C.plan_query (ready Old.binding projection) ~owner
      ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info |> Result.get_ok in
    let first=Id.Worker.Request_id.of_int64 1L in
    let admitted=(C.step planned.next(C.Admitted(ticket,first))).next in
    let old_failure=W.Answered(Error(W.Service_failed "Coordination binding retired")) in
    let before=if mode=1 then (C.step admitted(C.Completed(ticket,old_failure))).next
      else if mode=2 then (C.step planned.next(C.Completed(ticket,old_failure))).next else admitted in
    let invalidated=C.step before(C.Binding_invalidated Old.binding) in
    check(C.reply(C.view invalidated.next)ticket=None)
      "ordinary live-owner read leaked a retired attempt instead of awaiting a verified replacement";
    check(C.validate_session invalidated.next session=Error W.Revoked_session)
      "holding a read revived its old execution";
    let released=C.step invalidated.next(C.Binding_release_completed(Old.binding,Ok())) in
    let settled=if mode=1 then released else (
      check(not(List.exists(function C.Bind_replacement->true|_->false)released.instructions))
        "binding replaced before old read actually settled";
      C.step released.next(if mode=2 then C.Admitted(ticket,first) else C.Completed(ticket,old_failure))) in
    check(List.exists(function C.Bind_replacement->true|_->false)settled.instructions)
      "settled read obligation blocked actual replacement";
    let bound=C.step settled.next(C.Worker_bound Next.binding) in
    check(C.reply(C.view bound.next)ticket=None) "read completed without a fresh baseline";
    let resumed=C.step bound.next(C.Bootstrap_received(Next.binding,W.Ready next_projection)) in
    check(match C.query_origin(C.view resumed.next)ticket with
      |Some(actual,budget)->W.equal_session actual next_session
        && W.validate_request actual(W.Query(budget,W.Graph_info))=Ok()
      |None->false) "ordinary read was not resampled from the replacement's exact session and budget";
    let read_event (make : W.graph_info C.ticket -> C.event) = resumed.instructions |> List.find_map(function
      |C.Send(actual,_,W.Query(_,W.Graph_info))->Some(make actual)
      |_->None) |> Option.get in
    let admitted_event=read_event(fun actual->C.Admitted(actual,Id.Worker.Request_id.of_int64 2L)) in
    let fresh=(C.step resumed.next admitted_event).next in
    let stale=(C.step fresh(C.Completed(ticket,old_failure))).next in
    check(C.reply(C.view stale)ticket=None) "late old completion poisoned a fresh admitted attempt";
    let stale=(C.step stale(C.Admission_failed(ticket,W.Revoked_session))).next in
    check(C.reply(C.view stale)ticket=None) "late old admission failure poisoned a fresh attempt";
    let value=Read.For_worker.graph_info ~graph_uuid:graph ~graph_name:"Replacement read"
      ~schema:{major=1;minor=0} ~admission_facts:[] ~journal_title_format:None ~limits:raw.limits
      ~generation:"fresh-generation" ~projection_revision:"fresh-revision" in
    let completed=read_event(fun actual->C.Completed(actual,W.Answered(Ok value))) in
    let final=(C.step stale completed).next in
    check(C.reply(C.view final)ticket=Some(W.Answered(Ok value)))
      "fresh authorized read did not complete the original business ticket";
    check(C.query_origin(C.view final)ticket<>None) "fresh result lost original send provenance";
    let failed=(C.step (C.step resumed.next admitted_event).next
      (read_event(fun actual->C.Completed(actual,W.Answered(Error(W.Service_failed "genuine read failure")))))).next in
    check(C.reply(C.view failed)ticket=Some(W.Answered(Error(W.Service_failed "genuine read failure"))))
      "handover recovery hid a genuine error from the replacement execution"
  in
  List.iter run [0;1;2]
;;

let test_live_binding_read_owner_and_cancellation_fences () =
  List.iter(fun mode->
    let old_issuer,raw,projection,_=fixture (Int64.add 9500L (Int64.of_int mode)) in
    let next_issuer,_,next_projection,_=fixture ~graph_generation:(if mode=0 then 8 else 7)
      (Int64.add 9600L (Int64.of_int mode)) in
    let module Old=(val old_issuer:Worker_effect_authority.ISSUER) in
    let module Next=(val next_issuer:Worker_effect_authority.ISSUER) in
    let owner=Option.get raw.S.baseline.state.sync.selected in
    let ticket,planned=C.plan_query(ready Old.binding projection) ~owner ~maximum_items:1
      ~maximum_bytes:65536 W.Graph_info |> Result.get_ok in
    let admitted=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
    let invalidated=C.step admitted(C.Binding_invalidated Old.binding) in
    let state=if mode=1 then (C.step invalidated.next(C.Cancel ticket)).next
      else if mode=2 then (C.step invalidated.next(C.Forget ticket)).next else invalidated.next in
    let settled=C.step (C.step state(C.Completed(ticket,W.Interrupted W.Cancelled))).next
      (C.Binding_release_completed(Old.binding,Ok())) in
    let bound=C.step settled.next(C.Worker_bound Next.binding) in
    let fresh=C.step bound.next(C.Bootstrap_received(Next.binding,W.Ready next_projection)) in
    check(not(List.exists(function C.Send(_,_,W.Query _)->true|_->false)fresh.instructions))
      "foreign graph incarnation or canceled/forgotten owner replayed a read";
    if mode=0 then check(C.reply(C.view fresh.next)ticket=Some(W.Answered(Error W.Revoked_session)))
      "replacement graph incarnation failed to terminate the old business request") [0;1;2];
  let issuer,_,projection,session=fixture 9700L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
  let ticket,planned=C.request(ready I.binding projection)session(W.Query(budget,W.Graph_info)) |> Result.get_ok in
  let admitted=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
  let invalidated=C.step admitted(C.Binding_invalidated I.binding) in
  let settled=C.step invalidated.next(C.Completed(ticket,W.Interrupted W.Cancelled)) in
  check(C.reply(C.view settled.next)ticket=Some(W.Answered(Error W.Revoked_session)))
    "an explicitly sealed read was silently rebound to another execution"
;;

let test_binding_rebind_queued_read_and_failure () =
  let old_issuer,raw,projection,_=fixture 9800L in
  let next_issuer,_,next_projection,_=fixture 9801L in
  let module Old=(val old_issuer:Worker_effect_authority.ISSUER) in
  let module Next=(val next_issuer:Worker_effect_authority.ISSUER) in
  let owner=Option.get raw.S.baseline.state.sync.selected in
  let ticket,planned=C.plan_query_when_available(ready Old.binding projection) ~owner
    ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info |> Result.get_ok in
  let queued=(C.step planned.next(C.Admission_refused(ticket,W.Full))).next in
  let invalidated=C.step queued(C.Binding_invalidated Old.binding) in
  check(C.reply(C.view invalidated.next)ticket=None) "queued dependency read was discarded at handover";
  let released=C.step invalidated.next(C.Binding_release_completed(Old.binding,Ok())) in
  check(List.exists(function C.Bind_replacement->true|_->false)released.instructions)
    "logical waiting prevented physical binding settlement";
  let bound=(C.step released.next(C.Worker_bound Next.binding)).next in
  let failed=(C.step bound(C.Bootstrap_received(Next.binding,W.Bootstrap_failed(W.Service_failed "fresh bootstrap failed")))).next in
  check(C.reply(C.view failed)ticket=Some(W.Answered(Error(W.Service_failed "fresh bootstrap failed"))))
    "replacement bootstrap failure left retained read silently waiting";
  let ready=C.step bound(C.Bootstrap_received(Next.binding,W.Ready next_projection)) in
  check(List.exists(function C.Send(_,_,W.Query _)->true|_->false)ready.instructions)
    "fresh baseline did not resume queued dependency read"
;;

let () =
  if Array.mem "--unconfirmed-demand-only" Sys.argv then (test_unconfirmed_asset_registration_cleanup();exit 0);
  if Array.mem "--live-read-rebind-only" Sys.argv then (test_live_binding_replans_ordinary_reads(); test_live_binding_read_owner_and_cancellation_fences();test_binding_rebind_queued_read_and_failure();exit 0);
  if Array.mem "--retry-release-error-only" Sys.argv then (test_retry_binding_release_error_is_observable();exit 0);
  if Array.mem "--import-rejection-only" Sys.argv then (test_rejected_imports_release_capacity_after_fresh_readback();exit 0);
  if Array.mem "--import-proof-return-only" Sys.argv then (test_completed_imports_release_active_recovery_capacity();exit 0);
  if Array.mem "--file-return-only" Sys.argv then (test_returned_files_reuse_capacity();exit 0);
  test_returned_observations_reuse_capacity ();
  test_returned_files_reuse_capacity ();
  test_resource_return_finalization_properties ();
  test_asset_demand_notice_has_one_registered_owner ();
  test_asset_cleanup_ack_and_shutdown_retry ();
  test_asset_cleanup_round_properties ();
  test_unconfirmed_asset_registration_cleanup ();
  test_import_source_recovery_owner_cursor_and_ack ();
  test_import_recovery_pure_original_proof_owner ();
  test_import_intent_preserves_complete_source ();
  test_import_preview_late_result_is_cleanup_owned ();
  test_import_cancelled_preview_properties ();
  test_completed_imports_release_active_recovery_capacity ();
  test_rejected_imports_release_capacity_after_fresh_readback ();
  test_new_host_source_proof_retires_only_identical_unknown ();
  test_import_proof_consumption_properties ();
  test_atomic_append_intent_and_admission ();
  test_recovery_cursor_and_capacity_bounds ();
  test_durable_recovery_and_ack_purity ();
  test_committed_ack_requires_current_confirmation ();
  test_durable_recovery_ack_properties ();
  test_dependency_read_waits_for_capacity ();
  test_live_binding_invalidation_is_pure ();
  test_binding_rebind_queued_read_and_failure ();
  test_live_binding_replans_ordinary_reads ();
  test_live_binding_read_owner_and_cancellation_fences ();
  test_changes_serial_and_ack_capacity ();
  test_changefeed_planning_owns_its_typed_ticket ();
  test_changefeed_ack_requires_owned_delivered_batch ();
  test_empty_change_batch_ack_retires_old_reads ();
  test_change_application_properties ();
  test_scoped_change_notices_and_lifecycle ();
  test_observation_planning_is_pure ();
  test_host_candidate_waits_for_own_observation_ack ();
  test_observation_retains_typed_value ();
  test_observation_cancel_requires_ack ();
  test_observation_read_failure_and_refresh ();
  test_observation_notice_plans_one_refresh ();
  test_observation_cleanup_failure_waits_for_explicit_retry ();
  test_observation_properties ();
  test_observation_full_batch_does_not_self_wake ();
  test_observation_focus_and_reopen_fences ();
  test_observation_retirement_capacity_resets_only_after_binding_ack ();
  test_host_prepare_waits_for_exact_legacy_owner ();
  test_host_handoff_properties ();
  test_host_consumption_keeps_old_execution_retired ();
  test_repeated_graph_close_reopen_does_not_exhaust_handoff_history ();
  test_determined_failed_handoff_retires_when_user_retries ();
  test_account_host_unknown_requires_original_consumption_readback ();
  test_host_plan_pins_original_authoritative_frame ();
  test_query_origin_boundary ();
  test_durable_readback_reservation ();
  test_durable_mutation_properties ();
  test_durable_mutation_properties ~append:true ();
  test_bootstrap_validation ();
  test_retry_binding_release_error_is_observable();
  test_cleanup_admission_edges ();
  test_pure_properties ();
  test_reads_wait_for_verified_baseline ();
  test_queued_query_properties ();
  test_opening_query_retires_on_removal ();
  print_endline
    "Pure coordinator: invariants, 500 lifecycle + 250 queued-read + 250 ordinary/250 Append durable traces, \
     100 host-handoff + 300 observation + 250 application + 200 live-binding + 200 recovery/ACK + 200 retired-intent + 200 queued-presentation traces and shrinking passed"
;;
