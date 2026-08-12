# Journal Reference Alignment Acceptance Report

Status: Implementation and automated acceptance complete for the activated product scope; physical-device and assistive-technology acceptance remains partial.

Date: 2026-08-10

Primary document: `docs/agent-guide/006-journal-reference-alignment.md`

## Scope conclusion

The activated reference-alignment scope is implemented:

- Menu and More are visual-only shells with no semantics, focus, handler, route, drawer, action surface, or placeholder behavior.
- Tags retain literal canonical source. The future color policy is a stable deterministic hash over a fixed accessible palette, but styling remains deferred behind FG-1.
- Storage remains app-private and does not connect to a real Logseq graph.
- Timeline content is centered at a maximum width of `720` logical pixels; narrower layouts remain edge-to-edge.
- The project adopts `bonsai_flutter` commit `6f52ea79539ed0e115bac5991ab2db8f176dc88d`, including application-response delivery, generated-host integration dependency, profile-aware execution, and runtime Material icon retention fixes.
- The implementation golden now uses deterministic iPhone-style top and bottom safe areas and preserves the screenshot's hierarchy, spacing, typography, near-white surfaces, muted secondary color, row rhythm, fixed time column, and floating Capture treatment without adding deferred features.

Release acceptance is not granted because physical-device and assistive-technology evidence remains open. The former native-artifact profile, complete macOS integration, reference-raster availability, and iOS runtime-icon blockers are resolved.

## Task completion audit

| Plan item | Status | Completion evidence or authorized outcome |
| --- | --- | --- |
| Task 1: Baseline | Complete | The pre-existing dirty worktree was recorded and preserved; the reference hash, OCaml baseline, Flutter baseline, and clean dependency checkout were verified. |
| Task 2: Product decisions | Complete | Menu and More remain visual-only; tag colors use a future deterministic hash; storage remains app-private; and the timeline is centered at a `720`-logical-pixel maximum width. |
| Dependency adoption prerequisite | Complete | Project and active opam pins resolve to `6f52ea79539ed0e115bac5991ab2db8f176dc88d`; generator sync, application responses, generated integration dependencies, profile-aware execution, and icon retention pass. |
| Task 3: Reference fixture | Complete | The private temporary fixture contains six Today rows, four previous-day rows, three second-previous-day rows, one direct child, and every currently expressible reference variant. |
| Task 4: Header and overlay RED contract | Complete | The required failing logical-view, adaptive, and semantics assertions were observed before the minimum production changes; the focused suites now pass. |
| Task 5: Runtime-golden RED contract | Complete | The compiled runtime failed the new hierarchy and geometry contract before implementation; the approved checked-in golden now passes without update mode. |
| Task 6: Visual tokens | Complete | Palette-aware header, badge, task, divider, FAB, target, inset, and elevation contracts pass adaptive tests. |
| Task 7: Header composition | Complete | Real icons, independently centered view-only date, trailing indicator, divider, and noninteractive Menu and More shells pass logical, semantic, runtime, and visual tests. |
| Task 8: Localized dates | Complete | Generation-fenced OCaml state and compact Swift formatters pass OCaml, macOS Swift, and real-runtime tests; the obsolete date route is absent. |
| Task 9: Row anatomy | Complete | Conditional task space, filled Done state, independent task and disclosure actions, fixed time column, and adaptive profiles pass semantics and geometry tests. |
| Task 10: Capture overlay | Complete | Capture is an OCaml-owned body overlay with separate visual and semantic sizes, RTL mirroring, safe-bottom clearance, and final-row reachability. |
| Task 11: Wide layout | Complete | Automated widths `320`, `719.5`, `720`, `744`, and `1200`, plus live narrow and wide macOS windows, verify the centered content cap. |
| Task 12: Menu and More boundary | Complete | No handlers, semantics actions, focus targets, routes, drawers, action surfaces, placeholder items, or Dart behavior exist. |
| Task 13: FG-1 audit | Complete gate audit | The resolved public API and renderer were inspected, and the dependency core-surface suite passed. Independently styled spans with embedded controls, ellipsis, semantic order, and bounded layout remain unavailable, so the plan requires stopping this phase. |
| Task 14: Derived inline tokens | Not activated by FG-1 | The plan explicitly forbids application token work until Task 13 passes the capability gate. Canonical tag-like and mention-like source therefore remains literal and byte-identical. |
| Task 15: Golden approval | Complete | The real-runtime image was approved through leading- and trailing-aligned normalized overlays and then passed a clean non-update rerun. |
| Task 16: Native and assistive QA | Partial and explicitly open | Native macOS Timeline, Detail, Capture, narrow, reference, and wide-window flows were inspected. Physical iPhone, keyboard-only with Full Keyboard Access, VoiceOver, IME, and device lifecycle evidence remains open as permitted by the device-evidence release gate. |
| Task 17: Repository gates | Complete | OCaml, sync, analyze, host, golden, integration, doctor, unsigned builds, macOS Swift tests, dependency cleanliness, diff hygiene, and repository-scope checks pass. |

