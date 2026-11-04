"""Compile client examples against the sealed App/Worker coordination spec, without linking an implementation."""

import argparse
from pathlib import Path
import subprocess
import tempfile


POSITIVE = {
    "scoped_query": """
let read session budget day =
  request (session, W.Query (budget, W.Journal day))
""",
    "atomic_capture_and_durable_retry": """
let submit session intent = request (session, W.Append intent)
let restore_and_retry session bytes =
  Result.map (function W.Append_intent intent -> submit session intent | Mutation_intent intent -> request(session,W.Mutate intent)) (W.restore_durable_intent session bytes)
""",
    "typed_completion": """
let complete (ticket : W.page option C.ticket) (reply : W.page option W.reply) =
  C.Completed (ticket, reply)
""",
    "generations_remain_distinct": """
let owners session presentation =
  (W.account_generation session, W.graph_generation session,
   W.presentation_generation presentation)
""",
    "write_phases_and_interruption": """
let phase = function
  | W.Rejected _ -> 0
  | W.Outcome_unknown -> 1
  | W.Committed_pending_presentation _ -> 2
  | W.Confirmed _ -> 3
let reply = function
  | W.Not_admitted _ -> 0
  | W.Interrupted (W.Cancelled | W.Transport_lost | W.Worker_stopped) -> 1
  | W.Answered (Error _) -> 2
  | W.Answered (Ok progress) -> phase progress
""",
    "receipt_validation": """
let checked (module Issuer : Worker_effect_authority.ISSUER) session request_id intent response =
  Issuer.reply session ~request_id (W.Append intent) response
""",
    "observe_empty_page_and_release": """
let observe session budget day = request (session, W.Observe (budget, W.Journal day))
let receive (value : W.page option W.observed) = C.Observation_received value
let release (observation : W.page option W.observation) = C.Release observation
""",
    "projection_and_last_graph_removal": """
let projection state =
  (W.projection_version state, W.residents state, W.selected state, W.local_deletion state)
let equality left right = C.equal_view (C.view left) (C.view right)
""",
    "pure_owner_and_runner": """
let create client_id = C.initial ~client_id
let step state event = C.step state event
let execute runner instruction = Journal_worker_coordination.Worker_effect_runner.submit runner instruction
let connect client managed_origin user_id post publish =
  Journal_worker_coordination.Worker_effect_runner.create ~client ~managed_origin ~user_id ~post ~publish
let incoming runner event = Journal_worker_coordination.Worker_effect_runner.on_event runner event
""",
    "binding_consumes_concrete_worker_values": """
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Validate (Issuer : Worker_effect_authority.ISSUER) = struct
  let projection previous (push : Service.push) = Issuer.projection ~previous push
  let answer session request_id request (response : Service.response) =
    Issuer.reply session ~request_id request response
  let update session request_id observation (response : Service.response) =
    Issuer.observation session ~request_id observation response
  let confirm session request_id presentation receipt (response : Service.response) =
    Issuer.reply session ~request_id (W.Confirm(presentation, receipt)) response
end
""",
    "release_has_a_typed_acknowledgement": """
let acknowledged (ticket : unit C.ticket) = C.Completed (ticket, W.Answered (Ok ()))
""",
    "trusted_issuer_has_a_construction_boundary": """
let issue managed_origin user_id runtime_epoch worker_generation =
  Worker_effect_authority.issuer ~managed_origin ~user_id ~runtime_epoch ~worker_generation
""",
    "binding_encodes_scoped_service_requests": """
let send (module Issuer : Worker_effect_authority.ISSUER) session request_id request
    : (Logseq_db_worker_lui.Logseq_db_worker_lui_service.request, W.error) result =
  Issuer.request session ~request_id request
let cancel client mailbox_id =
  Logseq_db_worker_lui.Journal_worker.cancel client ~request_id:mailbox_id
""",
    "typed_query_and_observation_results_reach_the_view": """
let answer view (ticket : W.page option C.ticket) : W.page option W.reply option =
  C.reply view ticket
let observed view (handle : W.page option W.observation) : W.page option W.observed option =
  C.observed view handle
let drain state = C.step state C.Drain
""",
    "journal_to_children_to_rendering": """
let children_request session budget page =
  W.page_title page,
  request (session, W.Query (budget, W.Children {parent=W.page_uuid page; after=None}))
let journal view (ticket : W.page option C.ticket) session budget =
  match C.reply view ticket with
  | None -> `Pending
  | Some (W.Answered (Ok (Some page))) -> `Children (children_request session budget page)
  | Some (W.Answered (Ok None)) -> `Empty
  | Some (W.Not_admitted (W.Full | W.Not_ready | W.Stopping)) -> `Retry
  | Some (W.Not_admitted (W.Unsupported_request operation)) -> `Unsupported operation
  | Some (W.Interrupted (W.Cancelled | W.Transport_lost | W.Worker_stopped)) -> `Interrupted
  | Some (W.Answered (Error error)) -> `Error error
let rows (slice : W.block W.slice) =
  List.map (fun block -> W.block_uuid block, W.block_title block) slice.items
let children view (ticket : W.block W.slice C.ticket) =
  match C.reply view ticket with
  | Some (W.Answered (Ok slice)) -> `Rows (rows slice), slice.next
  | Some (W.Answered (Error error)) -> `Error error, None
  | Some (W.Not_admitted (W.Unsupported_request operation)) -> `Unsupported operation, None
  | Some (W.Not_admitted (W.Full | W.Not_ready | W.Stopping))
  | Some (W.Interrupted _) -> `Retry, None
  | None -> `Pending, None
""",
    "observation_consumes_empty_and_nonempty_results": """
let page view (handle : W.page option W.observation) session budget =
  match C.observed view handle with
  | None -> `Pending
  | Some {value=None;_} -> `Empty
  | Some {value=Some page;_} ->
    `Children (W.page_title page,
      request (session,W.Observe(budget,W.Children {parent=W.page_uuid page;after=None})))
let children view (handle : W.block W.slice W.observation) =
  match C.observed view handle with
  | None -> `Pending
  | Some {value=slice;_} ->
    `Rows (List.map (fun block -> W.block_uuid block,W.block_title block) slice.items)
let registration view (ticket : W.block W.slice W.observed C.ticket) =
  match C.reply view ticket with
  | Some (W.Answered (Ok observed)) -> `Observed (observed.observation, observed.value.items)
  | Some (W.Answered (Error (W.Unsupported_operation operation))) -> `Unsupported operation
  | Some (W.Answered (Error (W.Db_error error))) -> `Db_error (Logseq_db_worker.Error.code error)
  | Some (W.Answered (Error error)) -> `Error error
  | Some (W.Not_admitted (W.Unsupported_request operation)) -> `Unsupported operation
  | Some (W.Not_admitted (W.Full | W.Not_ready | W.Stopping))
  | Some (W.Interrupted _) -> `Retry
  | None -> `Pending
""",
}

