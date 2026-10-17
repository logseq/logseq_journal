# Journal Native Producer

## Problem

Simulator host-restamp evidence currently requires the native Dune phase of a macOS App build, which then unconditionally runs unrelated macOS Swift, packaging and signing. At PR90 head 63fce61 the native phase succeeds but macOS Swift fails on JournalChrome listSectionSpacing. The external producer script can consume that phase but the failed App manifest is not successful validation.

## Proposal

The user explicitly authorized a minimal producer-only entry, accurate receipts, controlled timing and a PR. Add macOS `--producer-only` to the existing Apple builder: retain prepared-switch/cache locks and complete preflight, build native_embed, derive schema-2 producer inputs from the current Dune rule, remove host DNS/crypto only from an owned archive copy, link the fixed host object, validate it through the existing importer, bind runtime headers before target handoff, and recheck all live inputs before accepting `status: native-produced`. Return its native-input envelope. Do not run macOS Swift/package/sign or grant historical-input privileges from this receipt. Simulator uses the ordinary explicit experimental importer and retains target C/Swift/provider/signing checks.

The build tools own this boundary; pure application reducer events cannot run Dune, observe filesystem input mutation or represent build phase completion. Tests belong in the existing build-owner Python suite, with a tiny real compiler/Dune fixture and CLI rejection checks.

## Alternatives considered

### Keep full macOS App as prerequisite

Rejected: it couples producer success to unrelated platform Swift compatibility. A failed App is not a successful end-to-end timing baseline.

### Weaken import or reuse a failed receipt

Rejected: keep PR90 schema-2 identity, runtime/mldoc retention, XMLm unresolved-reference and complete target acceptance checks. Do not alter Dune/spec/pins or another owner workspace.

## Acceptance criteria

- Producer-only uses one prepared locked switch and external cache; no unrelated macOS App stages run and receipt cannot claim App/runtime/iOS ABI acceptance.
- Real Dune link argv, compiler, source/config/pins and original dependency/archive/unit bytes remain bound and rechecked; hot runs obtain a current rule rather than guessing from old trace or cache existence.
- A normal Simulator experimental build consumes the generated schema-2 envelope and passes the existing final checks. Full source build/tests and independent journal-code-review bind the final head.
- Controlled measurements preserve source/lock/compiler/SDK/config/path and cache state, distinguish cold/hot, phase/end-to-end and queue/approval waits, and report failed old workflow boundaries honestly.

## Risks

- Host ARM64 restamping remains experimental with cross_abi_validated=false; this producer proves neither a macOS App nor full OCaml iOS ABI.
- New source or dependency bytes require fresh evidence. Producer receipts keep consumed files live until a successful target receipt validates them.
- PR90 is unmerged; the independent branch now stacks on its pushed, reviewed and CI-green fec63d8 commit. Do not merge the parent PR.

## Questions

None. Scope, protected-file exclusions and measurement constraints were explicitly authorized in the delegated user request; routine implementation choices remain within that scope. Formal timing still waits for the coordinated exclusive Mac window.
