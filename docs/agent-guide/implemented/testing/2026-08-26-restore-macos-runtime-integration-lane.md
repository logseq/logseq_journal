# Restore macOS Runtime Integration Lane

## Problem

`logseq_db_worker/tool/test_macos_runtime_flow.sh` invokes
`flutter/integration_test/logseq_db_worker_runtime_flow_test.dart`, but that file
and its snapshot-target harness were deleted when the application moved to the
managed-sync startup contract. The script therefore fails before launching a
macOS test host. The source-boundary allowlist still names all four deleted test
files, so normal repository tests do not detect the broken lane.

The obsolete tests cannot be restored unchanged: they construct the removed
snapshot startup target and bypass the current local-account, catalog, mirror,
wrapped-key, and post-presentation reconciliation boundaries. A passing legacy
test would not validate the encrypted offline behavior claimed by the current
testing decision.

## Proposal

Replace the stale lane with one current compiled macOS integration test. Extend
the fixture generator with an encrypted managed-sync warm-start fixture containing
a synthetic account, selected encrypted graph catalog, admitted local mirror, and
deterministic Timeline rows. Run the debug macOS host with the existing debug-only
in-memory private-key and wrapped-key stores, seed those stores through the native
crypto channel, and start the real compiled `logseq_journal` entrypoint through
`RuntimeClient`.

The test must use a local account binding, a never-resolving authentication token
capability, and no external endpoint. It must reach the deterministic Timeline,
acknowledge presentation, and prove that no token request occurred before that
presentation. It must also cover a missing wrapped-key fixture and require the
explicit `Online recovery is required` state without issuing a token request.

Remove deleted integration filenames from the source-boundary allowlist and make
the allowlist require the new test and fixture helper. Update the shell lane to
build its generator, allocate fixture roots under the writable system temporary directory,
run only the current test, and clean its synthetic directories.

## Decision

Replace the deleted snapshot-target test with
`encrypted_offline_warm_start_test.dart`. The fixture generator now publishes two
current managed-sync fixtures: one with a selected encrypted ready mirror and one
used after deleting only its wrapped graph key. A debug-only native fixture
operation generates scoped RSA and graph-key material, and it refuses to run
unless both secret stores are explicitly configured as in-memory stores.

The macOS shell lane builds the generator, supplies both fixture documents to the
compiled Flutter host, runs the integration test, and removes its temporary
directories. Source-boundary coverage requires the replacement file, command,
and memory-store configuration while forbidding the obsolete test path.

## Alternatives considered

### Restore the deleted snapshot-target tests

Rejected because the snapshot startup target no longer exists and recreating it
would add a compatibility path that cannot exercise managed encrypted startup.

### Treat the OCaml service test as sufficient

Rejected because it does not prove that the Flutter macOS host embeds and drives
the compiled runtime, native crypto bridge, application platform, and Timeline
presentation acknowledgement together.

## Acceptance criteria

- The source-boundary test fails while the current integration files are absent.
- The encrypted fixture generator test fails before the new fixture mode exists.
- The macOS lane launches the compiled host and presents deterministic local rows
  with a never-resolving token capability whose request count remains zero through
  Timeline presentation.
- A missing wrapped-key fixture presents explicit online recovery without an
  implicit token request.
- The integration process uses only synthetic content and debug-only in-memory
  secret storage and leaves no Keychain item behind.
- `dune runtest`, Flutter analyze/unit tests, the repaired macOS integration lane,
  signed macOS Runner tests, and `spec-dev-tool check --all` pass.

## Risks

- The in-memory secret backend does not replace the separate signed real-Keychain
  test; both lanes remain required for their distinct integration boundaries.
- Live Flutter macOS tests are slower and more timing-sensitive than pure OCaml
  tests, so waits must observe state with explicit bounds rather than fixed sleeps.
- The fixture must not introduce a production-selectable test startup target or
  permit debug secret-storage environment variables in profile/release builds.

## Consequences

The macOS runtime lane is self-contained and exercises the current managed-sync
startup contract instead of a removed compatibility target. It proves local
encrypted Timeline presentation before authentication and explicit recovery for
a missing wrapped key. Its ordinary integration run cannot touch Keychain, while
the separate signed opt-in probe continues to verify an isolated real Keychain
item and deletes that item before completion.

The fixture generator retains its older snapshot modes for their existing unit
coverage, but the application integration script no longer selects them. Future
startup-contract changes must update the single allowed integration test and the
source-boundary assertions together.

## Questions

- None. The user explicitly requested repair of the broken macOS integration lane.