NEGATIVE = {
    "observation_requires_registered_service_envelope": (
        """let wrong (module Issuer : Worker_effect_authority.ISSUER) session request_id observation
          (response:Worker_pure_read.answer) =
          Issuer.observation session ~request_id observation response""",
        ("Worker_pure_read.answer", "Service.response")),
    "account_generation_is_not_graph_generation": (
        "let wrong (x : W.account_generation) : W.graph_generation = x",
        ("W.account_generation", "W.graph_generation")),
    "presentation_generation_is_not_graph_generation": (
        "let wrong (x : W.presentation_generation) : W.graph_generation = x",
        ("W.presentation_generation", "W.graph_generation")),
    "session_cannot_be_forged": (
        "let wrong : W.session = ()", ("W.session",)),
    "request_cannot_complete_with_another_result_kind": (
        """let wrong (ticket : W.page option C.ticket) (reply : W.mutation_progress W.reply) =
  C.Completed (ticket, reply)""", ("W.page", "W.mutation_progress")),
    "receipt_is_not_presentation_confirmation": (
        "let wrong (receipt : W.receipt) : W.confirmation = receipt",
        ("W.receipt", "W.confirmation")),
    "cancellation_is_not_a_write_outcome": (
        "let wrong : W.mutation_progress = W.Cancelled", ("W.mutation_progress",)),
    "mutations_cannot_be_observed_as_queries": (
        "let wrong budget intent = W.Observe (budget, W.Append intent)", ("W.query",)),
    "session_is_not_an_observation_handle": (
        "let wrong (session : W.session) = C.Release session", ("W.session", ".observation")),
    "observations_keep_their_result_type": (
        """let wrong (value : W.page option W.observed) : W.block W.slice W.observed = value""",
        ("W.page", "W.block")),
    "committed_receipts_are_not_client_constructible": (
        "let wrong : W.receipt = ()", ("W.receipt",)),
    "mailbox_generations_are_not_runtime_epochs": (
        """let wrong (runtime_epoch : Journal_worker_ids.Runtime.epoch)
    (worker_generation : Journal_worker_ids.Worker.generation) =
  Worker_effect_authority.issuer ~managed_origin:"https://example.invalid" ~user_id:"fixture"
    ~runtime_epoch:worker_generation ~worker_generation:runtime_epoch""",
        ("Worker.generation", "Runtime.epoch")),
}



