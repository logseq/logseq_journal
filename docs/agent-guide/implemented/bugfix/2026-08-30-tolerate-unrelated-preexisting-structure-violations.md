# Tolerate Unrelated Preexisting Structure Violations

## Problem

Managed structural mutations run `tree_structurally_valid` against the complete
optimistic database after planning. A graph may contain a preexisting structural
violation that is unrelated to the mutation target, so an otherwise valid
capture fails with `unsupportedSemantics` and the lower message `The mutation
would violate graph structure.`

The reported production mirror contains two blocks with the same `block/order`
under the 2026-08-29 journal page. The failing `Insert_blocks` targets the
2026-08-30 journal page. The insert planner validates the target sibling list
and generates a valid next order there, but the Engine postcondition sees the
unrelated 2026-08-29 duplicate and rejects the transaction.

The postcondition must still reject mutations that introduce a new duplicate,
cycle, malformed structural value, or inconsistent page target. Simply skipping
validation when the input graph is imperfect would allow a mutation to make the
graph worse.

## Proposal

Represent full-tree validation failures as stable, comparable violations rather
than one boolean. A structural mutation is admissible when every violation in
the projected database already existed in the database used for planning.

Use the same comparison for local execution, initial managed preparation, and
managed semantic replan. Preserve planner validation of the selected parent,
anchor, and sibling list. Do not repair, rewrite, or normalize unrelated remote
graph data as part of this bugfix.

Violation identity must include enough context to distinguish a newly damaged
relationship from an unchanged existing one. At minimum it must cover malformed
or multiple parent/page values, malformed name/order values, duplicate sibling
orders, invalid page self-parent targets, and parent cycles.

## Decision

Replace the whole-graph boolean postcondition with a differential structural
violation check. Structural mutation output is valid when its complete
violation set is a subset of the planning database's violation set. Continue to
run the mutation planner's target-local validation before this postcondition.

## Alternatives considered

### Skip validation when the input graph is invalid

Accept every projected database when the planning database already fails the
boolean validator. This fixes the reported capture but permits a mutation to add
new structural damage, so it is not selected.

### Validate only changed UUIDs

Restrict the postcondition to planner-reported `changed_uuids`. A move or delete
can damage relationships on neighboring or formerly related entities that are
not represented reliably by UUID-only membership. Differential violation
comparison preserves the global invariant without assuming each planner's
change summary is complete.

### Normalize duplicate orders before capture

Rewrite the unrelated journal's sibling order before applying the requested
capture. This mutates user graph data outside the requested operation and would
create extra sync behavior. Structural repair requires a separate product
decision.

## Acceptance criteria

- A valid insert under one page succeeds when another page already contains a
  duplicate sibling order.
- The successful insert does not change the preexisting violation.
- An insert still fails when its selected parent has duplicate sibling orders.
- A structural mutation that introduces a new duplicate sibling order or parent
  cycle fails the Engine postcondition.
- Local execution, managed preparation, and managed replan use the same
  differential rule.
- Existing valid-graph structural mutation behavior remains unchanged.
- Focused tests, the complete OCaml test suite, formatting, build, and all agent
  decision checks pass.

## Risks

- Stable violation comparison is more complex than a boolean full-tree check and
  must not collapse distinct relationships into one identity.
- The graph remains imperfect after a successful unrelated mutation. Repair is
  intentionally outside this decision.
- Full before/after validation scans add work to structural mutation planning;
  this change does not attempt an incremental validator.

## Implementation outcome

Implemented on 2026-08-30.

- Engine structural validation now records stable violations for malformed
  structural values, multiple parent/page targets, duplicate sibling orders,
  invalid named-page targets, and parent cycles.
- Local execution, managed preparation, and managed semantic replan compare the
  projected violation set with the planning database's existing set.
- Managed Engine tests seed two equal sibling orders under an unrelated page and
  prove that preparation and replanning succeed for a valid target page.
- A companion test proves that the insert planner still rejects the same
  duplicate orders when that page is the selected parent.
- The source-boundary test requires the shared differential validator at all
  three Engine call sites.

## Consequences

- A valid capture is no longer blocked by unchanged structural damage elsewhere
  in the graph.
- A mutation cannot add or alter a structural violation merely because the
  planning database already contains a different violation.
- This change does not normalize the existing duplicate order or emit any
  repair transaction.

## Verification

- RED: `test_engine.exe` failed both new unrelated-violation cases with the
  reported whole-graph structure messages.
- GREEN: `test_engine.exe` and `test_engine_open.exe` pass after the differential
  validator change.
- `dune runtest`, `dune build @all`, targeted `ocamlformat --check`,
  `spec-dev-tool check --all`, and `git diff --check` pass.
- Full `dune build @fmt` remains blocked by preexisting formatting differences
  in two protected `spec/**/dune` files and unrelated `app/journal_platform.ml`;
  none is modified by this bugfix.

## Questions

- None.
