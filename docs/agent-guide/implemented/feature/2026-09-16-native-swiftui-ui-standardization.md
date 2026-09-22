# Native SwiftUI UI Standardization for iPhone

## Problem

The active application renders through SwiftUI, but several screens still use
manually assembled navigation, action rows, selection controls and layout rules.
Using native drawing primitives alone does not provide native navigation,
selection, sheet, keyboard or accessibility behavior. The result includes
duplicated detail navigation, oversized action sheets, manually positioned bottom
controls, and text geometry that can disagree with native text layout.

This decision consolidates every UI optimization case from the 2026-09-16
review and subsequent discussion. It describes the desired native experience,
not a compatibility plan for the current renderer or application architecture.

### Evidence and limits

- The [source audit](../../../test-reports/2026-09-16-swiftui-component-audit.md)
  records 16 grouped findings and the complete target checklist. The 32 cases
  below expand those groups into individually reviewable outcomes. UI-06 and
  UI-31 retain their audit IDs but are excluded by the subsequent iPhone scope
  clarification. UI-25 was deferred by the user on 2026-09-17; the other
  29 cases remain in the current implementation scope.
- The inspected production surfaces are `swift/App.swift`,
  `swift/JournalAuthenticationView.swift`, `swift/JournalSparseCollection.swift`,
  `app/application.ml`, and the `journal_header`, `journal_timeline`,
  `journal_row`, `journal_symbols` and `journal_visual_tokens` modules.
- Framework behavior was traced through the installed BonsaiSwiftUI sources,
  including `NativeSheet.swift`, `NativeNavigationStack.swift`,
  `NativeExpandableComposer.swift`, `NativeMessageComposer.swift`,
  `SwipeActions.swift`, `NativeTextView.swift` and `NativeNotices.swift`.
- Code locations below identify the audited working-tree snapshot, including
  uncommitted migration work. Recheck line numbers before implementation.
- This was a source review, not a visual or interaction test. Clipping, contrast,
  keyboard and accessibility risks have not all been reproduced on devices.
- SF Symbols, native sheet shells, native authentication fields, some progress
  controls, context-menu accessibility and motion adaptation already exist.
  Their presence is acknowledged; this document does not claim every existing
  component is defective.
- The earlier [renderer migration decision](../../implemented/architecture/2026-09-15-replace-bonsai-flutter-with-bonsai-ui.md)
  was closed at its recorded stopping point. This proposal neither reopens
  that implementation nor marks its outstanding verification as complete.

### Subsequent acceptance scope update

On 2026-09-17, the user deferred actual VoiceOver speech, traversal/operation
order and system accessibility acceptance. These human/system verification gates
are not required for current completion. Keep existing native semantics and
completed text-layout work; this does not authorize removing accessibility
behavior or defer other UI, authentication, data-integrity or performance work.
Where individual case descriptions below call for the deferred gates, this later
scope update takes precedence. UI-25 and separator work remain deferred.

On 2026-09-18, the user asked not to fix overly fine-grained issues. Prioritize
the main native screens and usable end-to-end flows. Defer the non-crashing macOS
NSTableView console-warning investigation and cosmetic refinements; neither is
a current completion blocker. Retain core navigation, editing, unlock/recovery
and data-integrity requirements, and do not report unperformed iPhone checks as
passed. The iPhone is available again as of the subsequent user instruction on September 18; continue physical iPhone acceptance.

## Decision

### User-directed implementation closure — 2026-09-18

The user requested stopping further work and marking this document implemented.
Close this implementation at the current delivered state. The native screens,
E2EE redesign and focus repair, retained List navigation, composer flows and
Capture synchronization repair are implemented, with evidence recorded in the
[implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md).
This instruction supersedes earlier requirements to keep the decision proposed
until every acceptance gate is proved. It does not turn unperformed checks into
passes. Further acceptance is paused and requires a new user request.

Remaining unverified items include real incorrect-E2EE-password retry, whether
login presents a verification challenge, remaining input/long-content boundaries,
first populated-content startup latency and attribution of performance alerts.
The short performance control completed with test and trace exit code zero;
its trace has not been analyzed. Undo/Redo, separators, fine cosmetic issues and
actual VoiceOver/system accessibility acceptance retain their prior deferrals.
The independent retry application was built but has not been installed or used.