POSITIVE.update({
    "exclusive_routing_never_falls_through_on_error": """
module R = Journal_worker_coordination.Worker_effect_runner
let route runner event registered_owner broadcast drop =
  let result = R.on_event runner event in
  (match result.R.disposition with
   | R.Consumed -> ()
   | R.Unowned_response -> (match registered_owner event with Some handle -> handle event | None -> drop event)
   | R.Broadcast -> broadcast event
   | R.Dropped_envelope -> drop event);
  result.R.error
""",
    "durable_all_mutations_and_confirmation": """
let operations session id uuid preconditions title status =
  let commands = [
    W.Save_block {block=uuid;title;preconditions};
    W.Insert_blocks {parent=uuid;roots=[{W.Data.uuid;title;children=[]}];preconditions};
    W.Delete_blocks {root=uuid;preconditions};
    W.Create_journal {page=uuid;day=(Result.get_ok(W.journal_day 20261101));title;preconditions};
    W.Set_task_status {block=uuid;status;preconditions};
    W.Clear_task_status {block=uuid;preconditions};
    W.Set_asset_reference {block=uuid;previous=None;asset=uuid;preconditions}]
  in List.map (fun command ->
    Result.map (fun intent -> request(session,W.Mutate intent))
      (W.mutation_intent session ~mutation_id:id command)) commands
let recover session bytes = Result.map (function W.Append_intent intent -> request(session,W.Append intent) | Mutation_intent intent -> request(session,W.Mutate intent))
    (W.restore_durable_intent session bytes)
let confirm session presentation receipt = request(session,W.Confirm(presentation,receipt))
let receipt value = W.receipt_mutation_id value,W.receipt_revisions value
let capture session id uuid day =
  W.append_intent session ~mutation_id:id ~block_id:uuid ~day ~title:"root"
    ~task_status:None ~children:(Rrbvec.singleton {Worker_pure_data.block_id=uuid;title="child";task_status=None;children=Rrbvec.empty})
""",
    "asset_import_notices_leases_and_ack": """
let import session source = Result.map (fun intent -> request(session,W.Import intent))
    (W.asset_import_intent session source)
let retry session bytes = Result.map(fun intent -> request(session,W.Import intent))
    (W.restore_asset_import_intent session bytes)
let consumer session name = W.asset_consumer session ~name
let demand session consumer descriptors =
  request(session,W.Replace_asset_demand(consumer,W.Foreground,descriptors))
let acquire session notice = Option.map(fun file ->
  request(session,W.Acquire_asset_file file)) (W.ready_asset_file notice)
let imported session receipt =
  W.import_data receipt,
  request(session,W.Acquire_imported_file receipt),
  Option.map(fun lease -> request(session,W.Release_file lease)) (W.import_preview receipt)
let lease session lease = W.file_path lease,W.file_type lease,request(session,W.Release_file lease)
let retry_upload session notice = Option.map(fun operation ->
  request(session,W.Retry_upload operation)) (W.upload_operation notice)
let notice view consumer = C.asset_notices view consumer
let facts view session first second =
  let for_consumer consumer = List.filter(fun notice ->
    match W.asset_notice_consumer notice with
    | Some owner -> W.equal_asset_consumer owner consumer
    | None -> false) (C.asset_notices view consumer) in
  let session_facts = List.filter(fun notice -> W.asset_notice_consumer notice=None)
      (C.session_asset_notices view session) in
  for_consumer first,for_consumer second,
  List.map W.asset_notice_data session_facts
let release session consumer = request(session,W.Release_asset_demand consumer)
""",
    "host_ownership_handoff_and_nonblocking_shutdown": """
module R = Journal_worker_coordination.Worker_effect_runner
let retire state uuid = C.prepare_host_change state (W.Graph_will_remove(uuid,W.Force))
let host_can_proceed view id =
  match C.handoff view id with
  | Some(W.Safe_to_proceed receipt) -> Some(W.handoff_change receipt,W.handoff_pending receipt)
  | Some(W.Quiescing _ | W.Applying_host_change _ | W.Host_change_applied _ | W.Handoff_failed _) | None -> None
let authorize state receipt =
  W.handoff_receipt_id receipt,W.handoff_binding receipt,W.handoff_sessions receipt,
  C.authorize_host_change state receipt
let send_consume runner receipt attempt = R.authorize_host_change runner receipt ~attempt
let stop runner =
  match R.shutdown runner with
  | R.Draining -> `Pump_again
  | R.Stopped -> `Done
  | R.Shutdown_failed error -> `Error error
""",
    "changefeed_observation_and_snapshot_registration": """
let bootstrap (module Issuer : Worker_effect_authority.ISSUER) response = Issuer.bootstrap response
let sample (module Issuer : Worker_effect_authority.ISSUER) = Issuer.bootstrap_request ()
let observed (value : W.block_summary W.observed) =
  W.compare_observation_epoch value.epoch value.epoch,value.value.W.lookup
let changes (batch : W.change_batch) = batch.generation,batch.through,batch.windows,batch.next
let capability session = W.capabilities session
let can_observe session query = W.supports_observation session query
let release_baseline (module Issuer : Worker_effect_authority.ISSUER) response =
  Issuer.revoke (); Issuer.release_binding_request (),Issuer.binding_released response
let handoff (module Issuer : Worker_effect_authority.ISSUER) plan response =
  Issuer.handoff_request plan,Issuer.handoff_receipt plan response
""",
})

