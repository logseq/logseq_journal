# Allow Unused Xmlm Native Input

## Problem

The native builder rejects a complete object whose locked XMLm archive is a correct link input but whose unused XMLm unit was removed by the OCaml linker. Journal's Markdown title path calls mldoc without using its OPML parser/exporter. The current unconditional XMLm symbol requirement confuses input identity with runtime reachability.

## Proposal

The user explicitly approved build-tool and provenance-contract corrections on 2026-10-17. Keep dependency versions, source pins, compiler, actual native link inputs and their byte identities strict. Allow XMLm to be absent only when no XMLm reference remains unresolved. Record observed runtime/mldoc/XMLm retention separately from input identity. Runtime and mldoc remain required.

Preserve schema 1 force-link producers and their immutable receipts unchanged. Add schema 2 for an ordinary original XMLm archive, binding its original cmx/object bytes and installed source identities as well as the complete object's actual compiler/link inputs. A new receipt records the observed unit-retention map accurately; it cannot reuse the old all-retained boolean for an object without XMLm. Recheck live object/headers/evidence as before, with receipt-bound historical archives remaining historical.

Change only the existing build owner, its narrow boundary tests and guidance. Do not change Dune, native_embed, dependency pins, protected interfaces, phones or graphs. Coordinate compilation and GUI with the Timeline owner before executing tests/builds.

## Alternatives considered

### Retain XMLm with an application anchor

Rejected: this adds unused production reachability to satisfy a check without a product runtime requirement. The previously drafted Dune/anchor patch remains unapplied.

### Delete only the macOS symbol check

Rejected: experimental import, final product checks and receipt validation would still enforce the old force-link contract, while manifest fields could misreport actual retention.

## Acceptance criteria

- A real tiny ordinary-archive producer with runtime/mldoc and no XMLm symbols is accepted with accurate retention observations and strict input hashes.
- Wrong dependency pins, changed compiler/source/archive/cmx/object/link-input identity, unresolved XMLm references and missing required runtime/mldoc symbols are rejected.
- Legacy producer/receipt regressions remain valid, including evidence tampering, changed native source and runtime-header checks. A new receipt cannot falsify observed unit retention or reinterpret a legacy receipt.
- Run RED before production edits, then the build-owner suite. Independently review the provenance contract before accepting new product artifacts; perform fresh final source/build/tests and A135 read-only acceptance afterward.

## Risks

- A permissive receipt/schema transition could accept unsupported inputs; versioned records, exact actual-input membership and negative tests must keep the change confined to legal dead-code elimination.
- Host-restamped iOS remains experimental with cross_abi_validated=false.

## Questions

- None. The user approved this exact direction; no protected Dune/spec edit is needed.
