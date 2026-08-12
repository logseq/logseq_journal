# Journal Timeline UI Acceptance Report

Date: 2026-08-10  
Environment: Apple Silicon macOS 26.5.2, Xcode 26.1.1, Flutter 3.44.8

This report records the acceptance evidence gathered for
`005-journal-timeline-ui.md`. A passing automated check is not treated as
evidence for a physical-device or assistive-technology check.

## Automated evidence

### Project behavior and ownership

- `opam exec -- dune runtest` passed.
- The durable 10,000-record Worker corpus passed with 67 retained rolling
  slots, 40 supplied rows, a 17,454-byte response payload, and a 6 ms cold
  query in this run.
- The separate 50,000-row synthetic sparse-list stress sequence passed.
- The source-boundary suite passed after removing the obsolete Search/Mail
  test paths and now scans every OCaml product source file.
- `flutter analyze --no-pub` passed with no issues.
- The OCaml application-view suite proves that the initial Feed state is a
  live-region `Loading journal` surface and never a false empty state.
- The real compiled-OCaml runtime golden passed twice.
- The complete macOS runtime integration suite passed twice. It exercised
  empty, Detail-loading, and error states, Capture, dirty cancellation, task
  mutation, Detail editing, direct-child creation, disclosure, route return,
  adaptive widths, a 34-point safe bottom, 2.0 text scale, dark mode, high
  contrast, reduced motion, frame size, mounted-node count, frame durations,
  and resident memory budgets. The Detail-loading assertion records the
  compiled runtime patch before the Worker read begins.
- A macOS disclosure regression was reproduced in the timeline state machine:
  collapsing a parent while its direct-child request was in flight removed the
  loading slot, but the matching response could not replace that slot and left
  the request pending forever. The new regression test failed before the fix,
  then passed after matching responses were changed to release `pending` even
  when the disclosure remains collapsed. It also proves that stale responses
  cannot clear a newer request and that re-expansion schedules a fresh request.
- The full compiled-runtime child flow passed after the fix. It creates a
  direct child, returns to Timeline, expands the parent, and observes the child
  source instead of an indefinite loading row.
- The debug integration guard uses a 75 ms frame budget so that the cold first
  Flutter `TextField` construction remains measurable without being presented
  as a release/profile device result.
- Five independent compiled-runtime locale cases prove that the centered Today
  context remains centered while the independent Capture target uses logical
  start for `ar-SA`, `fa-IR`, `he-IL`, and `ur-PK`, and returns to logical end
  for `en-US`. Each case advances beyond the initial environment frame before
  measuring the final OCaml-owned layout.

### Pinned renderer evidence

Ninety-eight relevant tests from the resolved `bonsai_flutter` dependency
passed without modifying the dependency. They cover the application platform
bridge, runtime root lifecycle, environment reporting, host adapter, native
resource disposal, navigation, Pressable behavior, text input, finite viewport
constraints, 50,000-row sparse virtualization, semantics, and core rendering.
The two dependency tests whose fixture paths exist only in the upstream source
checkout were excluded from the resolved-mirror command; their cross-language
frame and event boundaries are exercised by the project real-runtime golden and
integration suites.

### Generator and toolchain evidence

- `opam exec -- bonsai-flutter sync-project --check` passed.
- `opam exec -- bonsai-flutter sync-host --check` passed.
- `opam exec -- bonsai-flutter doctor --target=macos` passed.
- `opam exec -- bonsai-flutter doctor --target=iphoneos` passed.
- `/Users/rcmerci/gh-repos/bonsai_flutter` remained unchanged.

### Build and launch evidence

- Debug macOS and unsigned debug iPhoneOS builds passed.
- Release macOS and unsigned release iPhoneOS builds passed.
- A macOS profile build passed after the final RTL layout change.
- The release iPhoneOS bundle passed arm64, minimum iOS 15.0, Mach-O, and
  application-bundle verification.
- A signed release build was installed and launched on a connected iPhone 13
  running iOS 26.6. Xcode automatically used development team `K378MFWK59`.
  The installed `0.1.0` app was present under the expected bundle identifier,
  and a terminate-and-relaunch smoke test replaced device process `74066` with
  process `74069`.
- A signed physical-device Profile bundle was also built and verified for
  arm64 and minimum iOS 15.0 without replacing the running Release app. Profile
  installation and trace capture remain pending until the manual Release input
  and persistence check is complete.
- The physical-device application container contained the new bounded store at
  `Library/Application Support/logseq_journal/store.sqlite3` after startup.
  Only file metadata was inspected; no journal database content was copied or
  read. The device had no current crash report for this launch.
