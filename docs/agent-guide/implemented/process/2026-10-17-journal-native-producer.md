# Journal Native Producer

## Problem

Simulator host-restamp evidence currently requires the native Dune phase of a macOS App build, which then unconditionally runs unrelated macOS Swift, packaging and signing. At PR90 head 63fce61 the native phase succeeds but macOS Swift fails on JournalChrome listSectionSpacing. The external producer script can consume that phase but the failed App manifest is not successful validation.

## Proposal

The user explicitly authorized a minimal producer-only entry, accurate receipts, controlled timing and a PR. Add macOS `--producer-only` to the existing Apple builder: retain prepared-switch/cache locks and complete preflight, build native_embed, derive schema-2 producer inputs from the current Dune rule, remove host DNS/crypto only from an owned archive copy, link the fixed host object, validate it through the existing importer, bind runtime headers before target handoff, and recheck all live inputs before accepting `status: native-produced`. Return its native-input envelope. Do not run macOS Swift/package/sign or grant historical-input privileges from this receipt. Simulator uses the ordinary explicit experimental importer and retains target C/Swift/provider/signing checks.

The build tools own this boundary; pure application reducer events cannot run Dune, observe filesystem input mutation or represent build phase completion. Tests belong in the existing build-owner Python suite, with a tiny real compiler/Dune fixture and CLI rejection checks.

## Decision

Implement the user-authorized producer-only scope in the existing builder. Keep the full App default path and schema-1/2 import contracts, use native-produced only for producer acceptance, and require the ordinary experimental target build for an App. No protected spec/Dune/pin change is needed.

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

## Consequences

Simulator producers no longer depend on unrelated macOS Swift compatibility. Identity, live input/header checks and target acceptance remain mandatory; producer evidence alone cannot grant historical-input privileges or iOS ABI acceptance. Timing evidence is bounded to the measured failed auxiliary Swift stage and qualified route totals above the unchanged native/target checks.

## Validation

All 54 build-owner tests passed in 67.449s with no skips. The real Dune/OCaml fixture proves fresh production, hot reuse without relinking, immutable records, unknown-argument refusal, ancestor reuse, and header mutation rejection before target handoff. Header rejection and documentation-only reuse were observed RED before correction. Independent read-only journal-code-review at 801cddf closed both findings and found no further actionable issue; final whole-source build/regression remains the exact-head PR CI gate.

One bounded cold/hot pair ran on source/native 801cddf, using one prepared switch/root, compiler, locks, SDKs, Release/jobs=2 and the same absolute native cache path. New owned caches were renamed/restored in place; no shared dependency cache was cleaned. Real Dune traces show 268 OCaml compilation calls, 11 archive calls, one complete-object link and three C compilations in each cold sample; both hot samples show zero compilation/archive/link actions. Producer relinking runs once cold and zero times hot. All four final Simulator builds passed current source/input, target C provider, 54 Swift object platform, runtime/mldoc and signature checks; XMLm was accurately absent. They retain cross_abi_validated=false and runtime_acceptance=false.

The removed macOS Swift subprocess cost 35.273704s cold and 2.694505s hot. The legacy auxiliary macOS App failed at listSectionSpacing; packaging/signing were not executed and have no measured saving. New producer-only CLI elapsed was 24.124s cold and 6.874s hot; its following Simulator build was 45.923s/6.111s. Observed complete recovery-route totals were legacy 112.731s/18.944s versus producer-only 70.053s/12.991s. These totals are not a strict successful-App acceleration claim: the legacy App failed and 14 independently regenerated archive hashes differed only in date metadata (all member payloads identical), changing the derived Simulator namespace. The successful old macOS App baseline and exact equivalent end-to-end saving are therefore not established. Cold means a fresh owned Apple/Dune/Swift cache, not cold OS caches or a dependency reinstall. Resource, authorization and preflight setup waits were excluded from the formal execution measurements.

Raw argv, sanitized actual process events, phase logs, native/envelope/receipt/product hashes and archive metadata comparisons remain outside the repository in this task's evidence directory. No repeated benchmark or unrelated macOS UI repair was performed.

## Questions

None. Scope, protected-file exclusions and measurement constraints were explicitly authorized in the delegated user request; routine implementation choices remain within that scope. Formal timing still waits for the coordinated exclusive Mac window.
