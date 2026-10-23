# Timeline Return Top

## Problem

Selecting Timeline again currently does nothing. Users need to return to the
first journal date without animating hundreds of intermediate rows.

## Proposal

Reuse the existing token-scoped native list scroll request. Repeated selection
of the visible Journals root requests its first date, including empty Today.
The native List fades its content out for 90 ms, jumps without scroll animation,
then fades in for 150 ms once native scroll geometry confirms the top layout.
Keep navigation and toolbar chrome outside the transition. Coalesce pending
requests, cancel on native user interaction or disappearance, and skip fading
at the top or with Reduce Motion. Keep Capture's existing direct jump.

## Alternatives considered

### Animated long scroll

Rejected because it traverses intermediate rows and can amplify layout work.

### Replacing the list or introducing height caches

Rejected because the current native List must retain its identity and ownership.

## Acceptance criteria

- Reselecting visible Timeline returns to the first date, including empty Today.
- Long lists and image rows use fade/jump/fade with stable chrome.
- Repeated taps coalesce; drag/navigation interruption cancels stale callbacks.
- Already-top and Reduce Motion do not repeat animated transitions.
- Final source passes existing tests, independent review, Simulator acceptance,
  a real recording, and separate unrecorded performance sampling.

## Risks

- SwiftUI List layout may stall independently of animation; measure and diagnose
  rather than accepting a fade as evidence of main-thread responsiveness.
- Simulator host-restamp remains experimental with cross_abi_validated=false.

## Decision

The user selected scheme 1 and approved the minimal existing-List UIScrollView
adapter after public SwiftUI section anchoring and top-edge requests failed the
actual content-origin check. Resolve that scroll view once per mount, perform a
native nonanimated offset-to-inset jump, and finish native layout before reveal.
Preserve List identity, delegate, datasource, row sizing and data ownership.

Keep animation phase in the adapter so each phase does not publish a new List
model. Separate scroll commands from prepared row snapshots so command-only
changes preserve row identities. Reset interaction state on disappearance and
context replacement; the actual native pan state still gates new requests.

Follow-up review requires a distinct native-list `scroll_request` property,
including matching OCaml/Swift schemas and fingerprints. Publish command changes
through a mounted subscription without changing the Timeline content revision,
serializing its rows, decoding its content or publishing the Swift content owner.
Resolve the top intent against the actual presented first section, including
future dates and synthetic empty Today. Preserve Capture's direct row target.

The final PR111 baseline retains synchronous native layout. Removing that call
was an unsuccessful control experiment, then it was restored to avoid revealing
before cell layout completed. Its measured stall remains unresolved. Future
measurements must start at the actual native command entry before OCaml work and
Swift decoding, and include command clearance after animation completion.

The recording and formal PR are authorized; merge and TestFlight are excluded.
Remaining native List layout stalls must be disclosed with separate unrecorded
measurements. Fade completion is not proof of responsiveness.
