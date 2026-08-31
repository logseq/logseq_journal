# Exhaustive Pure Reducer Step Test Matrix

## Problem

`Core.step` accepts an abstract reducer state and a large event variant, but the
current contract tests cover selected workflows rather than an explicit state/event
matrix. This makes it difficult to see which event constructors have been exercised
from each meaningful reducer checkpoint and allows a newly added constructor to be
omitted from broad reducer characterization tests.

Literal enumeration of every `t * event` value is impossible: `t` is abstract and
contains unbounded data, event payloads also contain unbounded data, and `timer_id`
has no public constructor or currently emitted `Schedule_timer` value. The useful
finite boundary is every publicly reachable representative reducer checkpoint
crossed with every publicly constructible event constructor, plus distinct payload
classes where current, stale, malformed, or duplicate values select different
branches.

## Proposal

Add a table-driven contract test to `logseq_sync/test/core_contract.ml`.

The test will:

- build representative reducer checkpoints exclusively through the public `Core`
  API and event traces;
- define an event catalog with an explicit, exhaustive pattern match over `event`,
  so adding a constructor produces a compiler warning/error until the catalog is
  updated;
- run every catalog event against every checkpoint and verify that `step` is pure,
  deterministic, and produces structurally valid ordered instructions;
- include focused current/stale/invalid payload cases for scoped events, token
  responses, runner completions, lifecycle generations, and worker callbacks;
- report matrix cells by checkpoint and event name so a failure identifies the exact
  combination.

Do not modify the virtual library specification, reducer implementation, or Dune
files. `Timer_elapsed` remains documented as unconstructible through the public API
until the reducer emits a timer request or exposes a public constructor.

## Decision

Accept the finite public-contract matrix. Treat the 17 named reachable checkpoints
and 60 current, stale, invalid, duplicate, or ordinary event payload cases as the
declared exhaustive model. Cross every checkpoint with every event case, require
immutable deterministic replay for all 1,020 cells, and retain exact workflow tests
for domain-specific output assertions.

Keep `Timer_elapsed` in the constructor catalog as the sole explicit public-API
coverage gap. Do not manufacture its abstract `timer_id` with an unsafe cast.

## Alternatives considered

### Expose internal reducer state to tests

Making `t`, pending effect IDs, or `timer_id` constructors public would permit more
direct fixtures, but it would weaken the abstraction boundary and turn
implementation details into supported API solely for testing.

### Enumerate only the seven public sync phases

This is smaller but misleading because states with the same `sync_phase` can differ
in pending tokens, scopes, bootstrap phases, submission ownership, lifecycle
generation, and outstanding runner completions.

### Keep only workflow-specific examples

The existing focused tests remain valuable for detailed outcomes, but they do not
provide a mechanically complete constructor catalog or a visible cross-product.

## Acceptance criteria

- Every publicly constructible `event` constructor is represented in the matrix
  catalog.
- Every named representative checkpoint is exercised with every catalog event.
- The compiler forces the event catalog to be reviewed when `event` gains a new
  constructor.
- Matrix failures include both checkpoint and event names.
- Existing focused contract tests continue to pass.
- `dune runtest logseq_sync/test` and repository decision checks pass.

## Risks

- A representative checkpoint matrix is exhaustive over its declared finite model,
  not over the unbounded private `t` value space.
- Broad purity/determinism assertions do not replace focused tests that assert exact
  domain outcomes.
- Building many checkpoints by public event traces may make the test slower and
  requires fixture updates when workflows intentionally change.
- `Timer_elapsed` cannot be instantiated through the current public contract and is
  therefore tracked as an explicit coverage gap rather than fabricated with unsafe
  casts.

## Consequences

- Adding an `event` constructor makes the exhaustive naming match incomplete and
  requires a catalog decision before the test suite compiles cleanly.
- Matrix failures identify their checkpoint and payload case directly.
- The matrix adds 1,020 fast pure reducer calls and does not add I/O or test-only
  production interfaces.
- Exact output behavior remains owned by the focused contract scenarios; the matrix
  owns broad totality, immutability, deterministic replay, and catalog coverage.

## Questions

None. The finite coverage boundary and public-API-only constraint follow from the
current specification and repository rules.
