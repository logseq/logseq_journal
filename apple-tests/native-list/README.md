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


## Timeline top scroll-edge regression

`JournalTopEdgeEffectAcceptance.swift` drives the isolated full Application
(`org.logseq.journal.pr47-application-fixture`, `timeline-images.json`, memory
keys) with public XCTest taps and drags. Use an iPhone 13 / iOS 26.1 fixture for
the fixed coordinates. It covers repeated native Back at the top, scrolled text,
images under the date/account glass, edge-back cancellation/completion, shared Favorites/Timeline chrome navigation, actual account-menu taps, and
rotation back to portrait, and the current inline Capture composer above the actual software keyboard (TextField, trash and button.send identifiers).
Native render/compositing is outside the public pure OCaml route reducer; the
retained Timeline state and List identity remain correct in the reproduced case.
This regression therefore belongs at the narrow native Application UI boundary.

The XCTest navigation assertions alone cannot detect the short blur interruption:
record the Simulator during `testTextBack`, then run
`python3 apple-tests/native-list/check_top_edge_video.py --video <recording.mov> --trace <passive-frame-log.jsonl>`. The diagnostic host's Git-external frame log
reads public collection identity, contentOffset and adjustedContentInset without
injecting events or adding a view. The oracle checks the 646-point scrolled
fixture, stable normal-area glyphs and the top glyphs that should stay blurred.
It fails for the original automatic/explicit-soft controls; a hard-edge control
passed, but changes the visual style. The validated soft candidate retains an
empty transparent native navigation bar and uses the outer container safe area;
its repeated native Back recording has zero sharp top frames. Inspect retained image and interactive-transition frames too;
after-return screenshots alone do not establish absence of the transient.
Keep hard only as a diagnostic control: it changes the cutoff/divider and is not
an accepted replacement for the requested soft design.

The final main-aligned acceptance uses main `efb97631d9f1814803abe814bd3305fc6d17b8ae`, its complete current OCaml object, freshly rebuilt LUI Swift `adbdf63`, and the real locked Amplify/AWS dependencies. The real App.swift host compiles/links separately; UI operations use the synthetic offline scene with the same production host/chrome. Production contains no fixture controls or frame probe.

The Git-external runner also toggles an outer sign-in notice with exactly the production App.swift safeAreaInset shape. This verifies insertion/removal and native Back geometry; it does not claim to execute a real account authentication failure. That fixture-only method is not part of this repository test file.

The current-main unmodified control reproduces 17 sharp top frames in 348 matching normal-content frames across two native Back operations; the coherent soft candidate has zero in 301. Final image/top/menu/rotation/preview and software-keyboard acceptance also pass. With the outer notice and no diagnostic overlay, the collection container reports isHittable=false before and after navigation while actual menu taps and a second Detail navigation from root text succeed. This container flag alone is not an acceptance criterion for those fixture controls.
