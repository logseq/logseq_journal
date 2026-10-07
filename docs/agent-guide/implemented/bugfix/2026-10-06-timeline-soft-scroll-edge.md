# Retain the native host for Timeline's soft scroll edge

## Problem

On iPhone 13 / iOS 26.1, returning from Block Detail with native Back briefly sharpens Timeline content under the date/account glass. Repeated recordings of the real synthetic Application reproduce it with text and images. The native collection, hosting cells, offset, inset and content size remain stable, and the retained root List body does not rerun during the reproduced return. Ordinary content outside the top glass stays in place.

## Decision

Keep FloatingChrome's native navigation bar host visible with a hidden background, and explicitly request the soft top scroll edge. Capture the outer container's top safe area before the descendant NavigationStack adds its bar, then apply that inset to floating pages with native safeAreaPadding and ignoresSafeArea(.container, .top). Keep native Back and interactive navigation. Use no negative padding, fixed bar height, timer, row measurements, production collection scans, opaque cover, or LUI changes.

JournalRuntimeHost centers its opening placeholder within the new iOS GeometryReader. The macOS runtime content path stays outside that wrapper. Minimum deployment is iOS/macOS 26.0; full macOS execution is not covered by this Simulator work.

## Ownership and evidence

The public OCaml route owner retains the Timeline model correctly and does not execute Apple's native scroll-edge rendering. Its events/completions cannot reproduce the visual defect. An Apple-SDK-only NavigationStack/List program reproduces the same soft flash twice, including without Journal's floating controls. Hiding only Detail's bar background, explicit soft, a white List background and compositingGroup do not fix it. Retaining the transparent host does, including matched-content-offset controls. The regression therefore belongs at the narrow native Application UI boundary, with ordinary XCTest inputs and a Git-external passive video/frame observer.

Evidence supports the native hidden-to-visible navigation-bar/soft-edge transition as the trigger. No private filter or render-server API was inspected, so the exact Apple snapshot/filter step remains unproven. The effect view itself stays enabled with alpha 1; do not describe this as destruction of the whole List or the effect view.

## Validation

The isolated worktree is aligned to main efb97631d9f1814803abe814bd3305fc6d17b8ae. Its tree equals the original clean PR49 head 533b67f. The final real App.swift host compiles and links all current Swift, a complete current OCaml object, freshly rebuilt LUI Swift adbdf63, and actual Amplify/AWS objects matching all 30 Package.resolved pins. The offline synthetic scene exercises the same production chrome/runtime with that coherent dependency set.

The unchanged transport44 WebSocket aggregate first encountered End_of_file. Its narrow retry and a justified full retry pass; the latter passes 21 suites / 563 cases. No transport source changed. With identical current-main core/LUI/dependencies, the unmodified-main control reproduces 17 sharp top frames across two native Back operations (348 same-position normal-content frames); the soft candidate yields 301 same-position normal-content frames with zero sharp top frames. Actual short edge drag cancels and long edge drag completes; 196 matching root frames remain blurred. All ten final native acceptance cases pass, including images/top/menu/rotation/preview, the actual inline composer above the software keyboard, and parent top-notice geometry. A notice with no diagnostic overlay reports collection isHittable=false both before and after navigation, while actual account-menu taps and a second Detail navigation from root text succeed; the earlier container assertion did not demonstrate an interaction regression. Exact results and binary/object hashes are retained in docs/test-reports/top-edge-20261006/report.md and the external evidence directory.

Independent review found no material production-source blocker. Its opening-placeholder and Back-assertion suggestions were applied. The retained soft gradient tail changes from about 148.13 to 155.8 points, approximately 7.67 points longer, while original date/account/content positions and 47-point root top inset are retained. Pixel-identical gradient output is not claimed.

## Workflow and limits

spec-dev-tool is unavailable in this execution environment; this decision follows the repository document shape without claiming that tool ran successfully. No push, PR, merge, Library upload, phone installation, real graph/account operation, LUI upgrade, Dune edit or OCaml spec change is part of this local fix. Physical-device and other-OS acceptance remain unperformed.

## Publication dependency correction (2026-10-07)

After authorization to publish ready PR50, its first CI resolved the floating LUI main reference to 33b6908946f80954bf6a9175e14174ec6105abb0. That revision is 71 commits beyond the validated adbdf63 and removes FlutterHost (upstream removal b3a0ff314baf07ac856844919522afea95ad740a); the unchanged application.ml host-code mapping therefore fails to compile before tests run. The actual uploaded dependencies.json and protocol source establish dependency/API drift rather than a Swift soft-edge regression.

Pin only LUI in logseq_journal.opam and logseq_journal.opam.locked to the already validated adbdf63fe940157824f29262095bb194ebd21404. Keep the existing host protocol, Swift source, Dune files and other dependencies unchanged. This also affects other branches based on the same main; use this one correction rather than independently adapting them to Kotlin/GPUI. The historical opam provenance67ea3e8 and adbdf63 differ only in seven Apple/Flutter files, so the previously validated OCaml sources match this compatible pin. Fresh CI on the corrected PR head remains necessary; old test results are not represented as testing the failed upstream33b6908.