Tasks 13 and 14 are not silent omissions: FG-1 produced the exact stop condition defined by the plan. Task 16 is an evidence limitation rather than an implementation fallback; no unverified device or assistive-technology result is inferred as passing.

## Implemented evidence

### Dependency and generated-host adoption

- `logseq_journal.opam` pins `bonsai_flutter` and `bonsai_flutter_test` to full commit `6f52ea79539ed0e115bac5991ab2db8f176dc88d`.
- Active opam pins for `bonsai_flutter`, `bonsai_flutter_test`, and `bonsai_flutter_tool` resolve to the same commit.
- The project-local resolved mirror contains the updated foreground frame loop and application-response cycle behavior.
- Generated `flutter/pubspec.yaml` contains the Flutter SDK `integration_test` development dependency.
- `sync-host --check` and `sync-project --check` pass with no hand-maintained generated-host drift.
- The clean source checkout at `/Users/rcmerci/gh-repos/bonsai_flutter` remains unchanged.
- Canonical Profile and Release iOS builds retain the complete Material Icons font instead of a statically scanned subset.

### Header, date, and wide layout

- Menu and More use current Material icon code points and reserve `44 x 44` visual shells without `Pressable`, `Semantics`, or application handlers.
- The Today context is independently centered, view-only, and has no date-selection route or chevron.
- Swift formats compact locale-aware weekday, month, and day labels.
- OCaml caches localized headings by calendar generation and rejects stale responses.
- A real compiled-runtime golden renders `Today, Fri, Aug 7`, proving that the repaired application-response delivery cycle reaches accepted OCaml state.
- Timeline content uses a `720`-logical-pixel maximum width. Logical viewport tests cover `320`, `719.5`, `720`, `744`, and `1200` widths and prove the expected centered insets.

### Timeline rows and adaptive transitions

- Non-task rows do not reserve a task target; Todo and Done rows retain one independent task action.
- Current Material icon code points are used for task, disclosure, Menu, and More glyphs.
- Disclosure precedes the fixed time slot and retains a bounded target at large text sizes.
- Compact, adaptive-inline, and adaptive-stacked row roots use distinct stable keys so profile changes do not reuse flex children across incompatible parent layouts.
- Header and row dividers both resolve to one physical pixel from the active device pixel ratio while each compact row remains exactly `48` logical pixels high.
- The root consumes the top safe area once around the combined Header and Timeline. The Header's inner safe area and Flutter's automatic ListView padding therefore cannot introduce a second `47`-point gap before the first row.
- Canonical source remains literal. No token entities, attachment data, or renderer fallback was added.

### Capture and fixture

- Capture remains an OCaml-owned body overlay with a `48`-pixel visual circle, `56`-pixel target, bottom safe-area clearance, and RTL logical positioning.
- The compiled-runtime fixture includes Today, previous-day, and second-previous-day groups with normal, todo, done, parent, mention-like, tag-like, emoji, long-source, boundary, and final-row cases.
- The fixture creates only an explicit app-private temporary store.

## Automated verification

| Gate | Result | Evidence |
| --- | --- | --- |
| OCaml complete suite | Pass | `opam exec -- dune runtest`, including the `10,000`-record bounded-rendering corpus. |
| Source boundary | Pass | The suite reports `source boundary is clean`; obsolete Menu and More handlers are forbidden. |
| Flutter analysis | Pass | Canonical `flutter analyze --no-pub` reports no issues. |
| Flutter host tests | Pass | `bonsai-flutter exec --profile=debug -- flutter test --no-pub test` passes 14 tests and skips only the opt-in real-runtime golden. No generated manifest edit is required. |
| Real-runtime golden | Pass | Update mode and a clean non-update rerun pass through profile-aware execution. The checked-in `390 x 844` PNG has SHA-256 `e03e7e721084ca272bb3dd50dec0857d53507cb357b6ee6aa54f76f2454728bd`. The harness uses deterministic `47`-point top and `34`-point bottom safe areas and deterministic Roboto, Material Icons, and Apple Color Emoji fonts. It also asserts that populated compact content begins less than `30` points below the Timeline viewport top. |
| macOS integration suite | Pass | All eight cases pass: four RTL locales, LTR restoration, safe-area adaptive layout, complete OCaml-owned product flow, and truthful startup failure. The adaptive metadata slot now has a finite height and no RenderFlex overflow occurs. |
| Sync checks | Pass | `sync-project --check` and `sync-host --check`. |
| Toolchain checks | Pass | `doctor --target=macos` and `doctor --target=iphoneos`. |
| macOS no-codesign build | Pass | `bonsai-flutter build --no-codesign macos` built the Debug application. |
| iOS no-codesign build | Pass | `bonsai-flutter build --no-codesign ios` built and verified the arm64 physical-device application. |
| macOS Swift tests | Pass | `bonsai-flutter exec --profile=debug -- xcodebuild test ...` passes both Runner test cases while restoring the canonical generated manifest. |
| iOS Swift tests | Open | iOS Simulator is unsupported by the native-artifact hook; a physical iPhone test session is required. |
| iOS Profile and Release icons | Pass | Canonical unsigned iOS builds pass. Both application bundles contain the complete `1,645,184`-byte `MaterialIcons-Regular.otf` with SHA-256 `d9865b671a09d683d13a863089d8825e0f61a37696ce5d7d448bc8023aa62453`, identical to the Flutter SDK source. |
| Dependency cleanliness | Pass | `/Users/rcmerci/gh-repos/bonsai_flutter` is clean at `6f52ea79539ed0e115bac5991ab2db8f176dc88d`. |
| Project constraints | Pass for this increment | No `spec/` or Dune file was modified by this increment; pre-existing user changes were preserved. |

