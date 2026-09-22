# Retire application-owned root scroll visibility

## Problem

The approved iPhone standardization delegates bottom controls to SwiftUI Toolbar.
Journal and Favorites now use native List and do not emit pixel scroll events.
Application still stores two Root_scroll_trigger values, accumulates 24-point
travel, resets them after every route/modal transition, and exposes visibility
that no renderer reads. Journal_timeline also accepts unused geometry, typography,
RTL and scroll-handler arguments. These obsolete paths contradict the native
ownership and no-compatibility direction.

## Decision

Use the existing SwiftUI Toolbar as the only root-control presentation owner and
remove the inactive application visibility model. Retain the independent capture
session tracking, destination, draft and graph state. Remove the unused date
scaling helper and presentation arguments instead of keeping compatibility APIs.

Remove the root scroll trigger type, state, events, resets and unused visibility
queries. Keep Root_navigation's destination and composer lifecycle reducer.
Remove unused Journal_timeline and timeline_page arguments and their caller-only
row-profile calculation. Remove the unused Date_row helper with its capped font
scaling. Intrinsic List geometry and native Toolbar remain the presentation owners.

Retire only two tests of the deliberately removed product behavior:
`test_root_navigation_scroll_lifecycle` and
`test_capture_fab_scroll_threshold_direction_reversal_and_top_reset`. They assert
custom scroll thresholds and hidden controls. Their removal is part of this
explicit behavior retirement, not a consequence of bug-test classification.
Retain all pagination, anchor, mutation, capture/draft and route tests, plus the
existing application-dispatch test that keeps native toolbar identity through
native List visibility observations. No replacement hidden-state model or test
is introduced.

## Alternatives considered

### Leave compatibility events and ignore them

Rejected: inert interfaces preserve the obsolete model and continue unnecessary
work on every application state update.

## Acceptance criteria

- Root_scroll_trigger, its state fields/events and custom visibility queries have
  no production or active test references.
- Journal_timeline accepts only values it uses; app render no longer calculates a
  row profile merely to pass it into an ignored argument.
- Existing destination, draft, pagination and native toolbar dispatch tests pass.
- App build and full tests pass; no Dune, protected spec or bonsai_flutter OCaml
  files change. The main UI decision stays open for its remaining device gates.

## Consequences

Native list visibility drives pagination but no longer changes a parallel hidden
control state. The two obsolete hide-threshold tests are retired explicitly;
active domain and native toolbar dispatch coverage remains. The app build, full
OCaml tests, application-dispatch suite, native List viewport suite, Swift
iphoneOS typecheck and unsigned iPhoneOS Release build pass. Remaining geometry
utilities and physical-device gates belong to the still-open main decision.

- Similar names can conceal unrelated pagination/anchor logic. Limit removals to
  the unused visibility owner and presentation arguments identified above.
- Old geometry utilities still used by the separate legacy row module require
  their own retirement; this change does not claim they are gone.

## Implementation record

The obsolete scroll owner, visibility observations and getters are removed.
Application still calls track_capture_session after every state update, preserving
the session-identity invariant previously reached through the visibility reducer.
Destination, capture and graph lifetimes remain in Root_navigation.

The two threshold/hide tests were retired with the removed behavior. Capture
lifecycle assertions retain destination changes, admission, completion and graph
replacement; only obsolete scroll/coverage events were removed from their setup.
Pagination, anchor and native toolbar identity tests remain. Date_row and unused
presentation arguments are gone. Favorites now exports one native content frame;
its old width/scale/appearance parameters did not configure SwiftUI's environment.
Actual appearance/size matrices must be supplied by a native host rather than
encoded as duplicated OCaml frames with misleading filenames.
