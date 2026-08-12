# Fixed-Large Capture Bottom Sheet

Status: Implemented

## Goal

Present Capture as a declarative, fixed-large modal bottom sheet using the
current public `bonsai_flutter` navigation implementation.

The sheet keeps the Timeline route mounted underneath it, owns a real modal
barrier and focus scope, and provides a stable compose surface while the
platform keyboard changes the available content viewport.

## Framework dependency

The application pins both `bonsai_flutter` and `bonsai_flutter_test` to:

```text
ff08899293604bbaa0344733275397e053fa5d8c
```

That revision provides the required generic behavior:

- a real non-opaque `ModalBottomSheetRoute`;
- a fixed-large shell for `Sizing.Scroll_controlled`;
- one route-owned keyboard inset coordinator;
- automatic text-input focus staged after a nonzero route entrance;
- immediate explicit pointer or host focus;
- immediate automatic focus for reduced motion, zero-duration routes, or an
  already visible keyboard;
- cancellation of pending automatic focus when the route is removed or
  covered;
- a theme-backed, rounded, clipped outer sheet surface;
- a coordinated receding transition on the route immediately below the sheet.

No application-specific Dart bottom-sheet implementation is permitted.

## Product decision

Capture uses:

```ocaml
Ui.Navigation.Modal_bottom_sheet.Sizing.Scroll_controlled
```

The fixed-large presentation replaces the previous Medium/Large detent model.
Capture does not expose a drag handle, detent actions, resize gestures, or
drag-to-dismiss behavior.

The explicit Close action remains the product-owned pointer dismissal path.
Platform Back and Escape continue to use the live page `can_pop` policy.

## Route composition

```text
OCaml Navigator pages
  |
  +-- Timeline page
  |
  `-- Capture modal page
        |
        +-- Flutter modal barrier and focus scope
        +-- fixed-large rounded sheet shell
        +-- automatic-focus coordinator
        +-- keyboard-adjusted content viewport
        `-- OCaml-owned Capture content and actions
```

OCaml remains the only owner of page presence, draft state, dismissal policy,
mutation admission, and visible actions.

Flutter owns route animation, the barrier, modal focus isolation, outer surface
shape and clipping, keyboard geometry, and automatic-focus timing.

## Presentation configuration

Capture uses one stable page and restoration identity:

```ocaml
let presentation =
  Ui.Navigation.Modal_bottom_sheet.create
    ~barrier_dismissible:false
    ~barrier_color:palette.modal_scrim
    ~sizing:Ui.Navigation.Modal_bottom_sheet.Sizing.Scroll_controlled
    ~use_safe_area:true
    ~request_focus:true
    ~transition_duration_ms:motion.capture_sheet_enter_ms
    ~reverse_transition_duration_ms:motion.capture_sheet_exit_ms
    ()
in
Ui.Widget.page
  ~key:(Ui.Key.string "journal-capture-sheet")
  ~page_key:(ID.Navigation.Page_key.of_string "journal-capture-sheet")
  ~presentation:(Ui.Navigation.Modal_bottom_sheet presentation)
  ~can_pop:(Journal_capture.can_pop capture)
  ~restoration_id:
    (ID.Navigation.Restoration_id.of_string "journal-capture-sheet")
  content
```

Standard motion is `220` milliseconds for entrance and `180` milliseconds for
exit. Reduced motion resolves both durations to zero.

## Keyboard and focus contract

The revisioned OCaml text input keeps `autofocus:true`, but Flutter controls
when that automatic request becomes active.

For a nonzero entrance with no existing keyboard inset:

1. The modal route and lower-route depth transition enter together.
2. The text input remains mounted with stable controller, session, selection,
   and composing identity, but automatic focus is withheld.
3. When the route entrance completes, Flutter releases automatic focus on the
   next safe frame.
4. The platform keyboard begins from the settled sheet geometry.

