# Timeline return to the first journal date

## Problem

Selecting Journals while already on Timeline needs to return to its first
presented date without animating hundreds of intermediate rows. Navigation and
bottom controls must remain stable. The original no-stall goal is **not met**.

## Decision

Keep the implementation measured at code revision
`5b2954c58dbe1e1638ed218564ab42b0c3e5f8a2`, based on main after PR110. On
2026-10-23 the user accepted closing this work at the documented current 60+ ms
layout boundary and requested documentation and a formal PR. Reuse PR111. This
records implementation and handoff, not a performance pass or merge approval.
Merge and TestFlight remain outside this work.

- Reselecting visible Timeline coalesces an outstanding request and resolves top
  intent against the actual first presented section: a future journal before
  nonempty Today, or synthetic empty Today when that is presented first. Capture
  retains its existing direct row target and waits for that target to mount.
- Commands use an independent `scroll_request` extension property across OCaml,
  native schema/fingerprint and Swift. Request and clear avoid full row snapshot
  serialization, decoding, deep equality and Swift content-owner publication.
- Resolve the existing UIScrollView once per mount. A noninteractive native cover
  provides content-only fade-out for 90 ms, an unanimated jump to the adjusted
  top inset while hidden, synchronous native layout, then fade-in for 150 ms
  after top geometry is ready. Chrome stays outside this transition. These phase
  durations do not promise a 240 ms total operation.
- Already-top and system Reduce Motion skip fades. Tracking/dragging takes
  priority; token/mount checks, cancellation on disappearance/context replacement
  and a deadline reject stale completions. Near returns use this same transition;
  the optional short decelerating scroll was not adopted.
- Bind chrome properties once per body evaluation to avoid repeated decoding;
  the next body still reads current properties. There is no cross-update cache.

Preserve List identity, delegate, datasource, data ownership, row sizing/height
mechanism and locked LUI `4fdb9136026af7863a8d025133871e34864eace1`.
Both later isolated LUI candidate sources were restored to the locked baseline;
no dependency patch or pin change is shipped. No old container/cache
implementation was restored.

## Alternatives considered

### Animate a long scroll or use only SwiftUI top requests

Long animation visits intermediate rows and amplifies layout work. Both attempted
public SwiftUI section/top-edge requests failed the actual content-origin check
and timed out around one second. A pinned header alone is not actual top. The
user approved the minimal UIScrollView adapter while retaining the List.

### Remove synchronous layout or move its scheduling

Removing `layoutIfNeeded()` still produced roughly 83–100 ms callback gaps and
geometry before visible cells were ready. The final source restores the call to
avoid revealing incomplete layout. A later dispatch or longer cover moves or
hides a pause; neither establishes input responsiveness.

### Cache heights, simplify wrappers or replace the container

The bounded fixed-frame, header and shared-LUI controls below did not establish
acceptable stable improvement and were not integrated. They do not prove that
all sizing/reuse strategies fail. No native collection replacement, persistent
height cache, broad List rewrite or LUI dependency update is included.

## Consequences

### Unresolved performance and measurement identity