Make standard SwiftUI composition and interaction the target for the iOS iPhone
application surfaces. Choose the most appropriate native component for each task,
including iPhone layout, keyboard behavior, accessibility semantics and material.
iPad/Mac large-screen adaptation and desktop-only features are outside this work.

### Confirmed direction

The user supplied these requirements on 2026-09-16; they require no repeated
confirmation:

1. Record every optimization case identified in the UI review, with explicit
   scope exclusions for cases superseded by the iPhone clarification.
2. Choose the most idiomatic SwiftUI target without accommodating the current
   implementation, existing Bonsai API limitations or obsolete UI behavior.
3. Use the supplied bottom-control composition: a leading Liquid Glass capsule
   with Journals and Favorites icons, plus a separate trailing Capture icon.
4. After answering all three exploration questions, the user explicitly
   requested transition to proposed. This records the agreed design and scope;
   At that point, UI implementation and runtime acceptance had not started.
5. The user answered Q1: focus on iOS iPhone and do not consider large-screen
   adaptation. Keep the supplied bottom layout for the target iPhone interface;
   sidebar design and Mac-only UI work are excluded. This is not a request to
   remove existing platform support.
6. The user answered Q2: retain unsaved Capture/Append drafts when closing the
   sheet. Closing does not discard text and does not require a discard
   confirmation. Reopening the same composer context restores its draft.
7. The user answered Q3 by accepting the recommendation: initially support
   block-deletion Undo and its Redo only within the current open-graph session.
   Clear this history on graph change or application restart. Report conflicts
   and failed compensating operations explicitly.
8. On 2026-09-17, the user deferred Undo/Redo implementation. This supersedes
   item 7 for the current implementation scope: UI-25 is deferred, existing timed
   deletion cancellation remains, and no protected spec edits are authorized.
   The original design is retained below for future reconsideration.
9. On 2026-09-17, the user took the iPhone away and requested testing on macOS
   first. Use macOS to verify shared implementation and isolated mutation flows.
   This does not add Mac-specific UI adaptation to scope or waive the remaining
   iPhone visual, UIKit interaction and accessibility acceptance gates.

10. On 2026-09-17, the user made the iPhone available again. Resume signed
    production device acceptance over USB; iPhone Mirroring is unavailable.

11. On 2026-09-17, the user explicitly deferred the divider issue discovered
    during physical acceptance. Leave current separator behavior unchanged and
    retain the finding for later work.

12. The user subsequently took the iPhone away again and requested macOS testing
    first. Physical-device work is paused; shared native acceptance continues on
    macOS without treating it as iPhone visual or performance evidence.

13. On 2026-09-17, the user explicitly requested continued iPhone acceptance.
    The paired iPhone is available again. Resume USB XCTest on the current signed
    build and disposable encrypted fixture host; keep Undo/Redo and dividers deferred.

### Design principles

On 2026-09-18 the user removed the macOS-only restriction from the active goal.
The paired iPhone is available again through wired CoreDevice, now on iOS 26.7
(23H24). Resume current-build signed device acceptance. Retain the exclusions
for fine-grained issues, separators, new Undo/Redo and actual VoiceOver/system
accessibility acceptance. Earlier iOS 26.6.1 evidence retains its original
build/system attribution.

- Use native navigation, toolbars, menus, selection controls, lists, disclosure,
  sheets, forms and semantic action roles before custom interaction mechanisms.
- Apply Liquid Glass to appropriate navigation and controls. Use standard content
  styles for text, lists and forms; do not put a glass background behind every
  symbol or nest decorative glass surfaces unnecessarily.
- Treat the chosen APIs as the supported-system baseline. Remove obsolete paths;
  do not add old-system fallbacks, compatibility layers or imitation materials.
- Existing bridge gaps are implementation work, not reasons to weaken the target
  design. This document does not claim that all target APIs are already bridged.
- Preserve useful product capabilities and data integrity, not incidental UI
  structure. Native presentation must not become an independent owner of graph
  mutation, authentication or sync decisions.
