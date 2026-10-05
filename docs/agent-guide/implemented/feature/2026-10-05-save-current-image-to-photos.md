# Save the current preview image to Photos

## Problem

The user requested an explicit Save action in image previews and confirmed the destination is the photo library. The existing system Share menu does not expose Save Image reliably.

## Proposal

Add a visible native Save to Photos action to Journal's iOS image preview, including single images. Resolve the selected URL from QuickLook's current index when the action is pressed. Use Photos add-only authorization and NSPhotoLibraryAddUsageDescription; do not request read/write access, inspect the library, or export PDFs/documents.

A Swift save owner fences repeated taps and stale authorization/completion callbacks. It stages an exact byte copy of the selected image into a private temporary file lease before any asynchronous permission or Photos operation. This independent lease survives row/graph retirement and is released after completion. Closing before authorization prevents a late write; an already admitted Photos transaction is non-cancellable and finishes with its private file retained, suppressing feedback into a closed preview. The original file, dimensions and bytes are unchanged.

Use a system navigation bar and localized native button/alerts. Keep QuickLook's native image pager and zoom. Because child QuickLook does not own the wrapper navigation item, retain sharing through a native action button and UIActivityViewController for the current URL. Denied/restricted access and save/staging failures produce actionable feedback while the preview remains alive. The permission dialog itself is not accepted by the agent without separate test-environment scope.

## Decision

Implement the user-confirmed Photos destination in Journal only. The pure Swift owner owns authorization/completion races and staged-file lifetime; the mounted OCaml boundary owns single-image versus document routing. The existing platform APIs and shared LUI are unchanged.

## Alternatives considered

### Depend on Share's Save Image action

Rejected: native synthetic inspection found Save to Files but no Save Image.

### Hold the row's original reference through a graph switch

Rejected: graph retirement invalidates that owner. An operation-owned exact temporary file is independent of row and graph lifetimes, without importing earlier unpublished cache fixes.

## Acceptance criteria

- Public Swift save-owner tests cover authorized/not-determined/denied/restricted, current URL snapshot, repeated taps, write failures, close-before-permission and close-during-write, lease cleanup and stale/duplicate callbacks.
- Mounted media tests prove both single and multiple images use the Journal preview and documents retain generic file preview.
- Native staging tests compare raw bytes and dimensions and reject non-images; native compilation validates add-only Photos calls and usage declaration.
- Build a synthetic Simulator fixture without personal graph or image data. Actual OS permission approval and Photos writes require explicit test scope; no unauthorized input tools are used.

## Consequences

Deterministic save-owner tests passed for permission states, duplicate taps/callbacks, selected-source snapshot, failures and closure during authorization/write. Native ImageIO tests verify exact raw bytes, preserved 37×19 dimensions, detected type despite a cache extension, source deletion independence and cleanup. A nonimage posing as PNG is rejected. Restricted-shell ImageIO could not inspect generated files; the same tests passed with the permitted native subprocess environment. The mounted single-image regression failed on the old generic-preview path, then passed after images adopted the Journal extension.

All production iOS Swift sources compile with the existing dependency cache. The synthetic Simulator app links/signs and runs native controller assertions for selected URL (initial second image and changed third index), Save navigation item and add-only declaration. Actual GUI visibility/paging, OS permission approval and real Photos writes are not claimed because CUA is unavailable and no OS approval was given. The complete suite passes serially: 21 Alcotest suites, 560 cases and standalone boundary/semantic checks. Application has 58 passing cases after adapting its existing nine single-preview lifetime scenarios to the new public extension event. An untouched WebSocket frame-count test intermittently raised End_of_file in the parallel run; isolated and full serial retries pass, with failure evidence retained. Builds, changed-file formatting and changed decisions pass; existing repository formatting and one older decision validation issue remain documented in Gitignored reports.

## Risks

- Photos transactions already admitted cannot be cancelled; closing the UI suppresses alerts and keeps the staged source alive through completion.
- Original-preview forced teardown limitations remain separate from the operation-owned save file.
- The current environment has no callable CUA tool. Visible GUI and real permission/write acceptance may remain blocked; compiled synthetic controller assertions and public owner regressions are recorded separately.

## Questions

None for implementation: the user explicitly selected the photo library. Accepting an OS permission dialog in the disposable fixture, if needed, requires separate test scope.
