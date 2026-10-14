# Timeline relative dates and empty Detail title

## Problem

Timeline dates need immediate today/yesterday context. Block Detail has a redundant visible title.

## Decision

Timeline appends lowercase `today` and `yesterday` after the corresponding dates using the native `.subheadline` style alongside the existing `.title2` date. Other dates remain unchanged. Detail supplies an empty navigation title while retaining the native bar, back button and options menu.

## Authorization and ownership

The delegated user request explicitly supplies the labels, local calendar semantics, unchanged date format, soft header, accessibility, dynamic sizing, update reuse and isolated PR scope. The follow-up explicitly authorizes removing `Block`, creating a formal PR, independent review and CI tracking without merging. No design questions remain.

Application passes its sampled `Journal_calendar.local_day` as `Journal_timeline.view` current_day, so labels update immediately on the existing calendar refresh path, even while feed refresh is pending or has failed. Root presentation equality includes the local day as well as the time-zone projection fingerprint. `Journal_timeline_state.today` remains the existing feed/timestamp owner and the standalone component fallback. `Journal_calendar.relative_day_label` compares validated Gregorian civil day ordinals, without instant subtraction or extra timers. `Journal_header` carries only presentation props to the existing SwiftUI SectionDate.

## Alternatives considered

### Subtract 86400 seconds

Rejected because local days can contain 23 or 25 hours and time zone changes alter local dates.

### Add a SwiftUI date timer

Rejected because the OCaml calendar already owns local date updates.

## Consequences

- Today/yesterday labels are correct across month, leap day, year, local midnight, time zone and DST boundaries; older/future dates have no label.
- Existing date text, native soft section behavior and header accessibility remain; suffix uses dynamic smaller text.
- Detail has no visible `Block` title; back and options remain available.
- No protected Dune/spec interfaces/locks or mldoc changes enter the PR.
- Native presentation tests cover civil boundaries and updates; all 86 application-view tests, existing calendar/Timeline tests and source-boundary checks pass. The Simulator app builds with the pinned lui source. An isolated iPhone 13 / iOS 26.1 synthetic host verifies actual date labels, next-day/year changes, maximum Dynamic Type, empty Detail title, native Back and menu selection. The host mounts the production components; it does not exercise a personal graph or real device.

## Risks

- A longer header has less horizontal room; verify compact and accessibility dynamic sizes on Simulator.

## Regression ownership

Calendar installation belongs to Application's private effect closure. Its public pure `Root_navigation` events do not expose calendar installation or delayed feed completion; the new regression therefore uses the existing `For_testing.app_with_service` boundary, injected sampler and real foreground packets. It blocks the actual fixture feed request and then fails it, rather than injecting an already incorrect projection. Day and zone cases demonstrate suffix changes before completion, retention after failure, and no added feed query. The independent review found this gap in head `6f8f026`; the initial tests failed with `today` where `yesterday` was required before the fix.
