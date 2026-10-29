# Fixed Resident Timeline Hosts Implementation Plan

Goal: Keep each materialized graph's Timeline and native navigation instance at one stable owner-keyed location throughout a right-swipe transition.

Architecture: A bounded keyed collection retains up to three homogeneous graph page hosts.
Each host owns its presentation signal, row/media stores and native navigation state; account, authentication, worker runtimes and platform services remain shared.
Hidden hosts freeze presentation notifications while graph synchronization continues.

Tech Stack: OCaml, Signal/LUI, SwiftUI native List and navigation, UIKit pan recognition, XCTest, Time Profiler.

Related: Builds on proposed/architecture/2026-10-28-resident-graphs.md and the external handoff-performance-boundary.md evidence.

## Problem statement

A loaded target List is currently adopted from a bare preview into a different navigation subtree at focus.
Its virtual node ID survives, but its SwiftUI ancestor identity changes and triggers repeated mount/restore and a measured240–273ms display callback gap.
The existing image-color fix and idle-ready callback fix are preserved in e37ba13f58a4f06471632b93c00137c7a3d798e2.

## Testing Plan

The application mounting boundary owns the retained tree, graph dispatch and presentation subscriptions; the pure navigation reducer cannot reproduce native ancestor changes.
Reuse the existing public-service application fixture and native acceptance cases for resident ownership, hidden synchronization, drafts, saving, removal/reopen and gesture behavior.
Adapt obsolete preview-tree and handoff-cover expectations to the fixed-host contract, without adding test cases or tests for test/CI infrastructure.
The attempted additional product regression write was rejected by automatic review under the user's latest testing constraint; it did not execute and is not retried. Existing native run82 supplies the observed repeated mount/restore and ancestry failure before implementation.
Retain the existing color and native gesture checks; verify fixed-host lifecycle with temporary external diagnostics and actual GUI evidence.
Run full source build and regression on final production bytes, independent review and actual synthetic Simulator acceptance.
Compare the same optimized fixture, image data, native gestures and time windows against profiles79/80 and lightweight run82; count patch operations, mount/restore callbacks and display gaps, without increasing warm-switch animation duration. The user later explicitly approved a native first-open preparation transition; measure that cold path separately from warm switching.

Validation uses the existing checks and preserved pre-change failure evidence; no new test cases are added.

## Implementation steps

1. Preserve the three validated local changes as a local baseline commit and save their patch externally.
2. Adapt existing application-view expectations and unscoped picker selectors to the retained-host structure; run the existing 155-case suite.
3. Run the existing media semantics and native lifecycle checks, preserving pre-change run82 as the native structural failure baseline.
4. In app/application.ml, mount one keyed collection of full-owner presentation hosts outside the changing focus model.
Create a host only for the focused graph or an explicitly prepared target; retain it until that exact runtime retires.
Each host gets an owner-qualified dispatch, a private presentation Signal, fixed runtime-store references and its own header Signal.
Freeze host inputs while hidden, resume the latest graph state on prepare/focus, and keep callback lifecycle checks independent of the current graph.
5. Keep each graph's existing native navigation revision and owner fence inside the homogeneous host.
The first implementation retains native navigation UI per graph to avoid weakening the existing path/owner fence; it does not clone platform/auth/sync services.
Mount the shared picker/startup overlay outside the hosts, so opening it does not dispose a retained Timeline.
6. In app/journal_header.ml and its application interface, publish a reactive graph-pages payload and owner-keyed host slots without rebuilding host children on focus or preview revision.
7. Gate Journal_media_view.Store notifications while a graph's presentation is hidden; coalesce dirty subscribers and catch up once on activation.
Retain real data updates and resource cleanup.
8. In swift/JournalChrome.swift, render fixed owner-keyed native panes at stable ForEach positions.
Change translation, input and accessibility roles only; keep image enabled appearance, right-only direction admission, cancel and fast-gesture fences.
Remove the old preview-to-navigation handoff. Warm switches have no snapshot or readiness wait; an unopened page may use one transient source-only native snapshot and a bounded reveal after its own current List layout.
Keep per-pane scroll scope immutable, with only its records role changing.
9. Adapt native lifecycle checks to the retained-host contract, run GREEN, then simplify only after the affected regressions pass.
10. Build the final experimental optimized Simulator fixture with the maintained private toolchain and exact source manifest.
Run real cached/delayed/mixed-height image cases, saved scroll positions, drafts, pending Save, hidden synchronization, management/removal/reopen, navigation return, cancellation and repeated gestures.
Run final full checks, independent review and performance comparison; save and upload only synthetic original-speed videos below10MB each.

## Testing Details

Wire assertions verify actual mounted ancestry and public service effects, not helper data formats.
Native tests and buffered diagnostic runs verify actual UI lifecycle and input, which the OCaml mounting boundary cannot execute.
Existing tests are reused for drafts, saving, graph management and lifecycle contracts.
The synthetic Simulator is52A4C83E-57D2-4676-A164-BF80E91BBF67; the other two devices and real graphs remain untouched.
All generated hosts, logs, artifacts and reports stay in evidence/fixed-timeline-hosts or the existing image evidence folder.

## Implementation Details

- Host identity is account generation, graph UUID and graph generation; presentation tickets remain current without changing host identity.
- At most three native page/navigation hosts exist, with lazy initial presentation construction.
- Hidden DB/sync remains live; row, media and header presentation subscriptions freeze.
- Read each newly admitted full scope once to recover open pushes that preceded membership. Prepare its first metadata/feed without mounting a hidden page; later hidden invalidations stay deferred.
- An unopened target prepares on committed release, after source-only UIKit motion is submitted. The source snapshot follows the real pan, cancels back without preparation, and is released after the real target List has laid out its current payload. Warm targets retain direct page translation.
- A queued Save can delay asset-file acquisition; render the target's real cached text and dimensioned image placeholders instead of a blank screen. Do not claim those placeholders are loaded images.
- A closed graph keeps only lightweight known-scope cleanup ownership until admitted resource releases finish; stale-account cleanup is pruned. Physical lease-table diagnostics must demonstrate release, not just cancelled callers.
- Late callbacks retain their original owner and cannot route to the visible graph.
- Cancellation, external selection, graph removal, account exit and scene changes fence stale animations.
- No new visible Timeline UI, left-swipe switching, graph eviction or persistent credentials.
- No protected spec contract or Dune change is planned.
- Final source evidence must supersede earlier green source fingerprints.
- Performance claims distinguish optimized Simulator fixture evidence from shipping-device guarantees.

## Question

No user decision remains for the approved host structure.
The Planning Documents helper and spec-dev-tool executable were unavailable at planning time; naming follows this skill's numbered implementation-plan convention and the plan will be checked with repository tooling if it becomes available.
Publishing a PR or a new TestFlight remains outside this stage's authorization.

---
