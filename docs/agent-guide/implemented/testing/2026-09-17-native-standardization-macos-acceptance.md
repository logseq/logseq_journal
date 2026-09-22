# Native Standardization macOS Acceptance

## Problem

The user has taken the iPhone away and explicitly requested continued testing
on macOS. The current native standardization proposal still requires mutation,
outline, pagination and resource evidence. The existing encrypted warm-start
host uses the real Journal OCaml object and Swift native views with isolated
fixture storage, but its tiny graph cannot exercise a long list or child pages.

## Decision

Refresh the macOS native object and run the current production Swift view sources
in the existing isolated acceptance host. Extend its public fixture generator
with a bounded row-count argument and deterministic children/long multilingual
content. Add test-only native host configuration for readable window sizes and
public SwiftUI accessibility environments where applicable. Exercise real native
Capture/Append saving, status changes, timed deletion cancellation, navigation,
disclosure and pagination against disposable graph data.

Use observations from the actual process, native accessibility tree, rendered
screenshots and measured scrolling/resource usage. Record source/object hashes
and exact limits. macOS evidence verifies shared behavior; it does not close
remaining iPhone layout, UIKit gesture, keyboard or VoiceOver gates. Stop all
further physical-device commands while the phone is unavailable.

## Alternatives considered

### Keep testing the real account graph

Rejected: a disposable graph permits complete mutation and recovery validation
without changing the user's notes or requiring remote credentials.

### Treat macOS as iPhone visual acceptance

Rejected: AppKit and UIKit differ in native controls, sheets and accessibility.
Record platform-specific results explicitly.

### Add duplicate reducer regression tests for acceptance flows

Rejected: native acceptance verifies rendering and interaction. Existing public
reducer coverage remains authoritative for domain behavior. Any new bug follows
the production-owner reproduction rule before adding regression coverage.

## Acceptance criteria

- The host builds from the current native Journal object and current Swift views.
- Fixture data and secret storage are isolated; blocked authentication cannot
  prevent the latest local graph from opening.
- Bounded large graphs include stable root/child identities and long mixed-script
  text, generated through existing public storage interfaces.
- Actual native mutation, retained drafts, disclosure/pagination and scrolling
  outcomes are recorded with source hashes and explicit platform limits.
- iPhone-specific requirements remain open; no Dune or protected spec edits occur.

## Consequences

The bounded macOS acceptance work is complete. Batches 23–27 of the
[implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md)
record native Capture/Append saving and draft retention, status mutation, timed
child-deletion cancellation, 500-root scrolling, 135-child paging and disclosure,
large-subtree deletion, cache selection, Settings and Diagnostics. The latest
host uses the current native object and production Swift views; source hashes
identify each measured build. All fixture secrets remain memory-only and all
graphs remain isolated. Physical-device commands were not used.

Resource measurements find and verify a separate idle CPU repair: the system
Connecting ProgressView lowers a 500-root idle interval from 54.30% to 2.74% of
one core. Measured macOS Debug usage is not iPhone Release performance acceptance.
The final 81-block deletion and subsequent Capture survive a process restart;
cooperative shutdown completes after all native interactions. Background refresh
regressions remain exclusively at the authoritative pure runtime boundary.

This closes this macOS acceptance decision, not the broader iPhone proposal.
Physical keyboard/swipe/accessibility/layout/IME and iPhone performance remain
open. The blocked-authentication fixture cannot validate actual remote password
or authentication success, remote mutation acknowledgement, or distinct graph
switching. macOS list/form separator and AX recycling observations remain
platform limitations, not passed iPhone accessibility or divider-budget checks.

## Risks

- Large fixtures can expose performance or paging defects. Record reproducible
  inputs and fix the production owner rather than changing the acceptance oracle.
- Forced SwiftUI environment values are controlled host inputs, not proof of
  actual system preference propagation or spoken VoiceOver behavior.

## Questions

- None. The user explicitly authorized macOS testing; the previously approved
  standardization scope determines the required behaviors.
