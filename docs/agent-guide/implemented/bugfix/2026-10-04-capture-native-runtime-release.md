# 2026 10 04 Capture Native Runtime Release

## Problem

Capture Send can freeze the entire iOS UI. On the exact phone baseline
0524864/LUI adbdf63, the production Simulator app froze after one marked Chinese
text capture in ocaml-sync-test. Two samples show the main thread in a nested
OCaml runtime acquisition, called by a deferred LUI event during patch apply.
The outer C bridge entry still owns the runtime. The mutation was submitted
once despite the visible Saving state; retrying can duplicate content.

## Decision

Copy each returned patch into C-owned bytes while holding the runtime, release
the runtime, then synchronously deliver the owned bytes to Swift. Keep the
existing host ABI and apply this contract to every patch-producing entry,
including start, dispatch, pump and dispose. Release roots before unlocking;
free each response after its callback, so nested dispatch and GC cannot alter
the outer response. Root extension arguments across allocations.

Use branch fix/capture-runtime-release-2026-10-04 based directly on main
0524864, with the locked LUI version. This contains only the bridge repair and
its tests/documentation. The earlier 1056da3 candidate over local 8977c0 and
the graph-pressure/preview work remain on separate preserved branches.
Create a Draft PR only after final-source actual UI acceptance and independent
review. Do not merge, install on a phone, or change the independent 256KiB limit.

The production ownership boundary is the native host bridge. Public pure
Application reducer events/completions can reach Saving and finish saving,
but cannot execute C runtime acquisition or Swift apply/deferred event delivery.
The missing boundary is therefore tested through public Journal_bridge hooks,
the production C trampoline and Swift event adapter, in a bounded subprocess.

## Alternatives considered

### Queue host events to another main actor turn

This also avoids lock reentry, but introduces a separate event scheduler and
session FIFO. The user selected the Chat-style response ownership/release
boundary instead. No generic LUI driver or dedicated runtime thread is needed.

## Acceptance criteria

- Old production bridge times out on synchronous callback reentry; the fixed
  bridge passes all event, lifecycle, ownership and exception regressions.
- Existing aggregate OCaml tests and native build pass with frozen dependencies.
- Actual authorized Simulator UI sends finish and remain responsive on
  ocaml-sync-test; record own test IDs and never resend C1. If GUI tools are
  unavailable, explicitly leave this acceptance criterion pending.

## Risks

- Patch callbacks remain synchronous and main-thread-owned. The change removes
  runtime ownership during UI application, without changing the ABI.
- Each response needs a temporary allocation. Allocation failure is reported
  as failure instead of silently dropping a patch.
- Existing user data and graph must stay intact. Simulator acceptance is
  limited to a few marked records and scoped readback of those records.

## Questions

- Which repair boundary is authorized? Answered by the user: implement the
  Chat-style native bridge release, then actually test it on the Simulator.
- May the frozen app be terminated and upgraded for testing? Answered: yes,
  after retaining samples; preserve the graph and do not resend C1.

## Consequences

Every patch-producing native entry now uses one owned response and a common
release-before-delivery helper. The external callback/Int32 ABI is unchanged.
Extension arguments are rooted across both string allocations. Platform
envelopes still enqueue work without applying UI; wakeup/request callbacks
still schedule host work asynchronously, as before.

Audit of the locked Lui_app/Lui_runtime and Application entry points found one
flush batch per entry: start, dispatch, extension event, pump and dispose each
flush once; send only reduces state. Nested host events start a new entry after
the previous batch is fully applied. Stack-owned responses preserve their
ordering and bytes without a global latest-response buffer or event scheduler.

The original production bridge timed out after 20 seconds on a synchronous
startup callback querying the runtime. The repaired bridge passes 17 event
types, start/pump/dispose/restart, exception recovery, nil arguments, binary
platform event/response/failure envelopes, and 100 rounds with two nested
events while another OCaml domain allocates and performs minor GC.
Both the earlier combined-source candidate and this bridge-only main052
candidate pass the production native build, complete dune regression suite
and production native bridge regressions with frozen dependencies. Rebuild the
bridge-only Simulator artifact for final-source UI acceptance; do not attribute
the earlier 8977-based artifact to this main-based release.

Actual ocaml-sync-test UI acceptance remains pending and is assigned to a
separate GUI executor because this selected environment has no CUA/GUI tool.
This executor performed no install, termination or further Send. Keep C1 block
01a10638-1d46-8de7-9c0b-beefda5305e0 intact; do not resend it.
An optional preexisting platform-wire script stops on its missing
Journal_environment compile input. Aggregate document checking reports only
the preexisting bottom-lui-capsules document missing required sections; this
new decision document passes. These unrelated files were not changed.
