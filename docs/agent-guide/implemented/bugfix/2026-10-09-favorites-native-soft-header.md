# Let Favorites content show through its soft header

## Problem and ownership

Favorites and Timeline both requested a soft top scroll edge, but Favorites
placed its title and account controls in a plain safe-area inset with a full-width
bar-material background. Actual iOS 26.1 scrolling showed a distinct background
band covering the Favorites rows, while Timeline showed softened content behind
its pinned date and account controls.

Application's public route reducer owns selection and Favorites data, not Apple's
scroll-edge rendering. Reducer events and completions cannot reproduce this
visual defect. The regression belongs at the native UI boundary, using normal
XCTest swipes, short drags, screenshots, and menu taps against an offline synthetic
service running the current production Application, renderer and Swift views.

## Decision

Use the native safeAreaBar for the Favorites title and controls, and remove the
extra bar-material background. Keep the explicit soft top effect, transparent
retained navigation host, title accessibility, native controls, and minimum header
height. Timeline's absent title leaves the new bar empty. No per-row geometry,
custom scrolling, hard mask, opaque cover, new dependency or deployment change is
needed.

Removing only the material, or using an ordinary overlay, lets sharp row text
overlap the title. Both candidates were rejected by actual screenshot inspection.
The native bar registers its content with the system scroll-edge treatment.

## Validation and workflow

The external UI regression compares changing pixels beneath the top chrome with
the actual Timeline reference, checks that content remains visible and softened,
and verifies fixed readable title geometry and the Account menu after real
scrolling. It also covers AXXXL populated and empty Favorites. Existing public
Application navigation/header and renderer semantics regressions cover their
unchanged state and event owners. Production Swift compilation includes App.swift.
Screenshots, synthetic data, runner, measurements and result bundles remain in the
task's external evidence directory.

spec-dev-tool is unavailable in this execution environment. No Dune or spec files
are changed. Physical-device installation, real graph/account operations and merge
are outside this task.