- Comply with [UX guidelines](../../../ux-guidelines.md): at most three visible
  dividers, immediate restoration of the most recent graph, and preference for
  appropriate built-in Bonsai/SwiftUI components. In particular, native List
  adoption must not introduce a separator on every visible row.

### Bottom-control composition

```text
                  Journal content

    ( Journals icon | Favorites icon )       ( Capture icon )
           shared Liquid Glass                separate surface
```

The vertical stroke in this diagram separates labels for explanation; it is not
a requested visible divider. Both navigation actions are icon-only, with a clear
selected state and accessible names. Capture is a separate icon-only action.
Use a bottom toolbar with a native item group and flexible spacing. A system
toolbar should own its material, safe-area placement and control interaction.
Use a native glass button style for a genuinely standalone floating control.
Do not replace this composition with a conventional full-width tab bar. This is
the target iPhone layout; no expanded sidebar variant is required.

### Navigation and application structure

| Case | Audited evidence | Native target and observable outcome |
| --- | --- | --- |
| UI-01 — Bottom navigation | `application.ml:1670` builds labeled plain buttons in a row; line 1720 separately offsets Capture. | Use bottom-bar ToolbarItemGroup and native spacing for the supplied composition. There are two glass surfaces, icon-only controls, and no manual bar-height or bottom-position arithmetic. |
| UI-02 — Selected destination | Bottom buttons attach selected accessibility metadata without an explicit visual selection treatment. | Give Journals/Favorites a clear native tint or symbol-variant selection treatment, accessible selected state, and meaningful accessible labels. Selection remains identifiable without relying only on color. |
| UI-03 — Capture opener | `application.ml:1459` supplies an expandable labeled FAB; installed `NativeExpandableComposer.swift:177` uses borderedProminent. | Use a toolbar SF Symbol action with native glass presentation, or a standalone native glass button when warranted. Keep it icon-only in the supplied bottom layout; avoid a hand-drawn capsule. |
| UI-04 — Main header | `journal_header.ml:88` builds plain action buttons in a padded row. | Use a navigation title or principal toolbar title for date/context, with native account/error toolbar items. Header height, action grouping and scroll-edge presentation are system-managed. |
| UI-05 — Detail navigation | `application.ml:2433` draws Back and Block while line 4737 also declares a native Block destination with popping enabled. | Use NavigationStack/navigationDestination and the system Back action. Each destination has one title and one back affordance; gestures and keyboard navigation follow platform behavior. |
| UI-06 — Expanded iPad/Mac navigation (excluded) | The original audit proposed an adaptive sidebar. | Excluded by the user's Q1 answer: this work targets iOS iPhone and does not include large-screen navigation adaptation. Retain this ID for audit traceability; no implementation or acceptance requirement applies. |

### Capture, sheets and action selection

| Case | Audited evidence | Native target and observable outcome |
| --- | --- | --- |
| UI-07 — Capture and Append sheets | The shared composer uses custom HStacks for close/task/submit, a plain chevron-down control and a custom downward drag gesture. | Present a native sheet with a navigation container, native cancel/confirmation toolbar placement and a native editor. Use the system grabber and sheet gestures. Focus, submission and dismissal stay coherent in both Capture and Append. |
| UI-08 — Composer task intent | `application.ml:1509` varies action style and tooltip for the task-intent button. | Use Toggle with an appropriate native button style and explicit on/off semantics. Visual state, keyboard activation and accessibility value agree. |
| UI-09 — Sheet sizing | `application.ml:4815` applies Page sizing and viewport-percentage frames; status content also estimates handle and scroll height at line 1305. | Use task-appropriate presentationSizing, presentationDetents and native content measurement. No sheet or inner viewport is sized by a guessed fraction of the parent screen. Small iPhone displays, rotation and keyboard presentation retain reachable controls. |
| UI-10 — Sheet dismissal | Non-status modals disable interactive dismissal; status lacks an explicit close action; Error info uses Back to dismiss; authentication builds a separate Close row. | Use clear Close/Cancel actions and system placements. Read-only sheets dismiss normally. Closing Capture/Append retains the draft without a discard confirmation; reopening the same context restores it. Back means navigation within a hierarchy, not dismissal of a standalone sheet. |
| UI-11 — Account actions | `application.ml:1769` puts account actions and Cancel in a large sheet. | Use an anchored Menu with native Labels, symbols and roles. Settings, Diagnostics and graph switching open their appropriate destinations; choosing an action does not require navigating a modal action page. |
| UI-12 — Destructive confirmation | `application.ml:2303` uses a large custom sheet; action_target translates Filled/Text into styles rather than destructive/cancel roles. | Use alert or confirmationDialog with destructive and cancel roles and an accurate data-loss explanation. No delete occurs through cancellation or passive dismissal. |
| UI-13 — Task status selection | `application.ml:1251` renders seven buttons, disables the current status and estimates row heights. | Use Picker in a Menu as the default; use an inline Picker in a focused sheet only when the task needs more browsing space. The system marks selection; status symbols/colors retain domain meaning without separate glass backgrounds. |

