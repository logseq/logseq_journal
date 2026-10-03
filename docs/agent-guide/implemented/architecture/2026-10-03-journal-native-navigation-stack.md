# Journal Native Navigation Stack

## Problem

Journal's Navigation_stack facade mounts only the top destination. Pushing Detail
tears down the retained Timeline; Back constructs every row and creates a new native
List with reset offset. Journal_routes owns only one detail view and retains composers
by block ID, so equal-block pushes cannot have independent presentation state and
covered detail completions cannot reach their original owner. The user explicitly
requests adapting Journal to the latest merged LUI native typed navigation API.

## Proposal

Use current LUI main through the existing main dependency declaration. Verified main
is67ea3e8a9787cd80b1106a11a2504a6735f96d30, including merged PR96 and toolbar corrections.
Journal main remainsc33fbe26; preserve local57b62c6, dc331ab and7f096e5 as ancestors of
feat/journal-native-navigation. No remote Git write or global opam mutation.

Journal_routes owns a typed Lui_navigation.Path whose immutable entry identities select
independent loading/detail/error states, editor sessions and outline/composer owners.
Root is outside the path. Native committed pop proposals reduce that authoritative OCaml
path; graph/runtime replacement fences obsolete entries and callbacks. Existing public
top-detail APIs remain convenient wrappers, with explicit owner-aware APIs for covered
entries and request completion routing. Do not store business state in Swift.

Mount the native navigation component once per graph owner, outside model-wide dyn.
Timeline, Capture, modal and chrome keep their smallest existing regions; each destination
subscribes only its entry projection. Register matching OCaml and Swift native navigation
schemas, route generic extension events through the production C bridge, and remove the
redundant outer Swift NavigationStack when the OCaml component owns the native stack.
Native Back supplies the pop affordance rather than Journal's emulated toolbar button.
The Detail row context menu exposes Open block (also on its root block), so deeper and
repeated-block pushes use a real public action; disclosure remains outline expansion.
The Detail native-list adapter dispatches row/action keys through its own rendered
handler table, retaining entry-scoped actions and rejecting unavailable row actions.

Preserve media root/token subscriptions, capture drafts, fixed media slots and leases.
Keep media metadata and subscriptions at graph lifetime; retire the previous foreground
page's demand on navigation, and admit positive visibility only from the current page.
Worker mutation failures carry admitted mutation/block identity through follow-up reads.
Background errors update the sync ledger rather than whichever Detail or Capture is current.
Covered Timeline values must publish changes to actual row regions, including detail-save
updates; no per-row subscription to the global model. Necessary structural list changes
remain local to the retained list container. Prefer persistent owner projections and indexed
row publications; disclose any retained-slot reconciliation cost separately from row builds.

## Decision

Implemented the requested Journal native navigation adaptation on the independent branch,
with pure public route-owner checks, narrow public mounted subscription checks where needed,
full aggregate native/app tests, and actual Journal Application→C→Swift Simulator acceptance.
Parent authorization includes local implementation, tests and commits; excludes push/PR/merge,
personal graphs. Later explicit user authorization permits a production update on the
original iPhone after all applicable verification passes, preserving its application data.
Use an independent synthetic service/bundle/device for diagnostics.
Foreground GUI or quiet performance windows are coordinated with the parent as needed.

## Alternatives considered

### Mount all pages in a Journal-created Swift router

Rejected: duplicates LUI's retained native navigation and moves business identity/state out
of OCaml. Use the merged public typed Path and native extension instead.

### Swap only the top-view facade

Rejected: one model detail owner cannot preserve repeated routes, covered completions and
independent drafts. Mounted native retention also requires navigation outside enclosing dyn.

### Subscribe every retained row to the global model

Rejected: per-row cutoff still runs N selectors for unrelated events. Preserve media indexes
and use row-local publications for actual Timeline changes.

## Acceptance criteria

- Latest mains and concrete tested LUI SHA are recorded; declared dependency remains main.
  Three completed local commits remain in history; original user worktrees are untouched.
- Timeline root LUI node/list identity and scope remain across push/pop, with observable
  native anchor/offset retained. No promise about SwiftUI internal object lifetime.
