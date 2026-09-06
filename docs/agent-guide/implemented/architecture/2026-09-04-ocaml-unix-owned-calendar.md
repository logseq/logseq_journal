# OCaml Unix-Owned Calendar

## Problem

Application currently obtains every calendar snapshot through a multi-runtime
round trip:

1. OCaml sends `Journal_platform.get_calendar_request` through the Bonsai
   application-platform boundary.
2. Dart decodes the LJP2 request and asks `_NativeStartupEnvironment` for a
   snapshot.
3. Flutter invokes `getStartupEnvironment` on the
   `logseq_journal/platform` method channel.
4. Swift reads `Date`, `Locale.current`, `TimeZone.current`, and
   `Calendar.current` and returns a map.
5. Dart validates and re-encodes that map as an LJP1 payload inside an LJP2
   response.
6. OCaml decodes and validates the response before Timeline startup can
   continue.

The same boundary is used again for foreground resume, system calendar-change
events, and localized journal-day headings. Calendar acquisition is therefore a
required asynchronous platform dependency even though OCaml's `Unix` library is
already available in the native application and can read the process clock and
convert instants through the process-local time zone.

This indirection has already contributed to a permanent `Restoring local`
startup stall: graph restoration and the asynchronous calendar response were
previously allowed to race even though Timeline projection required both. The
calendar wire codec, Dart snapshot cache, native snapshot construction, native
notification observers, and tests also duplicate validation and generation
ownership across three languages.

The required product behavior is narrower than the current bridge implies. The
application needs to know the current local Gregorian day and minute, project
stored instants into the local time zone, refresh the Timeline when the local day
or time-zone interpretation changes, create captures with a coherent local time,
and render a stable heading for each journal day. It does not read calendar
accounts, events, or reminders.

## Proposal

Move calendar ownership into OCaml and use the OCaml `Unix` library as the
production clock and local-time implementation. The default and only production
zone is the host process's local time zone. Do not preserve the existing
Swift/Dart calendar protocol as a fallback.

### Define an OCaml-owned local calendar

Replace the platform-decoded `Journal_calendar.t` with an OCaml-created value.
The calendar module should accept an injected clock for tests and use
`Unix.gettimeofday` in production. For one sampled instant it should call
`Unix.localtime` exactly once and derive:

- `instant_unix_ms` from the sampled Unix time;
- `local_day` as Gregorian `YYYYMMDD` from `Unix.tm_year`, `tm_mon`, and
  `tm_mday`;
- `local_minute_of_day` from `tm_hour` and `tm_min`;
- an OCaml-owned monotonically increasing generation used only to fence stale
  calendar-dependent work.

The new value should not claim to know an IANA time-zone identifier or a numeric
offset that `Unix.localtime` does not expose. Remove `locale`, `time_zone_id`,
`utc_offset_seconds`, and `lifecycle_generation` from `Journal_calendar.t` unless
a remaining consumer demonstrates that it needs the fact rather than the local
conversion result. Do not substitute sentinel identifiers such as `"local"` and
do not retain compatibility fields.

Change `Journal_time` and graph projection to convert each stored instant with
`Unix.localtime`. A block is therefore presented in the machine's current local
time zone, including the system C library's historical daylight-saving rule for
that instant. Remove the current `feed_projection_context` zone-ID/offset pair;
its semantic identity becomes the locally derived day mapping needed by the
loaded feed.

### Make startup synchronous with respect to calendar facts

Application should construct the first calendar value directly in OCaml before
managed local-account restoration begins. The startup dependency remains
explicit, but it is no longer an application-platform request and cannot wait on
Flutter or Swift.

The intended ordering is:

```text
Unix.gettimeofday + Unix.localtime
  -> install Journal_calendar in Application and Journal_graph_runtime
  -> restore local account
  -> open selected graph
  -> load the initial local Timeline
```

Calendar construction failures must produce one typed startup error. They must
not silently fall back to UTC, a cached zone, a platform request, or fabricated
date facts.

### Re-sample local calendar state inside OCaml

Replace native calendar-change events with OCaml re-sampling:

- sample once during startup;
- sample immediately when the existing typed foreground-resume event reaches
  Application;
- sample before admitting a capture or detail child creation.

Do not add periodic foreground polling. An application that remains foregrounded
and idle across midnight or a device-zone change retains its current presentation
until the next foreground resume or capture boundary. The capture boundary must
apply any calendar refresh before choosing the Journal page or creation time.

Each sample compares semantic facts rather than raw generation:

- a changed `local_day` refreshes the meaning of Today and the initial feed;
- a changed local projection for representative instants refreshes projected
  block times and the feed;
- an unchanged local day and projection only updates the current instant and
  minute;
- a newer generation fences late feed or heading work but is not itself a reason
  to blank or reload Timeline.

