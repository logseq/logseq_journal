# Unified Outliner Planner Contract

## Problem

Seven production outliner planners independently declare nearly the same plan
record and overlapping copies of the same error vocabulary:

- `Save_block`, `Insert_blocks`, `Move_blocks`, `Indent_outdent`,
  `Delete_blocks`, `Pages`, and `Properties` all return transaction operations,
  transaction metadata, and changed UUIDs;
- every planner except `Save_block` also returns the same mutation status that
  `Mutation_plan` computes for `Save_block`; and
- the planners select subsets of `Unsupported_semantics`, `Invalid_selection`,
  `Invalid_tree`, `Invalid_order`, `Invalid_position`, `Conflict`, and
  `Built_in_protected`.

`logseq_db_worker/lib/mutation_plan.ml` then spends most of its 131 lines
reconstructing an identical record and translating nominally distinct error
constructors to an identical aggregate error. `Pages` repeats the same mapping
when it calls `Save_block`, and `Indent_outdent` repeats it when it calls
`Move_blocks`. This conversion layer has no independent policy: every field,
constructor, and message is forwarded unchanged.

These contracts are internal implementation. The public
`Logseq_db_worker.mli` facade exposes `Protocol` and `Engine`, but not
`Mutation_plan` or the qualified outliner planner modules. Repository tests are
non-production consumers and pattern-match the aggregate `Mutation_plan` error;
they provide preservation evidence rather than a supported external contract.
The repository explicitly does not preserve backward compatibility, so the
private nominal types do not justify the repeated conversion machinery.

## Decision

Create one private outliner planner contract containing:

- one plan record with `tx_ops`, `tx_meta`, `changed_uuids`, and `status`; and
- one error type with the existing seven constructors and unchanged string
  payloads.

The user selected full consolidation of both the plan record and the internal
error vocabulary on 2026-08-25; retaining narrowed per-planner error types is
not part of the proposed direction.

Make all seven planners return that shared result directly. `Save_block`
should set `No_change` or `Applied` at the point where it already knows whether
`tx_ops` is empty, matching the current `Mutation_plan` calculation. The other
planners should preserve their existing status values.

Reduce `Mutation_plan` to protocol-command dispatch: select the corresponding
planner and return its result without repacking fields or remapping errors.
Likewise, let `Pages` consume `Save_block` results and `Indent_outdent` consume
`Move_blocks` results without constructor-by-constructor translation. Keep
planner algorithms, exact error messages, transaction order, metadata,
changed-UUID order, mutation availability, and engine error mapping unchanged.

The shared contract remains private to the qualified `Outliner` subtree and is
not added to the `Logseq_db_worker` facade. This decision is independent of the
shared graph-read-primitives exploration: either may be proposed and
implemented without the other. No Dune file, protocol definition, generated
artifact, fixture format, or protected source changes.

## Alternatives considered

### Share only the plan record

This removes record repacking but retains all constructor-by-constructor error
translation in `Mutation_plan`, `Pages`, and `Indent_outdent`. Error forwarding
is the majority of the accidental dispatch complexity, and it has no distinct
behavior to preserve.

### Keep per-planner narrowed error types

The narrowed nominal types document which categories each planner currently
emits, but the aggregate dispatcher must still map every constructor and every
new error requires edits at multiple seams. Focused planner tests and error
construction sites provide the same practical documentation without parallel
types.

### Use polymorphic-variant subsets

Polymorphic variants could retain compile-time error subsets while reducing
some mappings. They would introduce row-type complexity throughout already
large planner implementations and would not simplify the plan-record
duplication. One closed internal error vocabulary is clearer here.

### Merge the planners into `Mutation_plan`

This would remove nominal boundaries by producing one very large module. The
planners own distinct mutation algorithms and focused tests, so merging them
would relocate code and weaken ownership without reducing domain concepts.

## Acceptance criteria

- All seven planners return the same private plan and error types; no planner
  retains a duplicate plan-record or aggregate error declaration.
- `Mutation_plan.plan` dispatches without reconstructing successful records or
  mapping same-named errors, and the equivalent mappings disappear from
  `Pages` and `Indent_outdent`.
- `Save_block` reports `No_change` exactly when its `tx_ops` is empty and
  `Applied` otherwise, matching current aggregate behavior.
- Every supported mutation produces the same ordered `tx_ops`, exact `tx_meta`,
  changed UUIDs, status, engine response, and failure category/message as the
  current implementation.
- No additional mutation becomes accepted and no planner-specific validation
  or error message moves into the shared contract.
- All focused outliner tests pass, followed by
  `dune runtest logseq_db_worker/test test` and `dune build @all`.
- The implementation does not modify a Dune file, protected `spec/` source,
  generated source, or `bonsai_flutter` source and does not export the shared
  contract from `Logseq_db_worker`.

## Consequences

All seven planners now expose the same private plan record and closed error
vocabulary. `Mutation_plan` performs only protocol-command dispatch, while
`Pages` and `Indent_outdent` forward nested planner errors directly without
constructor-by-constructor translation.

`Save_block` now owns its mutation status and reports `No_change` only when its
transaction operations are empty. Existing planners preserve their previous
status values, ordered operations, metadata, changed UUIDs, and exact error
payloads.

Adding a new internal error category now requires one contract change rather
than parallel nominal-type and mapping edits. The tradeoff is that individual
planner return types no longer encode which subset of the shared error
constructors they currently emit; focused behavioral tests remain the evidence
for those narrower behaviors. Source-boundary checks prevent duplicate plan and
error declarations or forwarding maps from returning.

## Risks

- A closed shared error type no longer makes each planner's impossible error
  categories visible in its return type. Focused `.mli` documentation and tests
  should state the categories each planner actually emits if that information
  remains useful.
- Moving `Save_block` status construction can accidentally change no-op
  reporting. A direct no-change assertion must pin the current behavior.
- OCaml constructor scope can make a type consolidation mechanically noisy.
  The implementation should prefer one qualified contract over local aliases
  that recreate the same nominal surface.