## Resolved former blockers

The two blockers identified during the first acceptance run are resolved and adopted:

1. Application responses, application request errors, and application events are rebased to the carrying presentation revision and schedule foreground frame delivery. The real Journal runtime now receives localized date responses and renders localized header and day labels.
2. The host generator emits `integration_test` under `dev_dependencies`. The generated dependency is checked in and `sync-host --check` passes.

These items must not be reported as open project work again unless the resolved dependency changes.

## Resolved native-artifact profile and icon gates

The canonical generated `flutter/pubspec.yaml` intentionally has no fixed `native_artifact_profile`. `bonsai-flutter exec --profile=debug -- COMMAND` now builds the selected native artifact, temporarily selects that profile for the wrapped Flutter or Xcode command, restores the exact manifest on success or failure, and preserves `sync-host --check` cleanliness.

Profile and Release runtime icons must be built through canonical `bonsai-flutter build` or `bonsai-flutter run`. Those commands normalize the forwarded Flutter flags and force `--no-tree-shake-icons`; generic `exec` intentionally does not rewrite arbitrary wrapped commands. Artifact inspection, rather than build success alone, confirms that both iOS bundles contain the full font.

## Framework-gated deferred work

FG-1 remains unavailable in the adopted dependency. The public OCaml `rich_text` surface accepts only a list of plain strings, and the renderer does not expose independently styled spans plus embedded controls with the required source-order, ellipsis, semantics, and bounded-layout guarantees. Therefore:

- hashtag and mention styling is not implemented;
- the deterministic hash policy is recorded but inactive;
- canonical source remains one plain text node;
- no private renderer patch or Dart fallback is permitted.

FG-2 and FG-3 also remain deferred exactly as specified by the primary document.

## Manual and visual evidence

The supplied `941 x 1672` reference raster has SHA-256 `52736e9506a43de70f24c653652eb6ee7c2d6823da700d74c3f09fa72e66a8e9`. It was normalized at `0.5x`, preserving the reference's approximately two-pixel-per-point row rhythm, onto a `471 x 844` logical comparison canvas. Two 50%-alpha overlays align the narrower implementation to the reference's leading and trailing edges separately; their SHA-256 values are `5a695a12345d20d292f6401d79c19afee68cab06d94fd32e33fea1e179054409` and `668b98efdca7b771c847b974a2bf3f99bc53283704d7718bf55c3ca2d5fbd6bb`.

That overlay exposed and then verified removal of a duplicated `47`-point top inset below the Header. After the fix, the Header divider, first populated row, later `48`-point rows, and day headings share the reference's vertical grid. The implementation image contains readable localized text, current Material icons, emoji, grouped days, task states, disclosure, aligned time slots, and Capture clearance. Background pixel sampling is effectively identical at approximately `#fdfdfd`. Horizontal comparison uses separate leading- and trailing-aligned overlays because the supplied raster and the agreed implementation viewport have different aspect ratios; no nonuniform scaling was used.

The canonical Release macOS application was also inspected through the native accessibility tree and screenshots without editing persisted content. Timeline, Detail, and Capture routes opened successfully; Capture was cancelled without saving. Narrow and wide windows retained the centered header, stable time column, nonoverlapping row content, content-width cap, and overlay Capture placement. The native tree exposes row, task or disclosure, Detail, Capture, Cancel, and Save controls truthfully, while Menu and More remain nonactionable images. Full Keyboard Access was not enabled on the host, so repeated Tab input did not establish keyboard-focus evidence; the system setting was not changed or treated as a pass.

The following release evidence remains open:

- physical iPhone portrait and landscape safe areas and Dynamic Type through `3.2`;
- VoiceOver names, headings, checked state, disclosure state, view-only date context, absence of actionable Menu and More semantics, and Capture;
- release macOS keyboard-only navigation, focus restoration, and VoiceOver; narrow and wide visual behavior has native evidence;
- Chinese and Japanese IME selection, paste, undo, emoji, combining marks, and bidi input;
- backgrounding, route restoration, locale changes, time-zone changes, and midnight rollover on device;
- signed-device screenshot review against the reference under native iOS font rasterization.

## Release conclusion

The activated application scope and all automated dependency blockers are implemented. OCaml ownership, durability, bounded rendering, source boundaries, sync checks, profile-aware tests, the complete macOS integration suite, the deterministic safe-area golden, reference-style comparison, canonical Profile and Release icon retention, and no-codesign platform builds pass. Release acceptance remains partial only until the physical-device and assistive-technology matrix is completed.
