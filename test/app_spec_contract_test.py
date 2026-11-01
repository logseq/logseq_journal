"""Compile client examples against the sealed App spec, without linking an implementation."""

import argparse
from pathlib import Path
import subprocess
import tempfile


POSITIVE = {
    "scoped_query": """
let read session budget day =
  C.Request (session, W.Query (budget, W.Journal day))
""",
    "atomic_capture_and_durable_retry": """
let submit session intent = C.Request (session, W.Append intent)
let restore_and_retry session bytes =
  Result.map (fun intent -> submit session intent) (W.restore_append_intent session bytes)
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
let checked (module Issuer : W.ISSUER) session request_id intent wire =
  Issuer.receipt session ~request_id ~intent wire
""",
    "observe_empty_page_and_release": """
let observe session budget day = C.Request (session, W.Observe (budget, W.Journal day))
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
let execute runner instruction = Journal_app_spec.Effect_runner.submit runner instruction
""",
    "trusted_adapter_can_issue_from_wire": """
module Decode_worker (Issuer : W.ISSUER) = struct
  let projection previous wire = Issuer.projection ~previous wire
  let answer session request_id request wire = Issuer.reply session ~request_id request wire
  let update session observation wire = Issuer.observation session observation wire
  let confirm session receipt wire = Issuer.confirmation session receipt wire
end
""",
    "release_has_a_typed_acknowledgement": """
let acknowledged (ticket : unit C.ticket) = C.Completed (ticket, W.Answered (Ok ()))
""",
    "trusted_issuer_has_a_construction_boundary": """
let issue managed_origin user_id worker_incarnation =
  W.issuer ~managed_origin ~user_id ~worker_incarnation
""",
    "trusted_adapter_can_encode_outbound_requests": """
let send (module Issuer : W.ISSUER) session request_id request =
  Issuer.request session ~request_id request
let cancel (module Issuer : W.ISSUER) request_id = Issuer.cancellation request_id
""",
    "typed_query_and_observation_results_reach_the_view": """
let answer view (ticket : W.page option C.ticket) : W.page option W.reply option =
  C.reply view ticket
let observed view (handle : W.page option W.observation) : W.page option W.observed option =
  C.observed view handle
let drain state = C.step state C.Drain
""",
}

NEGATIVE = {
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
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ocamlc", required=True)
    parser.add_argument("--cmi", action="append", default=[])
    args = parser.parse_args()
    required = [Path(path).resolve() for path in args.cmi]
    if not required or any(not path.is_file() for path in required):
        raise AssertionError("The compiled App spec interfaces are required before client checking")
    includes = sorted({str(path.parent) for path in required})
    prelude = "module W = Journal_app_spec.Worker_api\nmodule C = Journal_app_spec.Core\n"
    with tempfile.TemporaryDirectory(prefix="journal-app-spec-") as temporary:
        directory = Path(temporary)
        for name, source in POSITIVE.items():
            compile_case(args.ocamlc, directory, includes, name, prelude + source, None)
        for name, (source, diagnostic) in NEGATIVE.items():
            compile_case(args.ocamlc, directory, includes, name, prelude + source, diagnostic)
    print("APP_SPEC_CONTRACTS_PASSED: %d positive, %d negative" % (len(POSITIVE), len(NEGATIVE)))


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
