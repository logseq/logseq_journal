# Native LUI event boundary

## Problem

PR34 restores three host events but tests only the OCaml constructors. It does
not exercise the Swift declarations, native ABI, callback registration, or
synchronous patch delivery. The production owner of this boundary is
JournalRuntime's LUI event adapter; a pure application reducer cannot reproduce
an ABI or registration failure because it receives an already constructed event.

## Decision

Keep LUI's established typed native ABI. Both the fixed LUI revision 81af8e0
and inspected upstream main 1819094 use per-event native entry points and named
OCaml callbacks, including lui_ocaml_picked. The numbered Apple callback is a
separate AppKit host adapter, not a shared iOS OCaml decoder.

Extract the existing Swift event adapter so a headless Swift executable can
exercise the production adapter, Journal C bridge, and Journal_bridge callbacks.
Share the repeated node/string C trampoline with proper GC roots, preserving
Journal's runtime lock transitions and synchronous patch callback.

## Alternatives considered

### New generic event protocol

A new tag/JSON C dispatcher would change the native ABI instead of matching
LUI's existing one. Routing standard list/picker events as extension events
would fail the runtime's extension-node validation. Neither is in scope.

## Acceptance criteria

- A headless test sends real LUIEvent values through Swift, C, and OCaml, checks
  exact node/token/range/payload values, and observes patches before dispatch returns.
- The three restored events retain their typed LUI semantics.
- Related tests and the full iOS Simulator Debug app build pass; known unrelated
  suite failures are reported separately.

## Consequences

- scrollCompleted and visibleRange are present in LUI protocol/Apple backend but
  still lack upstream native C entries, so Journal must adapt them locally.
- PR35 is stacked on PR34 and must synchronize the updated base. The event
  adapter extraction preserves the loading callback ABI; PR35 is not changed.
- The iOS event path now has executable coverage at its actual ownership
  boundary. The user authorized alignment with LUI and this boundary coverage.

## Verification

- `python3 tool/test_lui_native_events.py` passed with the real fixed LUI Swift
  package and real OCaml runtime: 17 event cases, 64-bit IDs/tokens, Unicode
  payloads, synchronous patches, null rejection, and recovery after an OCaml
  exception. The fixture uses only Journal_bridge's public registration hook.
- `dune build @all` and `dune build --force @ios-app` passed with the isolated
  LUI 81af8e0 and DataScript a5ddac4 installed under task-3/local-prefix.
  The app is arm64 IOSSIMULATOR, minimum OS 26.0, SDK 26.1, with a valid ad hoc
  signature. No stub OCaml object was used.
- `dune runtest --force` passed the event semantics and 150 sync tests. Its sole
  failure remains the pre-existing source_boundary_test expectation of
  `V.progress` in unchanged app/journal_timeline.ml.
- New Swift files pass strict swift-format lint; the runtime retains two
  pre-existing indentation findings. Changed OCaml files pass ocamlformat;
  `git diff --check` and this agent document's validation pass. The repository-wide
  agent document check still rejects unchanged
  `implemented/feature/2026-09-28-bottom-lui-capsules.md` for missing required sections.