- A manual device mutation increased `store.sqlite3` from 12 KB to 20 KB and
  updated its modification time. A terminate-and-relaunch then replaced device
  process `74069` with process `74076`, while the same 20 KB store remained in
  the application container. This proves file-level post-mutation persistence;
  visible row-content confirmation remains manual.
- A new release macOS application instance launched successfully. Only the
  instance created for the smoke test was terminated afterward.
- A cold-started release macOS window was inspected through the native UI. It
  displayed the current `2026-08-10` Today context, truthful empty state, and
  Capture control. The retained screenshot is
  `logseq-journal-macos-release-cold-start.png`.
- The final rebuilt release window was inspected after the RTL change. Its
  native accessibility tree exposed Menu, Today/date, More, the empty-state
  text, and Capture. The window retained the centered Today context and
  lower-trailing Capture target without clipping. The retained screenshot is
  `logseq-journal-macos-release-final.png`.
- Capture was activated through its native accessibility action. The real
  release route exposed Cancel, New entry, Save, task state, and the focused
  text field, then returned to the timeline through Cancel without writing a
  record. The retained screenshot is
  `logseq-journal-macos-release-capture.png`.
- The final release application was rebuilt after the disclosure fix and
  launched against the existing macOS application container without deleting
  or replacing its store. The native accessibility tree exposed the persisted
  `xxx` row and `Show 1 child blocks for xxx` in the collapsed state. The
  automation bridge did not activate this Flutter disclosure through its AX
  click action, so this particular real-store click remains manual rather than
  being inferred from the integration result.

## Evidence not yet available

A physical iPhone later became reachable and completed the signed Release
installation, launch, file-level mutation, and process-restart checks recorded
above. The following release gates remain unverified:

- physical-iPhone visible row-content confirmation after process restart;
- Chinese and Japanese IME composition, selection, paste, undo, rapid edits,
  backgrounding, and route restoration on device;
- VoiceOver headings, checked state, full-source labels, disclosure wording,
  single stable disclosure focus target, reading order, hit regions, and focus
  restoration;
- physical-device Dynamic Type, safe-area, dark-mode, high-contrast, and
  reduced-motion acceptance;
- physical iPhone release/profile traces for fast fling, mutation, expansion,
  route return, frame timing, and memory;
- manual macOS keyboard-only, VoiceOver, adaptive-window, persistence, and
  profile acceptance.

The final release window did not advance focus after a plain Tab key because
macOS full-keyboard control navigation is not enabled in the current user
session. That setting was not changed, and keyboard-only acceptance remains
open rather than being inferred from the native accessibility tree.

These checks must remain open until they are executed on the stated hardware
and accessibility environments.

## Task completion audit

| Tasks | Status | Evidence or remaining boundary |
| --- | --- | --- |
| 1–22 | Complete | Ownership, obsolete-path removal, model, time, clean store, repository, Worker, platform, tokens, header, rows, semantics, and bounded timeline are implemented and covered by the full suites. |
| 23–24 | Complete except the explicitly deferred date-selection semantics | Capture, Detail, mutation, conflict, recovery, anchor, and route behavior pass; the date surface remains the intentionally deferred cancel-only shell. |
| 25–26 | Explicitly deferred | Menu and More product definitions were excluded by user direction. |
| 27–29 | Automated implementation complete | Semantics, adaptive profiles, truthful states, RTL layout, real-runtime golden, and complete integration suites pass. Manual assistive-technology acceptance remains under Task 31. |
| 30 | Automated, macOS build, and physical release-launch evidence complete; device trace incomplete | The 10,000-record release corpus, 50,000-row stress case, bounded slots/rows, runtime measurements, release builds, macOS profile build, and signed physical-iPhone release launch pass. A physical-iPhone profile trace is unavailable. |
| 31 | Incomplete | Signed physical-iPhone installation, launch, post-mutation file persistence, and process restart pass, and a release macOS empty-state window was inspected. Visible row confirmation plus the remaining IME, VoiceOver, keyboard, adaptive-mode, and profile matrices still require manual hardware runs. |
| 32 | Automated repository gates complete; final device-dependent result open | Project and dependency tests, ownership searches, source boundary, generators, analysis, doctors, builds, upstream cleanliness, and intentional-diff inspection pass. Its final expected result still depends on Task 31. |

## Intentionally deferred product decisions

The exact Menu and More item sets, ordering, labels, enabled states, and
destinations remain unconfirmed. The current OCaml-owned controls intentionally
stop at their tested shells, as required by Tasks 25 and 26. Date-selection
semantics beyond its current cancel-only shell are also deferred. These two
areas were explicitly excluded from this implementation pass; no placeholder
or future capability has been added.