### Settings, lists and information surfaces

| Case | Audited evidence | Native target and observable outcome |
| --- | --- | --- |
| UI-14 — Settings | `application.ml:1881` uses three button chips and displays font-size/line-height/weight strings. | Use Form/Section and a labeled density Picker, segmented when appropriate. Show a live reading preview instead of implementation metrics. Present settings through the iPhone navigation or sheet flow with native dismissal. |
| UI-15 — Graph selection | `application.ml:2640` uses a ScrollView/column of generic buttons with a custom refresh header. | Use List with native row/open or selection behavior and a native toolbar refresh action; use refreshable where appropriate. Launch still restores the last graph directly; this screen appears only when graph choice is needed. |
| UI-16 — Journal and Favorites feeds | `journal_timeline.ml` uses a custom sparse collection; `journal_row.ml` imposes estimated heights and clipping. | Use List, date Sections and intrinsic native row sizing. Use plain native row Buttons with programmatic NavigationStack pushes, retaining the existing List UI through detail navigation. Keep pagination correct, but redesign presentation around the native container rather than retaining custom geometry for compatibility. |
| UI-17 — Row actions | `journal_timeline.ml:77` and line 190 use framework swipe actions; installed SwipeActions translates rows and draws gesture-driven action panes. | Use List swipeActions and contextMenu with concise Label-based actions, SF Symbols and destructive roles. Native gesture arbitration, keyboard/context alternatives and accessibility actions are available. |
| UI-18 — Block hierarchy | `application.ml:2480` manually renders dots, chevrons, indentation and expanded-state text in a flattened window. | Use OutlineGroup or DisclosureGroup in List. Native disclosure exposes expansion state and keyboard interaction; adapt child-loading presentation to the native hierarchy. |
| UI-19 — Diagnostics | `application.ml:2254` creates heading/value columns and a custom close header. | Use Form/Section/LabeledContent for diagnostic values, selectable text and native dismissal/navigation. Values remain readable at large text sizes and on narrow iPhone displays. |
| UI-20 — Error details | `application.ml:2103` creates a custom Back header and metadata columns in GroupBox cards. | Use native structured sections, selectable error/cause text and contextual recovery actions. Distinguish a modal Close from hierarchical Back; diagnostic content does not become decorative glass controls. |
| UI-21 — Loading and download progress | `journal_timeline.ml:54`, line 243 and `application.ml:2676` often render work in progress as text alone. | Use ProgressView with a concise status label. Show determinate progress only when a meaningful total exists; otherwise show indeterminate activity. Busy authentication also has an activity indicator. |
| UI-22 — Empty and unavailable states | Favorites/journal empty states and graph failures are mostly plain text; the Swift startup host already uses ContentUnavailableView. | Use ContentUnavailableView for substantial empty/error screens with a relevant action such as Capture or Retry. Small inline empty indicators may remain concise native text. Never render an error as a normal empty list. |

### Input, undo and feedback