The implementation must define a testable local-zone fingerprint without relying
on an IANA identifier. One candidate is a bounded tuple of local conversions for
the sampled instant and nearby instants spanning the current feed window. This is
an implementation detail to validate against daylight-saving transitions; it
must not become a fake public time-zone identifier.

### Move journal-day heading formatting into OCaml

Remove `format_journal_days_request` and
`decode_formatted_journal_days` from `Journal_platform`. Application should format
validated Gregorian journal days locally. The initial implementation should use
the exact deterministic format `YYYY-MM-DD, EEE`, for example
`2026-09-04, Fri`. Weekday abbreviations are the fixed English values `Mon`,
`Tue`, `Wed`, `Thu`, `Fri`, `Sat`, and `Sun`; they do not depend on the process
locale. Formatting must never block Timeline readiness on a native formatter.

Formatting results no longer need calendar-response generations or the Dart
snapshot retention map. System-localized calendar headings are intentionally
removed. Any future localization must be a separate explicit capability rather
than being hidden inside the calendar clock API.

### Delete the obsolete platform surface

After OCaml owns calendar creation, refresh, projection, and heading formatting,
delete the complete old calendar path:

- `Journal_platform.get_calendar_request`, `decode_calendar`, calendar reason
  types, and formatted-day request/response codecs;
- the Dart `JournalCalendarSnapshot`, `_CalendarFacts`, calendar tags/codecs,
  snapshot providers, generation cache, `refresh`, and calendar handling in
  `JournalApplicationPlatform`;
- calendar fields and `formatJournalDays` from `_NativeStartupEnvironment` and
  `ApplicationHostAdapter`;
- Swift calendar snapshot construction, `formatJournalDays`, and native calendar
  notification observers on macOS and iOS;
- tests whose only purpose is checking the deleted cross-language calendar wire
  format.

Keep unrelated platform capabilities intact: the Application Support path,
local-account binding, preferences, authentication, termination, Flutter
presentation acknowledgement, and typed foreground/background network lifecycle
still belong to their current owners. `getStartupEnvironment` may remain for
non-calendar startup facts, but it must no longer carry calendar fields.

Add direct OCaml tests for all calendar behavior before deleting platform tests.
Tests must use injected instants and a controlled process-local time zone where
the test runner supports it. They must cover midnight, negative Unix instants,
leap days, daylight-saving gaps and folds, a changed local zone, stale-generation
fencing, resume re-sampling, capture-time re-sampling, and deterministic heading
formatting. Native macOS and iOS builds must prove that `Unix.gettimeofday` and
`Unix.localtime` link and behave inside the embedded OCaml runtime.

## Decision

Adopt the OCaml Unix-owned calendar in one direct cutover. Production samples
the process clock with `Unix.gettimeofday`, converts local civil time and stored
instants with `Unix.localtime`, and owns the monotonically increasing generation
used to fence calendar-dependent work. Startup installs the first successful
sample before managed graph restoration, while foreground resume, Capture, and
detail-child admission re-sample at their existing lifecycle boundaries.

Use an opaque, normalized fingerprint of representative local conversions to
detect projection-rule changes without exposing a fabricated time-zone identity
or treating raw generation changes as Timeline refreshes. Format journal-day
headings synchronously in OCaml as `YYYY-MM-DD, EEE` with fixed English weekday
abbreviations.

Delete the calendar snapshot and heading-formatting protocol across OCaml, Dart,
and Swift, including its cache, providers, notification observers, codecs, and
protocol-only tests. Retain the existing non-calendar platform capabilities and
typed network lifecycle without compatibility fields, fallback paths, or native
calendar observers.

## Alternatives considered

### Keep the current Swift/Flutter calendar bridge

This preserves immediate Apple notifications, Foundation locale formatting, and
IANA time-zone identifiers, but retains the startup round trip, three-language
codec surface, duplicated validation, and the calendar dependency that this
exploration is intended to remove.

### Call Apple APIs directly from OCaml

OCaml could use C or Objective-C stubs for Foundation calendar APIs. This removes
the Dart round trip but does not remove the Apple calendar dependency, adds FFI
and callback ownership to the OCaml runtime, and still requires separate iOS and
macOS lifecycle integration. It does not satisfy the requested Unix-library
implementation.

### Add an OCaml time-zone database library

An IANA tzdb library such as Timedesc could provide explicit zone identifiers and
deterministic historical rules. It adds a second time-zone database that must be
updated and reconciled with host settings. It is unnecessary for the requested
default-local-zone behavior, although it may become appropriate if users later
choose zones independently of the device.

### Keep native change notifications but compute snapshots in OCaml

Swift could continue emitting time-zone, locale, and day-change signals while
OCaml performs all conversions. This reduces snapshot traffic but retains the
native calendar observer surface and makes the OCaml implementation dependent on
Apple-only notification behavior. Periodic and lifecycle-triggered OCaml
re-sampling provides one portable owner instead.

