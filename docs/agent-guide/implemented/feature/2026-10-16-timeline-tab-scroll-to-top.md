# Timeline Tab Scroll To Top

## Problem

Selecting the already active Timeline button currently returns the same state. The user wants a smooth native scroll to its true top, including the initial date heading, with no visible Simulator stutter. Favorites navigation and Detail Back retention must remain intact.

## Decision

Reuse Journal Timeline's token-scoped native scroll requests and SwiftUI List/ScrollViewReader. Distinguish a top-edge request from Capture's existing row request. Root_navigation emits top requests only for repeated Journals selection on the Timeline root. Keep content, demand windows and database requests intact. Native animation follows Reduce Motion. Observe each request token so repeated taps can target the same top edge. A hidden zero-height native List anchor is the target; plain Lists use zero minimum row height so the anchor does not add blank space. Scroll-only updates send a small command to the existing mounted LUI node, retaining native rows, child identities and indices.

Separate content equality from scroll command equality so command-only changes do not compare or notify every retained Timeline item. Preserve the mounted List, row identities and Capture's existing nonanimated row request.

## Alternatives considered

### Rebuild or reset the list

Rejected: it loses navigation and retained state, widens rendering work, and does not implement scrolling.

### Custom per-frame offset or row geometry coordination

Rejected: native scrolling and animation are already available. No custom coordination is authorized or necessary.

## Acceptance criteria

- Public owner tests fail first for a repeated Timeline selection and pass after implementation; cover empty content, repeated commands, superseded completions, existing Capture commands and retained content/demand.
- Normal synthetic Simulator UI covers long lists and attachments, repeated taps, taps during momentum, already-at-top, Favorites switching and Detail Back.
- Native Reduce Motion is honored; a fixture environment override may test code behavior but is reported separately from system-setting validation.
- No real graphs, credentials or phone installs; A5E and 0BA remain untouched. The user later authorized PR publication and a separate independent review. Coordinate GUI/build/measurement windows with active owners.
- Report visual observations and available frame-time/hitch samples accurately. The user replaced strict >60fps with no obvious Simulator stutter; display-link callback frequency is not rendered FPS.

## Consequences

- The native adapter now handles animated requests and observes pending tokens. Direct section targeting moved an already-top list by 22pt; direct UIScrollView targeting drifted under native self-sizing. Those experiments are removed. The built-in zero-height anchor passes the same physical UI regressions without geometry tracking or custom animation coordination.
- Section-edge scrolling through native ScrollViewReader needs physical layout verification, especially empty Today and attachment rows.
- The user approved the exact three-public-interface diff (Sentinel_38be01cf2ebc8191b4a7490da4fbab2a, replying to Sentinel_5ecaec6339c88191840ecb102de824e5). No Dune or spec directory edits are planned.
- Experimental host-restamped native objects remain cross_abi_validated=false.
- The host display reports 120Hz and Instruments exposes Animation Hitches, but these facts alone prove neither Simulator refresh rate nor actual rendering FPS.

## Current validation

**Visual smoothness acceptance FAILED. PR 89 is not ready to satisfy the user's no-obvious-stutter requirement.** Three final Release behavior cases pass (86.890s), including the future-date regression, and the final Reduce Motion getter fixture passes (17.136s). These functional passes do not override the visible motion failure.

Independent review found that a Top command incorrectly required Today to be the first section. A legal nonempty future+Today fixture first reproduces the native failure after a normal Journals tap (RED, 28.413s); the minimal fix targets the existing global anchor without that ordering guard (GREEN, 24.355s within the three-case run). A public pure-owner probe emits the valid Top command and retains the future first slot; only the native target guard executes the defect, so no duplicate pure regression injects an already incorrect native result.

The final minimal-fix Release binary has SHA-256 `426e8f8f188f1b35e91a5ecdf934a21bd93d4c491907ad82c4e69de0d18b0d45`; its recorded build manifest verifies all 30 shared production Swift files and the 318 unchanged native source files. The later equatable List-content experiment did not remove visible stepping and was reverted; it is excluded from the delivered source.

Original, unresampled frames of two new short recordings were inspected in chronological order. They show intermediate text positions holding for several frames, followed by large jumps to earlier rows and the top. The second recording made no AX-tree or screenshot requests during the animation; its major glyph-position changes occurred at video PTS 8.051667, 8.133333, 8.231667, 8.310000 and 8.343333 seconds (up to 98.334ms between these picture changes). Its callback intervals in the click window have median 16.666ms, p95 19.338ms and maximum 389.937ms. This is visible stepping evidence and callback-delivery evidence, not rendered FPS or compositor hitch measurement. A first short recording, with a post-click UI observation, has a maximum callback gap of 379.563ms; it is retained as a potentially observer-affected comparison. The earlier 505.367ms gap is confirmed inside the return operation, from click+0.153s to +0.658s, rather than at a navigation boundary.