| Case | Audited evidence | Native target and observable outcome |
| --- | --- | --- |
| UI-23 — Authentication | `swift/JournalAuthenticationView.swift` already uses native fields and content types, but busy feedback is mainly a changed button label and focus/keyboard behavior needs review. | Keep native TextField/SecureField/Picker, use correct content types, capitalization and keyboard configuration, and coordinate FocusState/onSubmit. Password, code and challenge flows have clear focus progression, progress indication and readable inline errors. |
| UI-24 — Encrypted graph unlock | `application.ml:2708` uses a secure field in a generic startup stack. | Use a focused Form or sheet with a labeled SecureField, clear Unlock/Cancel actions and inline failure feedback. Keyboard submission is equivalent to the enabled primary action; secure text remains protected. |
| UI-25 — Undo and redo (deferred) | `application.ml:4560` exposes block-delete Undo through a timed notice, with no block-delete UndoManager integration. | Deferred by the user on 2026-09-17; not a current implementation or acceptance requirement. Retain existing timed deletion cancellation. Future design: integrate graph mutation undo with UndoManager and appropriate iOS undo/redo interactions, including a discoverable touch-accessible action. The notice is supplementary rather than the sole recovery window. Initially cover block deletion and its Redo only within the current open-graph session; clear history on graph change or application restart. Capture, Append and status mutations are outside this undo scope. Report conflicts or failures explicitly; text-editor undo remains distinct. |
| UI-26 — Typography and text geometry | Date scaling is capped in `journal_visual_tokens.ml:288`; scalar widths are estimated at line 367; `journal_row.ml:310` clips calculated row heights. | Use semantic font roles, Dynamic Type and intrinsic native measurement. Remove character-width heuristics, forced row heights and date shrink-to-fit limits. Dates, body text and supporting text reflow without accidental clipping. |
| UI-27 — Symbols and colors | Symbols already use SF Symbols; theme tint and destructive/status palettes partly use fixed RGB, while supporting text uses opacity. | Use SF Symbols with appropriate semantic sizing, primary/secondary foreground styles and semantic action colors. Preserve meaningful custom status colors with light/dark/high-contrast variants and non-color cues. |
| UI-28 — Safe areas and keyboard | `application.ml:1701` reserves fixed header/footer space and independently offsets Capture. | Use system toolbar layout, safeAreaInset where appropriate, scroll margins and native keyboard avoidance. Controls and the last row remain reachable without manual safe-area arithmetic or overlapping overlays. |
| UI-29 — Feedback messages | Sync errors are overlaid near the header; capture/status/delete feedback uses a custom material notice. | Place errors near the affected operation. Use an optional compact safe-area notice for transient feedback. Messages do not cover navigation or input, and not every message needs Liquid Glass. Critical recovery remains accessible after transient feedback disappears. |

### Platform behavior and accessibility

| Case | Audited evidence | Native target and observable outcome |
| --- | --- | --- |
| UI-30 — Accessibility | Custom selection, disclosure, date scaling and geometry require explicit semantics and adaptations; some native accessibility paths already exist. | Prefer native roles/values, selected and expanded states, accessible icon labels, logical focus and RTL layout. Validate VoiceOver, Dynamic Type, Bold Text, Increase Contrast and Reduce Transparency/Motion. No control depends solely on color or visual position. |
| UI-31 — Mac commands (excluded) | The original audit identified missing desktop command integration. | Excluded by the iPhone scope clarification. Mac Settings scenes, menu-bar commands and desktop-only shortcuts are not implementation or acceptance requirements for this work. |
| UI-32 — Animation | Root-control visibility and composer presentation include application-defined animation/layout behavior. | Use system navigation, sheet, disclosure and control transitions. Group glass controls through native toolbar behavior; respect Reduce Motion and avoid animations that remount lists, move focus or lose input. |

### Confirmed draft dismissal behavior

Explicit Close and interactive sheet dismissal retain unsaved Capture/Append
content. Neither action submits the draft as a graph mutation nor discards it.
Reopening the same composer context restores the text and task-intent selection.
A failed save retains the draft; a confirmed successful save clears the saved
attempt without clearing newer edits.

Keep draft identity associated with its graph and composer purpose; Append also
belongs to its parent block. Do not restore a draft into another graph or append
it to a different parent. Sheet view lifetime must not own the only copy of the
draft. The user's answer resolves dismissal behavior; storage durability across
application restarts is not established by this answer and must be specified in
the implementation design without being reported as an already confirmed choice.

### Draft implementation policy