### Use UTC everywhere

UTC would make conversion deterministic and eliminate local-zone refreshes, but a
Journal application must follow the user's local day. It does not satisfy the
default-local-time-zone requirement.

## Acceptance criteria

- Initial Timeline startup obtains all required calendar facts without an
  application-platform request, Flutter method-channel call, or Swift calendar
  API call.
- macOS and iOS use the embedded OCaml runtime's `Unix.gettimeofday` and
  `Unix.localtime` successfully in debug and release builds.
- The most recently selected local graph still opens directly and reaches a
  presented Timeline without `Restoring local` stalling.
- Journal Today selection, capture timestamps, detail child timestamps, and block
  time projection use the process-local time zone.
- A continuously foregrounded idle application performs no periodic calendar
  polling. Crossing local midnight or changing the device zone is applied on the
  next foreground resume or capture boundary.
- Resuming after a local-day or local-zone change re-samples before new
  calendar-dependent work is admitted.
- A capture started after a local-day or local-zone change re-samples before
  choosing its Journal page and creation time.
- Daylight-saving gaps and folds use the host C library's local conversion and do
  not fabricate impossible local times.
- Journal-day headings use the exact OCaml-owned `YYYY-MM-DD, EEE` format with
  fixed English weekday abbreviations and never gate Timeline readiness on native
  work.
- Changing the device time zone re-projects visible historical block times into
  the current local zone at the next refresh, while each block remains assigned
  to its stored Journal page.
- `Journal_calendar.t` and `Journal_time.t` contain only facts owned or derived by
  OCaml; obsolete locale, zone-ID, offset, and lifecycle compatibility fields are
  removed.
- The LJP2 calendar and formatted-day tags, Dart snapshot/cache/provider code,
  Swift snapshot/formatter/observer code, and their protocol-only tests are
  deleted rather than retained as fallbacks.
- Non-calendar platform features and network lifecycle behavior remain unchanged.
- Focused calendar, time, projection, startup, capture, and resume tests; the full
  OCaml and Flutter suites; source-boundary checks; formatting; Flutter analysis;
  macOS runtime walkthrough; and iOS build pass.
- No OCaml file under `spec/`, Dune file, or bonsai_flutter repository file is
  modified.

## Risks

- `Unix.localtime` exposes converted fields but not an IANA zone identifier or
  UTC offset. Removing those values changes the current `Journal_time` and graph
  projection contracts and requires auditing every comparison and test that
  currently treats them as identity.
- The process C library's local-zone state is global. Tests that set `TZ` can
  interfere with parallel tests, and mobile runtimes may differ in whether
  environment-variable changes are honored. Production uses the device-local
  zone; deterministic test injection should avoid mutating global state whenever
  possible.
- Without polling or native notifications, a continuously foregrounded idle
  application can retain a stale Today heading and historical time projection for
  an unbounded period. Foreground resume and capture are the only refresh
  boundaries by decision.
- `Unix.localtime` does not provide localized day headings. Foundation-localized
  formatting is intentionally replaced by deterministic English weekday
  abbreviations.
- Native calendar notifications currently refresh immediately on system changes.
  Removing them means correctness depends on startup, resume, and capture-boundary
  sampling remaining live.
- Direct use of ambient local time can make tests and results machine-dependent
  unless clock and local conversion are injected at the calendar boundary.
- iOS and macOS use Darwin libc, but the iPhoneOS cross-link and App Store runtime
  path must be verified before the old host implementation is deleted.
- A zone change can alter historical block display times as well as Today. The
  refresh must update visible projections without clearing an already-presented
  Timeline or losing scroll/expansion state.

## Consequences

Calendar startup no longer waits for Flutter or Swift. The Application owns one
typed sample, installs it into the graph runtime, and starts managed restoration
only after that prerequisite succeeds. Failed sampling produces a typed startup
or capture error instead of UTC, cached, or fabricated calendar facts.

Timeline refresh identity is now the current local day plus an opaque local
projection fingerprint. Minute-only and raw-generation changes update the
current calendar without blanking or reloading the Timeline, while local-day and
projection changes refresh it. Capture and child requests carry the sampled
generation and fail closed before Worker I/O if later work uses a stale value.

Stored block instants are projected through the current process-local converter,
including historical daylight-saving behavior, while their stored Journal page
assignment remains unchanged. Journal headings are deterministic and no longer
localized by Foundation.

The App performs no calendar application-platform request and the Flutter host
contains no calendar cache or refresh path. Apple startup environments retain
only non-calendar facts, and foreground/background network lifecycle remains a
separate typed capability. macOS and iOS debug and release builds link the Unix
calendar calls through the embedded OCaml runtime.
