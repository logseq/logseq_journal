# Stable Sliver Item Keys

## Problem

The journal timeline passes unkeyed widgets to `Sliver.varied_extent`. The
updated `bonsai_flutter` API requires every item to be a `Widget.Keyed.t`, and
the missing identity also prevents the runtime from matching an overlapping
logical slot with its existing native node when the visible window shifts.
Continuous macOS scrolling currently emits patches of about 60 KB and dirties
more than 800 nodes per runtime frame, contributing to visible frame latency.

## Decision

Key each direct sliver item with the stable logical slot key exposed by
`Journal_timeline_state.slot_key`. The key is applied after the complete slot
widget is built so it is the root identity observed by sliver reconciliation.
Application-view tests cover root-key presence, uniqueness, the expected
logical key, and mounted-node identity preservation across an overlapping
window shift.

The selective macOS benchmark used the same debug Flutter host and release
OCaml artifact as the baseline. For steady scrolling, median patch size fell
from 60,319 to 5,944 bytes and median dirty nodes fell from 831 to 124. Median
Flutter frame time fell from 18.378 to 13.089 milliseconds, p95 fell from
34.708 to 19.294 milliseconds, and frames over 16.7 milliseconds fell from 69
to 16.

For high-velocity scrolling, median patch size fell from 61,133 to 9,674 bytes
and median dirty nodes fell from 843 to 174. Median Flutter frame time fell
from 16.098 to 12.609 milliseconds, p95 fell from 22.544 to 17.398
milliseconds, and frames over 16.7 milliseconds fell from 13 to 3.

Adopt stable logical slot keys as the complete fix for the current sliver
reconciliation problem. Defer window hysteresis and handler stabilization
unless subsequent profile-host or Instruments measurements show a remaining
user-visible problem. The current debug-host remainder is dominated by Flutter
build time, not by full-window patch churn.

## Alternatives considered

### Index-based keys

Keys derived from the current child index are rejected because the same logical
slot moves to another child index as the window shifts, defeating identity
preservation.

### Immediate window hysteresis

Changing windowing behavior before measuring stable keys is rejected because
it combines two independent variables and makes the benchmark result harder to
attribute. The keyed result removed most patch and dirty-node churn without a
windowing behavior change.

### Immediate handler stabilization

Caching per-row event handlers is rejected for this change because stable keys
already removed the dominant full-window reconciliation cost. Handler identity
can be measured as a separate experiment if profile-host evidence requires it.

## Acceptance criteria

- Every direct `Sliver.varied_extent` item has a unique root key derived from
  its logical timeline slot.
- Logical slots shared by consecutive visible windows retain their mounted
  node identities.
- The focused application-view test, OCaml tests, Flutter tests, and static
  analysis pass.
- The macOS continuous-scroll benchmark reports post-change patch, dirty-node,
  and frame-timing metrics against the pre-change baseline.
- Any decision about additional hysteresis or handler stabilization is based on
  the measured result.

## Consequences

`Sliver.varied_extent` now receives only keyed direct items, and overlapping
logical slots preserve their mounted node identities as the materialized window
moves. The keyed result removes most full-window reconciliation work without
changing window size, pagination demand, extent geometry, event coalescing, or
handler behavior.

No window hysteresis or handler caching is included in this change. Those
remain isolated future experiments instead of additional complexity carried by
the current fix.

## Risks

- Incorrectly duplicated slot keys could cause native element reuse for the
  wrong timeline item; the uniqueness and logical-key tests guard this
  contract.
- Stable keys do not remove all changed props or newly allocated handler
  identities, so a smaller amount of patch work remains.