NEGATIVE.update({
    "tree_continuation_cannot_resume_journals": (
        """let wrong day (after : Worker_pure_data.tree_member W.continuation option) =
 W.Journals {from_day=day;through_day=day;revision=None;after}""", ("tree_member", "journal_item")),
    "import_cannot_complete_as_graph_mutation": (
        """let wrong (ticket : W.import_progress C.ticket) (reply : W.mutation_progress W.reply) =
 C.Completed(ticket,reply)""", ("W.import_progress", "W.mutation_progress")),
    "file_handle_is_not_a_lease": (
        "let wrong (file : W.asset_file) = W.Release_file file", ("W.asset_file", "W.file_lease")),
    "release_receipt_is_not_constructible": (
        "let wrong : W.handoff_receipt = ()", ("W.handoff_receipt",)),
    "bootstrap_ready_cannot_be_forged": (
        "let wrong = W.Ready ()", ("W.projection",)),
    "summary_is_not_a_child_slice": (
        "let wrong (value : W.block_summary) : W.block W.slice = value", ("W.block_summary", "W.slice")),
})


POSITIVE.update({
    "presentation_and_registration_identity_are_explicit": """
let confirm (module Issuer:Worker_effect_authority.ISSUER) session request_id presentation receipt response =
  Issuer.reply session ~request_id (W.Confirm(presentation, receipt)) response
let bound (module Issuer:Worker_effect_authority.ISSUER) state =
  C.Worker_bound Issuer.binding,C.Bootstrap_received(Issuer.binding,state)
let cleanup handle =
  W.observation_session handle,W.observation_id handle
let same (type a b) (left:a W.observation) (right:b W.observation) (value:b) : a option =
  match W.same_observation left right with Some W.Refl -> Some value | None -> None
""",
})
NEGATIVE.update({
    "confirmation_requires_a_presentation": (
      "let wrong (session:W.session) receipt = W.Confirm(session,receipt)",
      ("W.session", "W.presentation")),
    "binding_is_not_worker_incarnation": (
      "let wrong (worker:W.worker_incarnation) = C.Worker_bound worker",
      ("W.worker_incarnation", "Worker_pure_read.binding")),
    "observation_value_cannot_cross_without_equality": (
      "let wrong (type a b) (left:a W.observation) (right:b W.observation) (value:b) : a = value",
      ("b", "a")),
})