- Multiple detail entries, including repeated block IDs, have distinct IDs/editor/outline
  state; native Back, programmatic pop and pop-to-root reach the correct prior owner.
- Detail responses and mutations update their originating live entry, covered/root row
  updates affect only actual target regions, and generation/stale callbacks cannot alter
  a replaced graph or disposed owner. Capture draft and media notifications preserve scope.
- Pure reducer public reproduction/tests cover state ownership first. Narrow mounted tests
  cover subscription/identity behavior the reducer cannot own; no private mli bypass.
- Actual Journal full-runtime Simulator before/after evidence distinguishes mount/build,
  patches, native layout/offset and decode. System Back and real gesture behavior are reported
  independently; cancelled/completed swipes must not be inherited from a Swift-only demo.
- Full current build/runtest and applicable native/portable checks pass; no protected spec,
  Dune, unrelated backend or historical evidence edits. Decision and final report validate.

## Risks

- Covered pages remain subscribed, so stale lifecycle events need explicit entry/generation
  fences. Scope disposal belongs to LUI settlement/teardown, not onDisappear.
- Matching OCaml/Swift extension registries and bridge event ABI are necessary for real native
  navigation. Existing toolbar hoisting and shell sheets must avoid nested navigation owners.
- Async detail/append/delete/status work currently routes through top state; changing only
  the renderer would lose or misroute covered work. Preserve original request/session owners.
- Native scrolling and interactive transition behavior need actual Journal verification.
  Synthetic Worker checks do not establish real sync, user data, pixel drawing or phone FPS.

## Consequences

Journal uses the merged native navigation owner and typed OCaml route identities. Retained
root and covered entry subscriptions survive navigation, with independent detail state.
Initial mounts, structural timeline work and generic LUI reconciliation remain measurable
costs; no entire-app latency guarantee or retained-row eviction is introduced.

## Verification

Public route-owner RED/GREEN, admitted mutation failure RED/GREEN, and narrow mounted
root retention/covered row/native row-action RED/GREEN passed. Final @all/native object,
aggregate application/domain/Worker suites, and original registered portable regressions
compiled through public native APIs passed. Synthetic localhost transport needed approved
execution;150 unchanged cases passed after a preserved existing frame-count file race.
The legacy bytecode launcher cannot load the embedding stub in this OCaml5.5 environment;
its same registered pure/runtime source passed the compiled native runner.

Final synthetic actual Journal Application -> production C -> Swift native common and
extended runs completed with0failures. Root List154/weak UICollectionView and offset
1500.6667 survive push/native pop; Back builds root/Timeline/rows0 and emits57patch ops
versus fixed7f+LUI67 BEFORE1872. Covered N50 public Worker update builds/notifies one row,
root/Timeline0,2patch ops;50 retained-slot comparisons remain O(N). Repeated same-block
entries keep independent drafts, retired callbacks are inert, actual generation2 reset
clears owners, and old-generation native pop replay does not pop a new live entry.
An independent XCTest uses actual navigationBar Back.isHittable/.tap and completes the
full native trace with0failures/rejections. Gesture swipe/cancel and FPS remain unmeasured.

Evidence is outside Git in task2 implementation-evidence/native-navigation/RESULTS.md,
final-acceptance/, native-back-ui/final-native-back/, and iphone-production/. Frozen85
native product sources match all85 overlapping production phone inputs with0mismatch;
all247 production inputs have0drift. Production Debug build/signing preparation uses the
original authorized pipeline and preserves data. Final installation is a subsequent
explicitly authorized action after these gates, not a performance or personal graph test.

Changed OCaml formatting and diff checks passed. Existing Swift lint rule counts are
unchanged. Global decision validation still reports the unchanged historical bottom-lui-
capsules document missing three sections; this new decision validates. Global status/delete
interaction gates and generic LUI reconciliation costs remain separate audit boundaries.

## Questions

- Implement native Journal navigation with the scoped local-only checks above? **Answered:**
  the user explicitly requested latest-LUI navigation adaptation; the parent explicitly
  authorized implementation, testing and local commit, preserving prior local work.