Draft retention is process-local, keyed by graph UUID and composer purpose;
Append additionally uses the parent block UUID. Application restart does not
restore unsaved drafts. Account changes/sign-out clear all retained drafts;
explicit local-copy deletion clears drafts for that graph. These choices avoid
persisting private draft text and are implementation decisions, not a claim of
previously confirmed restart durability.

Application owns graph draft selection; Journal_routes owns retained Append
composers for its selected graph; Journal_detail remains the owner of Append
admission and result matching. Retain only composer state, not an entire stale
outline projection. Reopening reloads the parent projection and gives the editor
a new session while restoring text, task intent, selection and composition.
Successful and failed Append completions must reach retained off-screen
composers, and never clear another parent's draft. A graph-session interruption
retains an admitted request and marks it failed for explicit retry with the same
mutation identity rather than silently resubmitting or inventing a second block.

Reducer tests use these public production boundaries. No persistence, transport
or UI regression duplicates the same draft lifecycle behavior.

### Deferred undo scope

The user deferred this capability on 2026-09-17. The following design is retained
for future reconsideration and is not a current implementation or acceptance
requirement. Existing timed deletion cancellation remains. The
[contract proposal](../../rejected/feature/2026-09-17-session-delete-history-contract.md)
records the protected-interface gap; no spec edits are authorized by this deferral.

Native graph-mutation Undo/Redo initially covers block deletion and its inverse,
including the descendants affected by that deletion. Capture, Append and status
changes do not join this mutation history. Native text-editor undo remains a
separate editing capability.

History belongs to the current open-graph session. Switching graphs or restarting
the application clears it; returning to a previously opened graph does not
restore that session's undo history. This is independent of draft retention:
clearing undo history must not implicitly discard retained composer drafts.

A transient Undo notice may supplement the native action, but its expiration does
not determine the session history lifetime. Undo/Redo must report conflicts or
failed compensating operations explicitly and must not claim success before the
owned operation succeeds. It must never apply a previous graph's action to the
newly selected graph.

### Scope boundaries

The goal is a native iPhone UI redesign of the 29 currently in-scope cases above,
not retention of the current widget tree. UI-06 and UI-31 are explicitly excluded;
UI-25 is deferred by the user;
iPad/Mac layouts and desktop commands are not part of this decision. Existing
data operations, authentication, encryption, graph restoration and synchronization
remain product responsibilities. Any
change in undo lifetime, draft retention or operation semantics must be explicit.

Do not preserve current sparse collections, hand-built swipe gestures, custom
button chips, row-height estimation or generic modal wrappers solely because
they already exist. Conversely, native SecureField, SF Symbols and valid content
layouts need no cosmetic replacement merely to claim more Liquid Glass usage.

Future implementation must respect repository source permissions: no Dune edits
without explicit authorization, no protected OCaml edits under `spec/`, and no
OCaml changes in `bonsai_flutter`. If required spec interfaces are unclear or
unreasonable, report the exact interface issue and proposed change before
development. These process constraints do not redefine the target UI.

## Implementation record

Implementation started on 2026-09-16 and was marked implemented at the user-directed
stopping point on 2026-09-18. Remaining acceptance is paused, not reported as passed. The [implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md)
tracks the full original scope, current changes, verification and remaining work.
Historical batch statuses describe their original measurement limits; the closure
above governs the current lifecycle.

Detail presentation now uses native List/DisclosureGroup with stable logical row
identities. Journal_detail owns explicit expanded-state events and paginated
child loading; SwiftUI owns row measurement and disclosure layout. The obsolete
fixed-height window interface is removed. The bridge supplies the loaded,
expanded rows, so large-tree frame size and materialization performance remain
explicit acceptance gates rather than assumptions of native List adoption.

Journal's native List retains its loaded prefix instead of evicting earlier rows
at 512 slots. Native visibility drives the existing paginated reads, and Capture
uses an explicit scroll-command generation rather than inferred pixel offsets.
The application still supplies all loaded rows to the bridge. Large-session
memory, frame-size and scrolling performance remain unverified implementation
gates; the native-container choice alone is not performance evidence.