The main-thread jump still calls `scrollView.layoutIfNeeded()`, including with
Reduce Motion. The synchronous-layout
[P1 finding](https://github.com/logseq/logseq_journal/pull/111#discussion_r4357273361)
remains unresolved. Fading does not fix that stall. Evidence identifies
visible-cell preparation and SwiftUI sizing paths, not a count proving all
loaded rows are recomputed.

Focused final-code diagnostics recorded 62.165/70.792 ms layout and
66.614/83.356 ms maximum main-thread display-callback intervals for first/repeat
far returns. Later independent controls recorded 56.183–76.221 ms layout and
66.661–83.325 ms callback intervals over four returns. Thus 60+ ms describes the
remaining measured cost, not a fixed duration or upper bound.

All current evidence uses synthetic data on iPhone 13 / iOS 26.1 Simulator,
Swift Release optimization and OCaml Release. DEBUG is used only for in-memory
fixture-key storage in the synthetic host. Provenance remains
`experimental-host-restamp`, `cross_abi_validated=false`: no physical-device or
full iOS cross-compilation/ABI acceptance claim.

Unrecorded timing starts at the actual native Journals press before OCaml
execution and command decoding, through decoded command clearance plus 200 ms.
True-top checks include the initial content row, not only a pinned header. Runs
have no recording, profiler or competing build. Callback intervals are not GPU
measurements and may intersect a boundary from outside it. First means first far
return after a fresh App process; OS caches were not cleared. Small sample sizes
and diagnostic-scope overhead remain limitations.

The final uninstrumented host and existing recording correspond to code revision
`5b2954c`, not a later documentation-only PR head. Native producer
`153ddf80f6c66255ec71b0f1ef7797a5494612fb` had unchanged native inputs revalidated
for that code. Diagnostic variants retain separate source/binary identities;
they must not be presented as shipped code.

### Retained changes and rejected local experiments

Command separation is implemented, not a remaining hypothesis. At `153ddf80`,
five text returns reached actual top with 60.729–67.783 ms layout,
66.625–83.291 ms callback intervals and 333.927–350.828 ms press-to-clear latency.
Three multi-image returns with system Reduce Motion on recorded 60.563–67.173 ms
layout and 82.291–99.046 ms callback intervals. Hot command decoding was about
0.023–0.028 ms; initial decoding was 3.547 ms. Older timings starting after command
decoding are not equivalent total-latency comparisons.

The final chrome binding reduced repeated property decoding from 70–76 calls
across 13–14 bodies to 13 calls across 13 bodies. Scoped decode cost fell from
about 0.674 ms to 0.254–0.359 ms. This bounded constant-factor change does not
remove the layout stall. All instrumented Journal presentation scopes together
accounted for about 0.69–0.93 ms after the change. Uninstrumented residual includes
backend, framework and diagnostic work; it is not automatically framework-only.

All prototypes below were external local experiments and were not integrated.
Candidate sources were restored; experimental files and evidence are retained.
First/repeat values are milliseconds:

| Experiment | Control layout | Candidate layout | Control/candidate maximum callback intervals | Outcome |
| --- | --- | --- | --- | --- |
| Fixed frames for nine measured leading items | 72.910 / 64.780 | 68.987 / 71.749 | 83.306 / 67.367 vs 83.330 / 83.320 | No demonstrated gain |
| Date-header HStack/Spacer replaced by trailing padding and a leading frame | 54.683 / 56.595 | 65.251 / 75.047 | 66.657 / 66.661 vs 83.329 / 83.324 | No demonstrated gain |
| Adjacent LUI horizontal/vertical padding combined into EdgeInsets | Four controls: 56.183–76.221 | 65.229 / 73.449 | 66.661–83.325 vs 83.287 / 83.922 | No demonstrated gain |
| Two LUI perfProbe guards changed to single-key environment presence queries | Same four controls | 48.475 / 47.661, then 52.639 / 66.686 | 66.661–83.325 vs 50.477 / 50.029, then 66.722 / 83.312 | Positive mean signal; stable gain unconfirmed |

The environment candidate's layout mean was 53.9 ms versus 67.8 ms for four
controls: it must not be described as wholly ineffective. Reverse confirmation
overlapped control and still reached an 83.3 ms interval. It was restored under
the conservative gate. The sequence was control, environment, padding, control,
then environment confirmation: ten complete actual-top returns in total.

Preparation was not free: fixed-frame publication was followed by a 58.207 ms
callback interval versus 16.735 ms in its control. These are observed intervals,
not exclusive cache CPU attribution. That prototype did not bypass native
preferred sizing. Its failed benefit gate stopped the full font/rotation/image/
content/mount invalidation matrix; no cache was integrated. Header, environment
and padding experiments added no prewarming or cache work outside measurement.

Padding expressions passed 168 size/child-proposal-set cases, 24 exact rendered
image comparisons and temporary-component state/focus changes. Proposal sets do
not prove equal call counts or order; these are not full LUI wire-node/AX
lifecycle checks. Environment checks covered unset, empty, runtime changes and
invalid UTF-8, plus an ordinary concurrent stress run. TSan crashed and ASan
stalled during initialization before entering their test bodies; neither is a
passing sanitizer result or evidence of a candidate race. No further experiment
is part of this closeout.

### Sampled attribution and unresolved questions

Two aligned Time Profiler windows contained 131 main-thread samples across
61.753/69.551 ms layout spans. Inclusive matches were AttributeGraph 79,
StackLayout 71 and DynamicViewList 62. Their union covered 105/131 samples, about
80%; these paths nest. Do not add the counts or convert them into exclusive
milliseconds or function-call counts. The Release LUI environment-probe path
appeared in 11 overlapping samples; actual logging remains gated by the key.
Text/font paths appeared in nine samples. No image-decode or native Auto Layout
solver path appeared in this text fixture's sample; this does not rule them out
for other data.

Sixty-five stacks hit the 255/256-frame limit. A separate deeper stack sample
corroborated preferred sizing but perturbed wall time and is structural evidence
only. The viewport has nine principal items: Today header, empty Today, an older
date header and six blocks; the first block has Chinese/emoji text and three
child previews. Each item has multiple view nodes. Counts do not establish
excessive hierarchy, a bug, all-list updates or repeated identical proposals.
The hottest specific row and redundant same-content/same-proposal counts remain
unknown. SwiftUI Instruments explicitly reported unsupported on Simulator; that
failed capture is not usable identity/proposal evidence.

### Functional validation, review and remaining gaps

Existing native snapshot/owner suites, Dune runtest and behavioral negative
controls passed for the command/target implementation. Final-code Simulator
checks covered Capture's direct target (the inserted row in the normal fixture),
near/far/already-top/repeated taps,
Favorites return, future dates with empty/nonempty Today and multi-image returns.
Earlier checks of the unchanged controller covered navigation during both fades,
active-drag priority, drag/navigation/return and actual system Reduce Motion.

An actual native pan-began event inside the original **90 ms fade-out** was not
captured: XCTest idle/preamble timing did not land the gesture in that window.
The duration was not extended and no phase was fabricated. This remains an
unpassed scenario despite other interruption coverage. A separate macOS App build
remains blocked by the unchanged baseline `listSectionSpacing` availability;
this change did not expand into that issue.

Independent read-only reviews checked implementation, identities and bounded
experiment conclusions. This documentation-only closeout needs document/link/
diff review and exact-head CI, not another Simulator build. Older code results
do not become measurements of the documentation commit. Repository-wide document
validation has five pre-existing format failures outside this decision; this
document is validated separately.

### Existing recording and evidence

Already delivered synthetic recording: `Timeline-scheme1-5b2954c-final.mp4`,
App 1.0 (1), 49.950 seconds, 1170 by 2532; Library
`libfile_a72ac63a15e4819193c426abececd94b`, version 1. SHA-256:
`d82586ca7e30c5c41c1599720e08177a305b1d44e69675013d5cb7c636c8f30f`.
This is the real Simulator App at code revision `5b2954c`, not a concept,
failed prototype or recording of this documentation update. Recording and
unrecorded performance evidence are separate. No new recording/upload is included.

Local records retain raw traces, failed controls and source/build manifests:
`SIZING-FINAL-DELIVERY.json`, `PERFORMANCE-SCOPE.md`, `LAYOUT-DEEP-SUMMARY.json`,
`ROW-PROPOSAL-DIAGNOSTIC.json`, `TOP-HEIGHT-EXPERIMENT-RESULT.json`,
`header-performance-*-summary.json` and `lui-ab-tests/RESULT.json`. Diagnostic
identities are separate from the uninstrumented recording identity; green CI
cannot replace this performance evidence.
