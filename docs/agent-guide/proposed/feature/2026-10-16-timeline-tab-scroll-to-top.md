# Timeline Tab Scroll To Top

## Problem

Selecting the already active Timeline button currently returns the same state. The user wants a smooth native scroll to its true top, including the initial date heading, with no visible Simulator stutter. Favorites navigation and Detail Back retention must remain intact.

## Proposal

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
- No real graphs, credentials, device installs, pushes or PRs; A5E and 0BA remain untouched. Coordinate GUI and Swift build windows with task-8's 1DCE owner.
- Report visual observations and available frame-time/hitch samples accurately. The user replaced strict >60fps with no obvious Simulator stutter; display-link callback frequency is not rendered FPS.

## Risks

- The native adapter now handles animated requests and observes pending tokens. Direct section targeting moved an already-top list by 22pt; direct UIScrollView targeting drifted under native self-sizing. Those experiments are removed. The built-in zero-height anchor passes the same physical UI regressions without geometry tracking or custom animation coordination.
- Section-edge scrolling through native ScrollViewReader needs physical layout verification, especially empty Today and attachment rows.
- The user approved the exact three-public-interface diff (Sentinel_38be01cf2ebc8191b4a7490da4fbab2a, replying to Sentinel_5ecaec6339c88191840ecb102de824e5). No Dune or spec directory edits are planned.
- Experimental host-restamped native objects remain cross_abi_validated=false.
- The host display reports 120Hz and Instruments exposes Animation Hitches, but these facts alone prove neither Simulator refresh rate nor actual rendering FPS.

## Current validation

- Integrated onto main 3a7a6e6004ac956322505991899f06e30d10e17c (PR87). The user-approved three-interface patch produces exactly the current .mli bytes; no Dune or spec directory edits.
- RED: empty and 1,200-row public Root_navigation cases fail because repeated selection emits no request. GREEN verifies fresh tokens, all terminal outcome fences, retained slots/demand, no item comparisons/notifications, unchanged Favorites transition and Capture token ownership. Existing Capture behavior retains its full content projection on genuine content changes.
- Final complete Dune run: 900 Alcotest cases and 87 custom PASS checks. Final source boundary check passes. Normal native UI: 2 cases, 0 failures (63.446s); first row stays at the original 164.67pt coordinate. Reduce Motion fixture: 1 case, 0 failures; forced flag true and actual system flag false.
- Normal builds contain all 30 shared production Swift files verbatim, and the native manifest verifies 318 source files plus the compiler and six borrowed dependency hashes. Locked LUI is clean at 4fdb9136026af7863a8d025133871e34864eace1. Probe objects remain cross_abi_validated=false.
- Isolated iPhone 13 Simulator 1446A493-492B-4F2D-974D-3AED9DA5C97B reports maximum refresh 60Hz. Instruments explicitly reports Hitches unsupported. XCTest returns only Scroll_DraggingAndDeceleration duration (three values: 2.599500, 2.583284, 2.566101 seconds); no hitch result is available. Debug display-link callback gaps are diagnostic and do not establish rendered FPS or rendered frame times.
- A matching Release app is built and source-verified. Final real-time manual/performance acceptance is currently blocked because Computer Use reports the Mac locked and automatic unlock failed. Manual input is paused, OS settings were not changed, and no no-visible-stutter guarantee is claimed. Resume after the user unlocks the Mac.
- Evidence, exact commands, source/native/build manifests, screenshots, movies and result bundles remain in the external task-9/evidence directory. A5E, 0BA and task-8's 1DCE were not operated on.

## Questions

None. The exact public-interface diff was explicitly approved by the user on 2026-10-16 with “允许”; parent delegation includes the approval reference. Implementation and synthetic testing remain authorized; publishing, phone installation and merging are outside scope.
