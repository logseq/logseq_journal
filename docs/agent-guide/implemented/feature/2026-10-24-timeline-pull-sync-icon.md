# Timeline pull sync through the shared owner

## Problem

Timeline has no deliberate pull-at-top entry into the existing sync owner.
Online recovery currently inspects local sync state without guaranteeing a fresh
pull, and busy force intent is not retained. The existing header spinner only
covers Connecting.

## Proposal

The user approved design v3 and implementation plus isolated A135 acceptance on
2026-10-24. The later English-default requirement sets the top drag hints to
Pull to sync, then Release to sync at the threshold;
hide it at release/cancel. Reuse only the existing Options-left loading component.
Extend the existing Online_recovery_requested path and private pull-owner facts:
online forces a check, offline uses existing admission/connection recovery, busy
intent coalesces until the shared owner can send. Existing response/authoritative
commit and sync phases own completion. Do not add a refresh state machine or
per-refresh public contract. No spec/ or Dune changes are needed or authorized.
Use the native List's existing container geometry/phase observers for the small
trigger and text overlay; retain native scrolling, delegate, rows and anchors.

## Decision

Implemented the optional Timeline callback through Application's existing
Begin_online_recovery action and Online_recovery_requested event. The shared Core
retains one private forced intent until its existing pull owner can send; the
existing response and authoritative commit own completion. The existing header
progress node now spans Connecting, Pulling and Submitting without replacement.
No protected spec/ or Dune change, independent refresh state or top spinner.

The default native accessibility action is Sync. The English-default audit also
replaces unconditional Capture attachment labels with Files, Photos and Camera,
and the photo-add permission description with English. Existing locale-selected
Chinese image-preview translations and graph/test contents remain intact.

The existing public Core contract first reproduced the missing force behavior,
then passed with online, busy, commit, offline/scope, cancel/shutdown and submission
barrier cases. Header identity and optional native callback checks pass in their
existing targets. Full dune build @all and dune runtest --force pass.

A135 iPhone 13/iOS26.1 ran the actual production List, Timeline, header and Core
in a Git-external synthetic IO fixture. Public XCTest touch drags verified short
pull cancellation, armed release, both hints in actual recorded frames,
online/no-change, offline/reconnect/apply, busy repeats, page exit/return, deep
scroll non-trigger and stable first-row position. Actual system Reduce Motion
was enabled for short/long physical drags and restored to its original off value.
The complete flow and Reduce Motion tests both pass. CUA coordinate dragging was
ineffective, so the explicitly authorized official XCTest path was used.

## Alternatives considered

### Default refreshable and a separate per-check contract

Rejected by the updated user design: a second top spinner and independent refresh
state are unwanted. The original spec extension proposal remains external evidence
only and is not applied. Shared sync phase is sufficient for the reused activity
indicator when the actual shared owner retains force and owns completion.

## Acceptance criteria

- Below-threshold release/cancel creates no sync request; armed release creates
  one shared trigger and hides the hint immediately.
- Online pulls, offline reconnect/open/pull, and busy/repeated coalescing use the
  existing owner and transport; no parallel connections or dropped forced intent.
- Loading is one existing header component, derived from active shared sync phases.
  Queue admission, old Current and socket open never imply completion; response
  and required authoritative apply retain Pulling until the shared work settles.
- Graph/lifecycle exit retires or fences intent; no refresh continuation or endless
  independent spinner is introduced. Existing errors/Diagnostics remain shared.
- Stable List/row identity, anchors, return-top cancellation and Reduce Motion remain.
- Write meaningful failing public Core checks first, then minimal implementation,
  passing checks and full applicable local validation in existing test targets.
- Use A135 only with isolated synthetic fixture, no accounts/real graphs, no new
  device, 1446, reset/deletion or OS permission changes. Record actual implemented
  native UI, with accurate coverage limits. No push/PR/merge/TestFlight.

## Consequences

- Native List overscroll remains system-owned. Only semantic hint changes update
  view state; the overlay reserves no layout space and no per-row geometry exists.
- Keep the unrelated error-icon branch separate; main remains d37ee9c as fetched.
- Reuse prepared build inputs without changing another owner's switches or caches.
- Simulator host-restamping has cross_abi_validated=false; this is execution
  evidence, not a validated cross-compiled iOS release artifact. Synthetic auth,
  transport and apply completions do not establish live service/account acceptance.
- No performance measurement, live graph mutation or dedicated native blocking
  error scenario is claimed. Existing shared error/Diagnostics behavior remains.
- Evidence, temporary XCTest, original videos, result bundles and build manifests
  are outside the repository in the task's implementation-evidence directory.
  The final actual-gesture recording supersedes the earlier partial AX recording;
  neither it nor the earlier design movie claims production network verification.

## Questions

None. The latest user approval answers the implementation/isolated A135 scope.
The obsolete per-check protected-spec proposal is not part of this design.
