# Native iPhone Performance Measurement

## Problem

The native UI has physical functional evidence, but macOS measurements do not
establish iPhone Release startup, idle, scrolling, memory or lifecycle behavior.
Accessibility inspection itself affected pagination on macOS, so mixed samples
would obscure the actual device baseline.

## Decision

Use the current signed isolated full-runtime Release host and a fresh known-count
encrypted graph with blocked authentication and memory-only secret stores. Record
physical Instruments traces using available xctrace templates. First launch and
sample without XCTest, AX or UI interaction. Then measure explicitly identified
accessibility inspection, scrolling to the final root, loaded idle, navigation
and actual foreground/background phases. Retain CPU, memory and animation data
only when exported tables provide the corresponding metric; never infer frame
time or launch latency from command elapsed time.

Keep fixture counts, current source/binary hashes, trace configuration, timing
windows and tool overhead visible. Distinguish logical loaded rows from AX
materialization; if no independent count exists, report that limitation. No
production graph writes, global preferences or production changes are planned.
Actual VoiceOver speech/order and system accessibility acceptance are deferred
by the user. XCTest evidence is not evidence of those deferred checks.

Complete the bounded physical measurement workflow with the retained batch 41
results. Keep detail-return restoration and responsiveness attribution open in
the active UI scope. Do not treat observation-harness success as feature success.

## Alternatives considered

### Reuse the macOS resource numbers

Rejected: AppKit materialization and desktop runtime behavior do not prove UIKit.

### Use only XCTest timing

Rejected: automation latency and accessibility processing confound rendering.

## Acceptance criteria

- Retain a current physical Release no-AX/no-interaction trace and known fixture.
- Retain separate UI-driven scrolling, final-root/loaded-idle and navigation or
  lifecycle measurements, with directly exported metrics and explicit limits.
- Document genuine regressions for their owner before any implementation change.
- No claims of complete performance or accessibility acceptance from unsupported,
  absent or indirect metrics; the full standardization scope remains intact.

## Execution result

Batch 41 retains three physical Instruments traces, exported app CPU/footprint,
app-attributed hitch events and potential interaction delays, exact phase timing,
known fixture count, binary hashes, device readback and independent navigation
observations. No-AX baseline and UI-driven phases are kept separate. Report:
`docs/test-reports/2026-09-16-native-swiftui-standardization/batch41-performance.md`.

A native detail-Back scroll reset is reproduced and tracked in the proposed
`retain-journal-position-after-detail-back` decision. Pre-scroll delays remain
unattributed and controlled first-content startup latency remains unmeasured.
These limits prevent full performance/UI closure; they do not invalidate the
bounded measurement workflow. This testing decision is complete for the evidence
collection criteria and makes no claim that the observed defects are fixed.

## Consequences

Batch 52 reanalyzes the retained trace on macOS. Sampled stacks establish system
accessibility, SwiftUI layout and XCTest snapshot contributions but not complete
wall-time attribution. Time-profile coverage stops before the original mapped
Capture phase, so its zero event count does not close performance acceptance.
See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch52-trace-attribution.md`.
Current-build device recording with verified coverage and clock alignment remains
required. No production repair or physical-device interaction follows from this
offline analysis.

Future comparisons have a current signed physical no-AX baseline and explicitly
separated UI phases. Instrument/XCTest overhead, limited sample duration and
blocked authentication constrain interpretation. Large raw traces remain local
with hashes; portable XML exports and screenshots remain in the report directory.

## Risks

- Instruments and XCTest add overhead; measurements are observed instrumented
  results, not production service-level guarantees or controlled benchmarks.
- Blocked authentication and host status UI differ from real production network
  and scene composition. Record both rather than extrapolate silently.

## Questions

- None. Physical performance is an existing acceptance gate.
