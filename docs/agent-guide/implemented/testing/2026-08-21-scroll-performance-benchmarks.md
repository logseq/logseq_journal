# Scroll Performance Benchmarks

## Problem

Continuous vertical scrolling on macOS feels detached from the trackpad even
though the journal uses a sparse, bounded virtual sliver. Existing correctness
tests verify the supplied window, extent geometry, pagination, and gesture
arbitration independently. They do not measure the repeated hot path from a
painted-range change through the OCaml runtime and back to Flutter.

Every changed painted range currently updates `Journal_timeline_state`, slices
a new supplied window, recomputes sparse extents over the retained cache, builds
the supplied row widgets, reconciles a runtime frame, and applies that frame in
Flutter. Without repeatable measurements it is not possible to distinguish
geometry cost, application reconstruction, runtime reconciliation, event
backpressure, and Flutter build/layout/paint cost.

## Decision

Add two complementary benchmark paths without changing production behavior.

The OCaml benchmark will exercise consecutive visible-range observations on a
fully populated retained cache. Each iteration will consume the current sparse
window and extent geometry so the benchmark covers the application-owned work
performed before widget construction. It will report elapsed time and operation
counts while retaining correctness assertions for the bounded window.

The compiled-runtime benchmark will run only on macOS and use the existing
pagination fixture. It will send trackpad pan/zoom sequences through the real
Flutter scrollable at steady and high velocities. Each case will report JSON
containing scroll distance, wall time, Flutter frame percentiles, runtime frame
percentiles, patch sizes, dirty-node counts, and visible-range event coalescing.

Timing values are observations, not pass/fail budgets. Debug Flutter, profile
Flutter, host load, and display refresh rate are not comparable enough for a
single repository-wide duration threshold. The tests will instead assert that
the intended path ran, scroll position advanced, no renderer exception occurred,
and existing memory, mounted-node, patch-size, and supplied-window bounds held.

## Alternatives considered

### Add a fixed frame-time threshold to normal CI

Rejected. A threshold loose enough for debug macOS tests would not detect the
reported interaction problem, while a release-quality threshold would be flaky
across CI hosts. Structured measurements can later define hardware-specific
acceptance gates from observed distributions.

### Benchmark only sparse geometry

Rejected as insufficient. Sparse geometry is one component, but the reported
symptom crosses pointer dispatch, visible-range publication, OCaml state,
runtime reconciliation, and Flutter rendering. The pure OCaml benchmark keeps
the application cost visible while the compiled-runtime benchmark measures the
complete feedback loop.

### Profile a developer graph directly

Rejected for the repeatable benchmark. A developer graph is valuable for manual
profiling but changes over time and may contain private data. The committed
pagination fixture gives stable row counts and content while still exercising
the compiled database worker and application runtime.

## Acceptance criteria

- A repeatable OCaml benchmark reports consecutive visible-range, window, and
  extent-geometry work on a maximum-size retained cache.
- macOS compiled-runtime benchmarks cover steady and high-velocity trackpad
  scrolling against the pagination fixture.
- The macOS report includes Flutter frame timing and Bonsai runtime/reconciliation
  counters in machine-readable JSON.
- Benchmarks verify scroll progress, bounded supplied/mounted work, bounded patch
  size, and the absence of renderer exceptions without enforcing machine-specific
  timing thresholds.
- Existing OCaml and Flutter tests remain green.

## Observed baseline

The benchmark was run on macOS with a debug Flutter host and the release OCaml
native artifact. The OCaml state-only path took approximately 96 microseconds
per range for sparse extents and 125 microseconds per range for dense extents on
a 512-slot retained cache.

The steady trackpad case recorded 111 Flutter frames. Median total frame time
was 18.4 milliseconds, p95 was 34.7 milliseconds, and 69 frames exceeded 16.7
milliseconds. The high-velocity case recorded 40 frames with a 16.1 millisecond
median, 22.5 millisecond p95, and 13 frames over 16.7 milliseconds.

Runtime work, rather than the state-only geometry functions, is the dominant
signal. Steady scrolling produced 82 runtime frames after 206 coalesced events;
high-velocity scrolling produced 36 runtime frames after 275 coalesced events.
The median patch remained about 60--61 KB and the median dirty-node count was
831--843 per runtime frame. Flutter build time accounted for nearly all recorded
frame time in the test host, while raster time was negligible.

## Optimization direction

The updated `bonsai_flutter` API requires every `Sliver.varied_extent` item to
carry an application key. Stable logical slot keys are therefore the first
experiment: they let reconciliation preserve overlapping materialized children
when the supplied window shifts instead of replacing the full 40-row subtree.

That experiment reduced the steady-scroll median patch from 60,319 to 5,944
bytes and median dirty nodes from 831 to 124. Steady p95 frame time fell from
34.708 to 19.294 milliseconds. In the high-velocity case, the median patch fell
from 61,133 to 9,674 bytes, median dirty nodes fell from 843 to 174, and p95
frame time fell from 22.544 to 17.398 milliseconds.

Window hysteresis is no longer the next default change. It should be considered
only if profile-host or Instruments measurements still show a user-visible
problem after stable keys. Any hysteresis design would keep the supplied
40-row window stable until the painted range approaches a guard band, while
continuing to track exact visible demand for pagination.

The second experiment should stop recomputing retained-slot sparse extents when
only the visible range changes. Extents depend on retained slots, expansion,
profile, and safe-bottom geometry, not on the painted range. This removes an
O(retained slots * expanded IDs) pass, although the state-only benchmark shows
that it is a secondary optimization.

Handler identity stabilization is also deferred. Stable keys removed most of
the patch and dirty-node churn, while the remaining debug-host frame time is
mostly Flutter build time. Event queue coalescing is already effective and
should not be the next optimization target.

Each experiment should compare runtime-frame count, patch bytes, dirty nodes,
and p50/p95 Flutter build time against this baseline. A profile Flutter host and
an Instruments trace should confirm the winning design before adopting a fixed
frame-time budget.

## Consequences

The OCaml test suite now performs two bounded measurement loops and prints two
JSON records. The macOS compiled-runtime suite adds one selective test containing
two velocity cases and prints one JSON record per case. Non-macOS hosts skip the
compiled-runtime benchmark.

Normal correctness gates remain machine-independent because timing values are
not assertions. The benchmark intentionally adds approximately one second to the
OCaml test executable and approximately ten seconds to the selected macOS runtime
test on the development machine. No production source, protocol, `spec/` file,
Dune file, or bonsai_flutter source changed.

## Risks

- Widget-test pointer injection follows Flutter's macOS trackpad event path but
  does not measure AppKit event delivery latency. A later Instruments trace on a
  signed profile build is still required before selecting an optimization.
- The runtime benchmark uses a release OCaml artifact with the Flutter test host;
  debug-host numbers must not be treated as release-product frame budgets.
- Printing measurements from ordinary tests can add log noise, so reports use one
  stable JSON line per benchmark case.