NEGATIVE.update({
    "planned_ticket_keeps_its_result_type": (
      """let wrong state session budget day =
  match C.request state session (W.Query(budget,W.Journal day)) with
  | Error _ -> None
  | Ok(ticket,_) -> Some (ticket : W.block W.slice C.ticket)""",
      ("W.page", "W.block")),
    "handoff_id_is_not_request_id": (
      "let wrong view (id:W.request_id) = C.handoff view id",
      ("W.request_id", "Worker_effect_authority.handoff_id")),
})

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ocamlc", required=True)
    parser.add_argument("--cmi", action="append", default=[])
    args = parser.parse_args()
    required = [Path(path).resolve() for path in args.cmi]
    if not required or any(not path.is_file() for path in required):
        raise AssertionError("The compiled Worker coordination interfaces are required before client checking")
    includes = sorted({str(path.parent) for path in required})
    prelude = "module W = Journal_worker_coordination.Worker_api\nmodule C = Journal_worker_coordination.Worker_pure_coordinator\nlet request (session,operation) state = Result.map snd (C.request state session operation)\n"
    with tempfile.TemporaryDirectory(prefix="journal-worker-coordination-") as temporary:
        directory = Path(temporary)
        for name, source in POSITIVE.items():
            compile_case(args.ocamlc, directory, includes, name, prelude + source, None)
        for name, (source, diagnostic) in NEGATIVE.items():
            compile_case(args.ocamlc, directory, includes, name, prelude + source, diagnostic)
    print("WORKER_COORDINATION_CONTRACTS_PASSED: %d positive, %d negative" % (len(POSITIVE), len(NEGATIVE)))


def compile_case(compiler, directory, includes, name, source, diagnostic):
    path = directory / (name + ".ml")
    path.write_text(source)
    command = [compiler, "-c", "-w", "-a"]
    for include in includes:
        command.extend(["-I", include])
    result = subprocess.run(command + [str(path)], cwd=directory, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if diagnostic is None:
        if result.returncode != 0:
            raise AssertionError("Positive client %s did not compile:\n%s" % (name, output))
    elif result.returncode == 0:
        raise AssertionError("Invalid client %s compiled successfully" % name)
    elif "Unbound" in output or "Syntax error" in output or not all(
            fragment in output for fragment in diagnostic):
        raise AssertionError("Invalid client %s failed for an unrelated reason:\n%s" % (name, output))
    print("PASS " + name)


if __name__ == "__main__":
    main()
