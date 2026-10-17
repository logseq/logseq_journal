# Allow Unused Xmlm Native Input

## Problem

The native builder rejects a complete object whose locked XMLm archive is a correct link input but whose unused XMLm unit was removed by the OCaml linker. Journal's Markdown title path calls mldoc without using its OPML parser/exporter. The current unconditional XMLm symbol requirement confuses input identity with runtime reachability.

## Proposal

The user explicitly approved build-tool and provenance-contract corrections on 2026-10-17. Keep dependency versions, source pins, compiler, actual native link inputs and their byte identities strict. Allow XMLm to be absent only when no XMLm reference remains unresolved. Record observed runtime/mldoc/XMLm retention separately from input identity. Runtime and mldoc remain required.

Preserve schema 1 force-link producers and their immutable receipts unchanged. Add schema 2 for an ordinary original XMLm archive, binding its original cmx/object bytes and installed source identities as well as the complete object's actual compiler/link inputs. A new receipt records the observed unit-retention map accurately; it cannot reuse the old all-retained boolean for an object without XMLm. Recheck live object/headers/evidence as before, with receipt-bound historical archives remaining historical.

Change only the existing build owner, its narrow boundary tests and guidance. Do not change Dune, native_embed, dependency pins, protected interfaces, phones or graphs. Coordinate compilation and GUI with the Timeline owner before executing tests/builds.

## Decision

Add schema 2 for ordinary original archives and keep schema 1 unchanged. Bind expanded object-only argv, compiler, original archive companions, unit/object bytes and pinned Git source identities. Require runtime/mldoc retention and reject unresolved XMLm symbols, while permitting unused XMLm elimination. Record the actual three-unit boolean map in schema-2 imports and final links instead of the legacy all-retained claim.

## Alternatives considered

### Retain XMLm with an application anchor

Rejected: this adds unused production reachability to satisfy a check without a product runtime requirement. The previously drafted Dune/anchor patch remains unapplied.

### Delete only the macOS symbol check

Rejected: experimental import, final product checks and receipt validation would still enforce the old force-link contract, while manifest fields could misreport actual retention.

## Consequences

Unknown compiler/linker inputs, split or disguised -cclib options, response files, conflicting input hashes and output-as-input identities are refused. Relative argv uses its recorded working directory. Absolute historical input names are stable lexical identities, so removing an installation symlink after a valid receipt does not change the identity being checked. Current source, object, runtime headers and evidence remain live checks; only receipt-bound consumed inputs can become historical.

No production anchor, forced archive, Dune/spec edit or shared dependency repair is needed. Experimental Host restamping remains explicitly outside full iOS ABI validation.

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

## Verification

Real tiny compiler/linker fixtures first reproduced the new contract and seven independent review findings as RED cases. After the corrections all 46 build-owner tests pass with no skips, including legacy producer/receipt cases and the installed SQLite runtime boundary. A separate read-only journal-code-review session confirmed the seven findings closed and no further evidence-backed contract issues; this does not replace the later whole-PR review.

The formal native macOS phase for revision 6ab0ead succeeded with runtime=true, mldoc=true and xmlm=false. The macOS App subsequently failed on the pre-existing JournalChrome listSectionSpacing API being unavailable on macOS, so no macOS App success is claimed. Fresh source/link records use that completed native phase's actual Dune argv and current input hashes; the old failed overall manifest is not a successful receipt.

The formal Simulator build 1.5877.34 completed input revalidation, target C/Swift compilation, final symbol/provider checks and signing with accurate schema-2 unit observations. A135 read-only Lambda RTC Favorites/detail acceptance then passed. The artifact remains experimental-host-restamp with cross_abi_validated=false.