Journal and block-favorite rows use native Buttons with the application-owned
NavigationStack path. Their existing Lists remain mounted while a detail is
presented, preserving actual UI state without scroll-position recording or
restoration. Batch 42 supersedes the earlier NavigationLink design. Batches 55–57
verify full-width touch targets, bounded row-open delivery and synchronous iOS
scene admission, with repeated physical navigation and foreground Capture checks.
Committed OCaml destinations remain authoritative.

Reading density uses native semantic fonts: Dense selects callout, Balanced body,
and Comfortable title3. Journal, Favorites, Detail and the Settings preview share
that mapping; system forms, controls and navigation keep their own native roles.
No global point-size overrides or date shrink-to-fit rules are needed. Root
navigation uses the system accent tint and semantic primary/secondary foregrounds.
The authentication surface uses semantic primary tint for native prominent and
bordered actions after native light-appearance audits exposed insufficient
contrast in the default blue actions; inline recovery messages use primary text.
No fixed replacement color palette is introduced. Meaningful status palettes
remain subject to the separate contrast/non-color acceptance gate.

## Alternatives considered

### Restyle the existing UI without replacing its structure

Changing colors, icons or button backgrounds would leave custom navigation,
selection, sheet sizing, swipe behavior and text geometry in place. It does not
meet the user's request for the most idiomatic native design.

### Replace the bottom controls with a conventional TabView

TabView is a valid standard navigation component, but a conventional full-width
tab bar does not express the specific two-surface sketch. Prefer native toolbar
composition for that layout and provide explicit navigation selection semantics.

### Apply glass to every icon, row and panel

This confuses content with controls and can create excessive layered materials.
Prefer native system material decisions for navigation/actions and standard
content styles for lists and forms.

### Limit the target to the current Bonsai bridge and collection architecture

That would keep several identified custom implementations by necessity. The
user explicitly excluded current implementation constraints from the design.
Native capability work must follow the chosen design, not the reverse.

### Retain older presentation paths through availability fallbacks

This conflicts with the repository's no-compatibility direction. Select a system
baseline that supports the chosen native APIs and remove obsolete paths.

## Acceptance criteria

### Proposal completeness

- UI-01 through UI-32 account for every case in the audit and conversation.
- The supplied bottom composition, native-first direction and rejection of
  compatibility constraints are recorded as confirmed, not asked again.
- Source evidence is distinguished from unverified visual or interaction risks.
- Q1, Q2 and Q3 are answered: target iPhone, retain drafts on dismissal, and
  initially support deletion Undo/Redo only in the current graph session. The
  subsequent user instruction on 2026-09-17 defers Undo/Redo implementation.
- The user explicitly requested the proposed lifecycle after resolving all
  three questions. This transition changes only the decision document and does
  not assert implementation or runtime acceptance.
- `spec-dev-tool check` for this document and `spec-dev-tool check --all` pass.

### Implementation acceptance

The following original criteria remain the evidence checklist. The user-directed
closure above explicitly permits implemented status with recorded verification
limits; it does not assert that the entire checklist passed.

- Every in-scope numbered case has an implemented native outcome and
  corresponding evidence, or an explicitly reviewed change to this decision.
  UI-06 and UI-31 are documented exclusions and UI-25 is explicitly deferred;
  no other case is silently dropped
  because an existing framework API is missing.
- The bottom controls match the supplied composition, have visible selected
  state and accessible labels, and remain usable with the keyboard and safe area.
- Each screen has a single coherent native navigation/dismissal structure.
  Destructive operations use semantic roles and clear confirmation.
- Native List, disclosure, forms and pickers replace the identified custom
  mechanisms; obsolete presentation paths and sizing heuristics are removed.
- The divider limit remains a recorded design requirement, but its implementation
  and acceptance are deferred by confirmed direction item 11. Do not change
  current separators in this work. The latest graph opens directly on launch;
  graph selection is not reintroduced as a mandatory startup screen.
- Capture/Append, task status, deletion/recovery, graph selection/unlock,
  authentication, settings and diagnostics remain functional with their chosen
  native presentations and explicit draft/undo policies.
- Closing Capture/Append by its button or sheet gesture retains unsaved text and
  task intent; reopening the same graph/composer context restores them without
  a discard confirmation. Closing never implicitly saves or deletes the draft.