A pointer tap or explicit host focus request remains immediate. Reduced motion,
a zero-duration entrance, or an already visible keyboard also bypasses the
delay.

The fixed-large sheet surface remains geometrically stable during keyboard
animation. Flutter applies the engine-provided bottom inset inside the surface,
shrinking only the Capture content viewport. It removes the consumed inset from
the child `MediaQuery` so application content cannot apply it again.

The OCaml application must not read `Environment.keyboard_insets` to change the
Capture layout, sheet sizing, or page identity.

## Capture content

The sheet contains:

- a Close action;
- the `New block` heading and current journal date context;
- the existing revisioned multiline editor;
- a status or retry region;
- the task-state action;
- the Save action or saving progress indicator;
- the existing discard confirmation dialog when required.

The editor remains the only vertical scroll viewport in Capture. Its content
can scroll when the keyboard reduces the available fixed-shell viewport, while
the header and action row remain fixed.

The action row uses a Flutter `SafeArea` for the bottom system region. It does
not calculate or serialize a keyboard-dependent padding value.

Wide viewports keep the compose content bounded to `560` logical pixels while
the route-owned outer sheet surface still spans the fixed-large shell.

## Dismissal policy

| Capture state | Explicit Close | Platform Back or Escape | Result |
| --- | --- | --- | --- |
| Clean `Editing` | Enabled | Allowed | Close immediately |
| Dirty `Editing` | Enabled | Blocked | Show discard confirmation from Close |
| `Confirm_discard` | Replaced by dialog actions | Blocked | Keep editing or discard |
| `Saving` | Disabled | Blocked | Remain until the durable outcome is known |
| `Failed` | Enabled | Blocked when dirty | Confirm before discard |
| `Recovery_only` | Enabled | Blocked when dirty | Confirm before discard |
| `Committed` | Not rendered | Not applicable | Remove the page declaratively |

Barrier dismissal remains disabled. `Scroll_controlled` Capture has no
drag-to-dismiss path.

## Mutation and IME invariants

The presentation refactor does not change Journal mutation behavior:

- blank trimmed source cannot be saved;
- one Save activation admits one stable mutation and Block identity;
- saving blocks dismissal;
- durable `Block_captured` prepends exactly one Block and removes the sheet;
- failed retry reuses the admitted mutation identity;
- task-state changes never save or dismiss;
- UTF-8 content, selection, and composing ranges survive environment and route
  reconciliation;
- the `65,536` UTF-8 byte transport limit remains unchanged.

## Accessibility

The real modal route excludes the underlying Timeline semantics while Capture
is active. The heading, editor, Close, task, Save, retry, progress, error, and
discard-dialog semantics remain OCaml owned.

There is no adjustable drag-handle semantic control because the fixed-large
sheet has no detent state.

## Removed paths

The application no longer contains:

- `capture_sheet_detents`;
- `capture_sheet_geometry`;
- `resolve_capture_sheet_geometry`;
- keyboard-inset-driven Capture layout;
- `Modal_bottom_sheet.Handle_semantics` for Capture;
- `Modal_bottom_sheet.Detents` for Capture;
- `Sizing.Detented` for Capture;
- application-owned outer sheet radius or clipping.

No compatibility alias or fallback implementation is retained.

## Verification

Acceptance requires:

1. Source-boundary tests pin the exact framework revision and reject every
   removed path.
2. Application view tests require `Sizing.Scroll_controlled`, stable page
   identity, live `can_pop`, autofocus intent, the multiline editor, and the
   complete action hierarchy.
3. OCaml reducer, route, repository, Worker, IME, accessibility, and adaptive
   tests remain green.
4. Flutter analysis and application tests remain green against the rebuilt
   native artifact.
5. The upstream modal navigation suite proves delayed automatic focus, fixed
   shell geometry, keyboard viewport behavior, focus and semantics isolation,
   reduced motion, route identity, and exactly-once pop behavior.
