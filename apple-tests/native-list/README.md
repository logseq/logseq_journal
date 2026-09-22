# Native List checks

`python3 tool/test_swiftui_list.py` exercises application row-index projection and token-scoped scroll completion through public OCaml interfaces. It does not execute native geometry.

`JournalListViewportTests.swift` now verifies visible-row identity and accepted Capture scrolling through the public native List in the isolated fixture host. The retired viewport accumulator has no production owner; invalid ranges, empty dates, loading rows and terminal scroll outcomes are covered by the OCaml tests, while actual geometry remains in XCTest.

`JournalListNavigationAcceptance.swift` is the physical XCTest regression for
native detail-return UI retention. The original public OCaml route/timeline probe
preserved state for the reproduced scenarios; only the native row lifecycle
reproduced the loss. The final implementation retains the native List and removes
unused restoration state. Do not duplicate this regression in the reducer or worker suites.

Build the existing isolated full-runtime Release host following
`../warm-start/README.md`. Prepare a 500-root, zero-child encrypted graph with the
existing fixture generator. Copy its descriptor as `Documents/batch41-performance.json`
and its complete support directory as `Documents/batch41-support` into
`org.logseq.journal.warm-start-probe`. Keep the SQLite preparation connection open
while copying the committed WAL and SHM sidecars. Never use devicectl's
`--remove-existing-content` option. No production container is a test target.

For Favorites, generate a separate 100-root graph using the existing built-in `$$$favorites` page
and ordered membership blocks linking to its roots. Copy it as
`Documents/batch42-favorites-v2.json` and `Documents/batch42-favorites-support-v2`.
The batch 42 report retains the exact generator used. The Favorites test waits
for the asynchronous list load before scrolling.

Add this file to the existing DeviceAcceptance XCTest target, build for testing,
and run its four methods on the connected iPhone. Middle and final-root tests
are read-only. The Capture/lifecycle case inserts one uniquely named disposable
entry and checks the existing explicit scroll-to-top behavior. Retain screenshots and
read back the graph afterward to verify that only the expected uniquely named inserts were queued.

Batch 42 retains its exact target project path, commands, source, RED/GREEN
results and signed-binary hashes in the standardization test report. Use the
current host build rather than historical device installation state.

## List-owned date headers and floating controls

`JournalDateHeaderAcceptance.swift` checks native section pinning/push-off,
reverse and fast scrolling, Detail/Back position retention, row actions, Capture,
refresh, route-scoped toolbar visibility and floating Account/error controls.
Dates use `YYYY.MM.DD` and exist only as Native_list section headers. Review real
content underlap and date/control clearance in retained screenshots. Native List
reports full-width header accessibility bounds, not tight date glyph bounds.
Initial section spacing is native; alignment is asserted after reaching the pin line.

Use the isolated Release host with `--rows 8 --children 0 --history-days 4`.
Copy `valid.json` as `date-headers-final.json` and its complete `support-valid`
directory as `date-headers-final-support` into the test app Documents container.
Regenerate after midnight. Use `--application-only` to remove diagnostic chrome,
`--light-appearance` for normal-size and `--accessibility-size --dark-appearance`
for large-text acceptance. The error layout test uses `--auth-failure`, a host-only
failure of the real token request, to exercise production error feedback and details.
All graph mutations are confined to disposable fixture data.

`JournalScrollPerformance` uses the same bidirectional gesture sequence on both
Release binaries and the same fixture/device. It records native
`XCTOSSignpostMetric.scrollingAndDecelerationMetric` and `XCTHitchMetric(application:)`
with three measured iterations. These are native frame/hitch measurements;
XCTest wall-clock duration is not a performance proxy. Retain both result bundles,
binary/object hashes and metrics; avoid other device interaction during measurement.

Semantic dates, empty Today, midnight presentation, hidden-day restoration,
Capture projection and slot mapping are covered once at the public OCaml view
boundary. Native layout is not owned by the pure timeline reducer. Only control
cluster size is measured in the application chrome; no row/date frame tracking remains.