- Existing timed deletion cancellation remains functional. New session-scoped
  block-deletion Undo/Redo (UI-25) is deferred and is not an acceptance gate for
  this implementation. Draft retention remains independently required.
- Device verification covers supported iPhone display sizes, portrait/landscape,
  keyboard visibility, large Dynamic Type, Bold Text, VoiceOver, RTL, dark
  appearance, increased contrast, reduced transparency and motion. iPad and Mac
  visual acceptance are outside this work.
- IME composition, selection, focus, scrolling, pagination, graph changes and
  navigation do not lose input or silently change the affected data operation.
- Build/interaction/performance evidence is recorded for the chosen iOS iPhone
  baseline. Source review is not counted as a passed device test.

For bug regression tests, follow the repository's production-owner rule: first
attempt deterministic reproduction using the owner's public pure reducer events,
completions, state and effects. Use only that boundary if it reproduces the
defect; otherwise document the missing boundary and test the narrowest layer that
executes it. Visual acceptance is still needed for material and layout claims;
do not duplicate reducer behavior tests in unrelated integration/UI layers.

## Risks

- Native List/OutlineGroup adoption changes presentation and materialization.
  Pagination, large-history performance, scroll position and hierarchical
  loading still need deliberate design and measurement.
- Native toolbar grouping is platform-managed. The sketch must be verified
  through actual toolbar behavior rather than matched with hand-drawn shapes.
- Native containers introduce default separators, spacing and selection behavior;
  use their public styling APIs to satisfy the divider budget and content needs.
- Draft retention must apply consistently to gestures, explicit Close and sheet
  teardown. Losing view-local state must not erase the recoverable draft or
  associate it with a different graph/parent block.
- Undo after a synced mutation may require a compensating domain operation and
  conflict handling. UndoManager must not imply that arbitrary remote changes
  can be reversed safely or that failure may be hidden.
- A native redesign may require new public framework capabilities and a newer
  supported-system baseline. Missing capabilities are not evidence that existing
  interfaces may be bypassed or protected files edited without authorization.
- Custom domain colors, long diagnostic text and complex scripts need real
  accessibility and layout validation; source inspection cannot establish their
  contrast, readability or fit.
- Earlier migration defects remain separate evidence. This design document does
  not assert that input-loss or native-interaction problems are already fixed.

## Questions

None. The user explicitly requested stopping further work and transitioning the
main UI decision to implemented.

## Consequences

The delivered UI implementation is closed at the recorded stopping point.
Production behavior and existing user data are unchanged by this documentation
transition. The remaining-acceptance checklist is retained for a future explicit
request; no additional device installation, credential entry, profiling or UI
changes are part of this closure.

## References

- [UI source audit](../../../test-reports/2026-09-16-swiftui-component-audit.md)
- [Project UX guidelines](../../../ux-guidelines.md)
- [Apple: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple: Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
- [Apple: Picker](https://developer.apple.com/documentation/swiftui/picker)
- [Apple: Form](https://developer.apple.com/documentation/swiftui/form)
- [Apple: Destructive button role](https://developer.apple.com/documentation/swiftui/buttonrole/destructive)
- [Apple: Get started with Dynamic Type](https://developer.apple.com/videos/play/wwdc2024/10074/)
- [Apple: Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo)

## Batch 42 navigation correction

The user explicitly chose retaining the original list UI instead of recording and
restoring its scroll position. Journal and Favorites now use native row Buttons
with the existing programmatic NavigationStack path. This supersedes the earlier
NavigationLink choice for these two collections; repeated physical push/pop is
the acceptance boundary. Obsolete route anchors and restoration plumbing are
removed. Pagination visibility and explicit Capture scroll-to-top remain.

Batch 42 verifies repeated middle-row Back, final root 500, Favorites and
Capture/lifecycle behavior on iPhone, plus Journal/Favorites return on macOS.
See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch42-list-ui-retention.md`.
The user withdrew the iPhone after installation and requested macOS-only work.
New production cold start and isolated Capture outbox reconciliation are not
claimed verified in that batch. The September 18 implementation closure above
supersedes its historical active-goal status.
