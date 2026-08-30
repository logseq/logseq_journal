# Align the Bonsai Flutter iPhoneOS SDK dependency universe

## Problem

The installed Bonsai Flutter iPhoneOS SDK was regenerated with DataScript
revision `5895af25101de15f56d7c5df383c150ca07cef90` and melange-transit 0.1.1 at
revision `a64270a1ed5c8ad3ff7e05dbb60e83ad0465ae93`. The application dependency
manifests and locks still select DataScript revision
`b1029d6a7210baae15aa2189293bd126b746bad4` and melange-transit 0.1.0 at
revision `b298260eb67d96710cb26eaad96a40c81b1af21b`.

The host OCaml tests and macOS build can use the installed packages despite
that stale metadata, but the Bonsai Flutter iPhoneOS preflight correctly
rejects `logseq_journal.opam.locked` because its reachable package versions do
not match the immutable SDK closure. The project therefore cannot reproduce an
unsigned iOS build after the framework update.

## Proposal

Update every project-owned DataScript and melange-transit dependency declaration,
source pin, and generated lock entry to the exact revisions and versions in the
verified iPhoneOS SDK. Update the existing dependency source-boundary contract
to require the new revisions and reject the obsolete revisions and 0.1.0
dependency declarations.

Also advance project-owned Bonsai Flutter source pins from
`f4377637a33cdc450204734d033bbcbb861e06bb` to the installed committed upstream
revision `de1196c2663b43388ebf04bd0612c5050edef753`, so fresh host installs use the
same framework source as this validation run. Preserve all unrelated staged
work and do not modify any OCaml file in the Bonsai Flutter repository.

## Decision

All four project package declarations and their locks select DataScript
revision `5895af25101de15f56d7c5df383c150ca07cef90`, melange-transit 0.1.1 at
revision `a64270a1ed5c8ad3ff7e05dbb60e83ad0465ae93`, and the current direct Bonsai
Flutter pins where those packages are declared. The source-boundary contract
owns these exact revisions and rejects every displaced revision and 0.1.0 pin.

## Alternatives considered

### Change only `logseq_journal.opam.locked`

Changing the one lock checked by iOS preflight would make this build pass but
leave package manifests, the other application locks, and future installs on a
conflicting dependency universe. Reject this partial compatibility path.

### Keep the old dependency universe

The old dependencies still support host builds, but they cannot be linked
against the verified iPhoneOS SDK and would require retaining an obsolete SDK.

## Acceptance criteria

- The dependency boundary contract fails before the metadata update and passes
  after it.
- Every project-owned DataScript pin resolves to
  `5895af25101de15f56d7c5df383c150ca07cef90`.
- Every project-owned melange-transit dependency and pin selects 0.1.1 at
  `a64270a1ed5c8ad3ff7e05dbb60e83ad0465ae93`.
- Every project-owned Bonsai Flutter pin resolves to
  `de1196c2663b43388ebf04bd0612c5050edef753`.
- Full OCaml tests, Flutter analysis and tests, macOS debug build, iPhoneOS
  toolchain verification, and unsigned iOS debug build pass.
- `spec-dev-tool check --all` passes.

## Risks

- Existing staged changes include dependency manifests and generated locks, so
  updates must be narrow textual replacements that preserve all unrelated
  edits.
- The selected revisions are immutable; another upstream dependency-universe
  update will intentionally fail the boundary contract until reviewed.

## Consequences

The project metadata now matches iPhoneOS SDK fingerprint
`bf5888716f9a50e87f0b4ac4a611109a8c4dd41c45d321d45c6dcc4e002623b2`.
The dependency boundary changed from a verified failure to a pass, and the
toolchain produced a verified unsigned arm64 iOS debug app with minimum target
15.0. Full Dune tests, generated-host validation, Flutter analysis and tests,
and the macOS debug build also pass. No application source adaptation or
generated Flutter host change was required.

## Questions

- None. The user explicitly authorized updating the dependency declarations and
  continuing the build and test workflow.