A separate 15-second sample of only the synthetic process shows native collection cell creation/self-sizing, SwiftUI layout and AX work during the diagnostic window. It also contains long idle portions; aggregated stacks have no per-sample timestamps and cannot identify the cause of the exact callback gap. No full-row rebuild, DB amplification, framework defect or particular causal bottleneck is asserted from this sample. Further native coordination is not implemented: AGENTS.md requires explaining the native limitation and explicit approval before custom UI coordination. Current SwiftUI ScrollViewReader+List and the reverted content-boundary experiment failed this scene; this does not prove every standard native approach is insufficient or that a custom adapter will solve it.

- Integrated onto main fc27cfd6 (PR87 and PR88). The approved three-interface patch still produces exactly the current .mli bytes; no Dune or spec directory edits.
- RED: empty and 1,200-row public Root_navigation cases fail because repeated selection emits no request. GREEN verifies fresh tokens, terminal outcome fences, retained slots/demand, no item comparisons/notifications, unchanged Favorites transition and Capture token ownership. Existing Capture behavior retains its full content projection on genuine content changes.
- Final complete Dune build includes @all and app/native_embed.exe.o. Final full rerun passes 900 Alcotest cases and 87 custom PASS checks, including source-boundary checks. The initial sandboxed rerun was interrupted after loopback fixture bind failed with EPERM; the complete rerun with authorized local fixture ports exits 0.
- Release native UI: 2 cases, 0 failures (62.760s). The current cross-day fixture has empty Today plus yesterday's long image list; the initial first-row coordinate is 257pt and is retained after top requests. Detail Back retains the scrolled row coordinate, and Favorites switching keeps its existing navigation semantics.
- A separate normal Computer Use three-tap sequence starts while passive samples of the same native collection report decelerating=true and changing offsets (725pt immediately before the click call). The list then settles at the true top (-47pt), retaining the same collection identity. XCTest swipe-followed-by-tap alone is not treated as momentum evidence.
- Reduce Motion fixture: 1 case, 0 failures (17.060s). The exact getter override forces the no-animation branch; metadata records forcedReduceMotion=true and systemReduceMotion=false. OS preferences were not changed. This Debug fixture is separate from the normal production-Swift Release acceptance.
- The final Release host contains all 30 shared production Swift files verbatim; the earlier Debug host remains historical evidence. Native provenance verifies 318 source files plus the compiler and six borrowed dependency artifact hashes. Locked LUI is clean at 4fdb9136026af7863a8d025133871e34864eace1. Existing build/cache inputs were reused, without changing global pins. Probe objects remain cross_abi_validated=false and are not full iOS cross-compilation proof.
- The isolated iPhone 13 Simulator 1446A493-492B-4F2D-974D-3AED9DA5C97B reports maximum refresh 60Hz. Instruments reports Hitches unsupported; XCTest supplies no hitch values. Release Scroll_DraggingAndDeceleration durations are 2.549989, 2.583294 and 2.549919 seconds (mean 2.561s), which are gesture durations rather than frame times.
- Across the four Release performance tap windows, display-link callback medians are about 16.67ms, p95 19.35–22.75ms, and maximum gaps 163.75–505.37ms, including boundary intervals. The independent active-scroll three-tap window has median 16.67ms, p95 30.04ms and maximum 79.15ms. These are main-thread callback delivery intervals, not rendered-frame times or rendered FPS. No zero-hitch or >60FPS claim is made.
- Earlier native pictures show the complete top and no blank/reset list; the later short original recordings demonstrate visible stepping, so smoothness is explicitly not accepted. A long recording has a decoded timestamp discontinuity, so its resampled contact sheets and average video rate cannot establish rendering cadence. Actual rendered frame times, rendered FPS and compositor hitches remain unavailable on this setup.
- Commands, source/native/build manifests, passive samples, screenshots, movies and result bundles remain in the external task-9/evidence directory. A5E, 0BA, task-8's 1DCE and the Favorites task's A135 were not operated on. GUI/build/measurement windows were coordinated and released. No phone installation or merge is part of this change.

## Questions

None. The exact public-interface diff was explicitly approved by the user on 2026-10-16 with “允许”; parent delegation includes the approval reference. The user subsequently authorized publishing a PR and an independent review session after validation. Phone installation and merging remain outside scope.
