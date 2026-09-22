# Use System Sync Progress

## Problem

The real macOS Debug host continues expensive SwiftUI layout while an offline
encrypted graph is idle and Connecting remains visible. With 500 roots loaded,
a 29-second interval consumes 54.3% of one CPU core. A separate first-page run
uses 21.1%, becomes 0.3% with the controlled scene inactive, and rises to 60.7%
after reactivation. These are CPU-time deltas, not UI automation timings.

Stack sampling includes repeated layout and the SDK's custom animated progress
style. This implicates an active native presentation path, but does not yet prove
that the spinner is the cause. The journal header supplies a custom-rendered
progress child instead of allowing its native SwiftUI owner to select the system
control. The design already requires appropriate built-in controls.

## Decision

Replace only the Connecting indicator with SwiftUI's built-in ProgressView.
Journal_header continues to supply the
Connecting label and authoritative syncing property. JournalChrome presents that
label inside the system control. Remove the obsolete nested progress widget.

The public OCaml state is stable during the offending idle interval; no domain
events or completions reproduce native animation/layout work. The missing owner
boundary is SwiftUI presentation. Use the existing real native host and process
sampler as the narrow execution check, without copying production view logic or
adding duplicate reducer/transport tests. Before/after measurements establish
the improvement; native status and cooperative shutdown remain usable.

## Alternatives considered

### Disable animation or hide Connecting

Rejected: the sync state still requires visible indeterminate feedback. A
controlled inactive scene is diagnostic evidence, not a production fix.

### Change every SDK progress widget

Deferred: that expands the change beyond the measured journal header and changes
determinate circular/linear semantics. First isolate the native sync indicator.

## Acceptance criteria

- Same-host active idle CPU decreases below 10% of one core over at least 20
  seconds on the initial page, including after inactive/active reactivation.
- The actual native Connecting indicator and label remain visible and accessible.
- Pagination to root 500 and cooperative shutdown still work.
- Existing header/application checks and macOS/iPhoneOS builds pass.
- Record Debug/macOS and physical-device limits; do not infer iPhone acceptance.

## Consequences

The comparison passes. JournalChrome now renders the Connecting child as the
label of the built-in ProgressView with small control sizing. Journal_header
supplies text rather than a redundant custom progress subtree. No SDK progress
APIs or other progress presentations change.

## Risks

- The high CPU may originate elsewhere in the native tree. Do not retain an
  unproven performance claim if the system-control comparison fails.
- Native platform progress appearance differs from the previous custom style.

## Questions

- None. This is a measured implementation investigation within the authorized
  native-control standardization and macOS acceptance scope.

## Implementation evidence

The same Debug host and isolated 500-root fixture show the following interval
CPU usage as a percentage of one core: initial page 21.12% to 2.02%, after
inactive/active reactivation 60.72% to 2.50%, and all 500 roots loaded 54.30% to
2.74%. Candidate intervals last 24.2, 25.2 and 25.2 seconds respectively. The
Connecting busy indicator retains its native accessibility description. Native
pagination reaches root 500 and cooperative shutdown completes normally.

The existing macOS regression suites, macOS native/host builds and complete
unsigned iPhoneOS Release build pass. No Dune, protected spec or SDK source edits
were made. The fixture gains a public scene-phase checkbox and usage notes; the
attempt to inject read-only Reduce Motion was removed after compiler rejection.
The [batch 26 ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md)
contains raw CPU samples, before/after stack archives, source hashes and limits.
This is a measured idle CPU repair, not iPhone performance or frame-rate proof.
