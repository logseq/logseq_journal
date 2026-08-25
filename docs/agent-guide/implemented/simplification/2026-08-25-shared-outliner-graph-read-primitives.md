# Shared Outliner Graph Read Primitives

## Problem

The outliner mutation planners independently implement the same low-level
DataScript reads. `values` appears in eight production modules, `one` in seven,
`entities_by_uuid` and `uuid_of_entity` in seven, `has_true` in six, and
`children` in five:

- `logseq_db_worker/lib/outliner/delete_blocks.ml`;
- `logseq_db_worker/lib/outliner/indent_outdent.ml`;
- `logseq_db_worker/lib/outliner/insert_blocks.ml`;
- `logseq_db_worker/lib/outliner/move_blocks.ml`;
- `logseq_db_worker/lib/outliner/pages.ml`;
- `logseq_db_worker/lib/outliner/properties.ml`;
- `logseq_db_worker/lib/outliner/references.ml`; and
- `logseq_db_worker/lib/outliner/save_block.ml`.

Most copies are byte-for-byte or behaviorally identical: read an EAVT value
list, accept exactly one value, select one concrete value kind, resolve both
UUID and legacy string encodings, recover an entity UUID, or enumerate
non-self children. Because these copies are private implementation rather than
planner policy, a storage-shape correction must currently be repeated across
several modules. Small differences are easy to miss, especially the intentional
dual UUID representation and self-parent exclusion.

The planners themselves are production consumers. Their focused tests under
`logseq_db_worker/test/` are non-production consumers and behavioral evidence.
No dynamic registration, generated reference, Flutter bridge, wire value, or
supported external interface selects these helpers: they are local `let`
bindings hidden behind each planner's narrow `.mli`.

## Decision

Introduce one private outliner graph-read module, with a narrow `.mli`, that
owns only behavior-identical, policy-free primitives. The eight production
consumers use that module and no longer retain local copies of those primitives.

The user selected this narrow boundary on 2026-08-25: resolution, ordering,
selection invariants, and error policy remain in their owning planners rather
than becoming configurable shared helpers.

The shared contract should cover the common operations whose semantics can be
copied exactly:

- EAVT value enumeration without changing sequence order;
- strict optional single-value selection, where zero or multiple values both
  yield `None`;
- string, reference, and `true`-boolean selection;
- UUID lookup across both `Datascript.Uuid` and `Datascript.String`, retaining
  deduplication and integer sort order;
- entity UUID decoding from either supported storage representation;
- page detection through a single string-valued `block/name`; and
- child lookup that excludes a self-parent datom.

Keep every domain decision local: planner-specific error text, `require_*`
functions, property validation, ordered-sibling validation, selection
canonicalization, transaction construction, and mutation status. In
particular, `Properties.one` returns a typed error for multiple values and is
not the same contract as the optional selector; it must remain local.

The module remains internal to the qualified `Outliner` subtree and is not
re-exported from `Logseq_db_worker`. No Dune file, protocol type, wire encoding,
public worker facade, fixture, or generated artifact changes. The resulting
code has one source of truth for raw graph reads while preserving every
planner's observable response, transaction operations, metadata, changed UUIDs,
and error messages.

## Alternatives considered

### Keep local copies

This avoids a new module but retains at least 58 repeated helper definitions
and the obligation to update all copies when the accepted storage shape
changes. The helpers have many real production consumers and no independent
planner policy, so this duplication is not buying isolation.

### Share planner-level resolution helpers

Functions such as `require_entity`, `ordered_children`, and `page_for` look
similar but attach operation-specific errors or invariants. Sharing them would
either erase useful domain language or require callbacks that relocate the
same complexity. The proposed boundary stops below that policy layer.

### Reuse `Read_model`

`Read_model` implements the typed public query protocol, including response
limits, selectors, and error semantics. Making mutation planning depend on it
would add protocol concepts and allocations to simple internal graph reads
rather than remove complexity.

## Acceptance criteria

- The shared module is private to `logseq_db_worker` and exports only raw,
  policy-free DataScript read primitives used by at least two production
  planners.
- The listed planners no longer define duplicate copies of the migrated
  primitives.
- UUID lookup still accepts both UUID and string storage values, preserves
  deduplication and sort order, and entity UUID decoding accepts both values.
- Child lookup still omits self-parent entries, strict single-value selection
  still rejects ambiguous cardinality, and `Properties.one` retains its typed
  ambiguity error.
- For the existing planner fixtures, successful plans produce byte-equivalent
  `tx_ops` and `tx_meta`, identical mutation status and changed UUIDs, and
  failures preserve their exact error category and message.
- `dune exec logseq_db_worker/test/test_save_block.exe`,
  `test_insert_blocks.exe`, `test_move_blocks.exe`,
  `test_indent_outdent.exe`, `test_delete_blocks.exe`, `test_pages.exe`, and
  `test_properties.exe` pass from `logseq_db_worker/test/`.
- `dune runtest logseq_db_worker/test test` and `dune build @all` pass without
  modifying any Dune file, protected `spec/` source, generated source, or
  `bonsai_flutter` source.

## Consequences

Raw outliner graph reads now have one implementation under the private
`Outliner` subtree. UUID lookup and decoding, strict selection, page detection,
and child enumeration therefore share the same storage-shape behavior across
the mutation planners and reference derivation.

Planner-specific validation and error policy remain local. In particular,
`Properties.one` still reports ambiguous cardinality as a typed
`Invalid_selection` error rather than using the optional shared selector.

The focused graph-read characterization test covers UUID and legacy string
encodings, sorted deduplicated lookup, ambiguous cardinality, typed selectors,
page detection, and self-parent exclusion. Source-boundary checks prevent the
removed local helper definitions from returning. The implementation adds no
public facade, protocol, Dune, protected `spec/`, generated, or
`bonsai_flutter` change.

## Risks

- A superficially similar helper can encode different cardinality or error
  behavior. Migrating only the enumerated exact contracts and retaining
  `Properties.one` locally prevents that semantic collapse.
- Unqualified shared names could make planner code less explicit. A narrow
  module qualifier or a deliberately small local open should keep the data-read
  boundary visible.
- Current outliner tests heavily cover mutation results but do not directly
  assert every raw helper edge. Focused tests for dual UUID representation,
  ambiguous cardinality, and self-parent exclusion are required before deleting
  the copies.
