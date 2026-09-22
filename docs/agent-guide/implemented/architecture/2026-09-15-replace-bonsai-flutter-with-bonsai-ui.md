# Replace bonsai-flutter with bonsai-ui

## Implementation status

On 2026-09-16 the user explicitly instructed stopping further implementation of
this document and moving it to `implemented`. That instruction closes this
implementation task at its current state. The remaining items below are recorded
limitations, not authorization to continue implementation automatically.

Implemented work includes the OCaml `bonsai_swiftui` renderer and worker wiring,
the generated native host, Swift platform services and Amplify authentication,
bounded timeline presentation, and the native detail/Capture presentation.
macOS restored the existing local graph; the user confirmed login and sync.
The iPhone application installed and launched, and the user confirmed normal
timeline display. Timeline scroll remounting and detail alignment were corrected.
OCaml build/tests and the native checks recorded in the linked reports passed
within their stated scope.

The lifecycle change does not assert that every original acceptance criterion
passed. Known unfinished work includes rapid-input loss during native handler
updates, reliable native disclosure/accessibility interaction, duplicate Back
presentation, remaining IME/large-text/RTL/VoiceOver and long-history checks,
physical-device auth/sync and verification of the latest source on the device,
final build/performance audits, and removal of obsolete Flutter host/tooling
following completion of relevant native coverage. The installed iPhone artifact
predates the latest layout changes. No remaining requirement is silently recorded
as tested or complete.

See the [coverage map](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/legacy-ui-coverage.md),
[input reproduction](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/composer-input-upstream.md),
and [iPhone evidence](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/iphone-install-launch.json).
The design and chronological checkpoints below are retained as decision history;
this status section is authoritative for the stopping point.

## Problem

Replace the application's bonsai-flutter UI and Flutter host with the local
`bonsai-ui` framework while preserving all non-UI business behavior. The user
accepted the platform, visual direction and bounded implementation scope on
2026-09-16. This proposal records those decisions; the technical feasibility
and release gates below remain required.

The dependency crosses rendering, worker startup, native authentication and
application lifecycle boundaries. A package-name replacement would leave Dart
host responsibilities behind and could change data ownership or startup behavior.

### Evidence and baseline

Inspected on 2026-09-15:

- Journal checkout: `aa3c87705ad1317a57b2106b9fba2e69ec45b935`, plus existing
  uncommitted application, test and Flutter changes. In particular, the current
  block-detail outliner and Journals/Favorites behavior belong to the baseline.
- Target checkout: `/Users/rcmerci/gh-repos/bonsai-ui`, HEAD
  `651e5140e1ef8f91ed2aa2436c965dd0b61c5f3b`, plus uncommitted framework changes.
  Findings describe the inspected working tree, not a published SDK or a
  reproducible commit-only dependency. Select a reproducible revision before coding.
- The target [README](../../../../../bonsai-ui/README.md) names the actual
  packages `bonsai_swiftui`, `bonsai_swiftui_test` and `bonsai_swiftui_tool`, with
  CLI `bonsai-swiftui`. Its backend is SwiftUI; it has removed Flutter/Dart.
  Do not introduce an invented `Bonsai_ui` API or old-name aliases.
- The target supports macOS 26+ Apple Silicon and physical iOS/iPadOS 18+ arm64.
  It excludes Simulator, Intel Mac and Catalyst. Journal currently configures
  macOS 26 and iOS 15 in [bonsai-flutter.sexp](../../../../bonsai-flutter.sexp).
  The target reports unfinished acceptance and SDK publication; local examples
  are evidence of capabilities, not proof that this application already works.
- [UX guidelines](../../../ux-guidelines.md) require at most three dividers,
  immediate reopening of the last graph, and preference for built-in Flutter
  components. The user approved replacing that framework-specific rule with
  preference for built-in bonsai-ui/SwiftUI components on 2026-09-16. Apply that
  approved documentation change before UI implementation; this proposal update
  leaves the guidelines file unchanged.

### Current ownership

| Boundary | Production owner | Migration scope |
| --- | --- | --- |
| Graph types, storage, overlay mutations and sync | `logseq_db_types/`, `logseq_db_storage/`, `logseq_overlay_db/`, `logseq_sync/` | Preserve algorithms, schemas, protocols, effects, encryption and persistence behavior. |
| Worker state and execution | `logseq_db_worker/lib/`, `contract/`, `spec/` | Preserve command/completion semantics, admission, token cache, managed sync, concurrency policy and shutdown. |
| Bonsai worker attachment | `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` and `.mli` | Replace framework service/ID types and dependency wiring only. Keep five push topics, `max_in_flight = 2`, request/result mapping and existing Eio runners. |
| Application business state | `journal_model`, `journal_graph_request`, `journal_graph_projection`, `journal_graph_runtime`, `journal_graph_transport`, `journal_startup`, `journal_calendar`, `journal_time`, `journal_validation` | Keep behavior and public domain contracts. These files are not a general refactoring target. |
| Mixed state and presentation | `application`, `journal_capture`, `journal_detail`, `journal_routes`, `journal_timeline_state` | Preserve state transitions and effect intent; adapt framework types, view construction and UI event bindings where necessary. |
| Rendering | `journal_timeline`, `journal_row`, `journal_header`, `journal_visual_tokens`, `material_icon_catalog`, and view code in mixed modules | Replace Flutter widgets, styling, layout and host interactions with SwiftUI-backed public APIs. |
| Native application services | `flutter/lib/application_host_adapter.dart`, `flutter/lib/main.dart`, Apple Runner sources | Reimplement host glue in Swift while keeping startup, authentication, preferences, lifecycle and termination semantics. |
| App-specific native UI | `flutter/lib/journal_widget_registry.dart` and registered Dart widgets | Port presentation and interaction contracts; preserve domain events consumed by OCaml. |

Not all reducers are framework-free: `journal_capture.mli` exposes text-input
IDs and editing values; `journal_timeline_state.mli` exposes Flutter sparse
extent types; `journal_routes.ml` uses a framework text-session ID. Therefore
"business logic unchanged" means unchanged decisions and observable effects,
with narrowly reviewed UI type substitutions in these mixed modules. It does
not imply that every file containing business state can remain byte-identical.

## Decision

### Confirmed decisions

On 2026-09-16, the user accepted all three exploration questions:

1. Target macOS 26+ Apple Silicon and physical iOS/iPadOS 18+ arm64. Drop iOS
   15-17 support and do not provide a Simulator target. Verify macOS first and
   require physical-iOS acceptance before releasing the complete migration.
2. Adopt native SwiftUI controls, typography, symbols and sheets while preserving
   the current information architecture, actions and business behavior. Replace
   the Flutter-specific preference in `docs/ux-guidelines.md` with preference for
   the most appropriate built-in bonsai-ui/SwiftUI component; retain the
   three-divider limit and immediate last-graph reopening requirements.
3. Authorize the subsequent implementation to edit the build files explicitly
   listed in this proposal, replace the Dart host/auth integration with Swift
   glue and relocate shared native services, while preserving their business
   behavior. This explicitly satisfies the repository's Dune-edit permission
   requirement for the listed files. Protected `spec/` OCaml files and all
   `bonsai_flutter` OCaml files remain outside scope.

The user additionally required the `bonsai-swiftui` CLI tool on 2026-09-16.
Use its installed application workflow for host generation, synchronization,
native builds, launch and iOS toolchain management.

These decisions need no repeated confirmation. They do not establish technical
feasibility: dependency selection, collection mapping, editor ownership,
authentication/session continuity and lifecycle validation remain execution
prerequisites. A new incompatibility must be reported against the relevant gate.

### Approved scope

Use bonsai-ui's SwiftUI runtime as the sole final UI backend. Retain Bonsai and
all domain computation in OCaml. Swift owns native presentation, editing
sessions and platform capabilities. Do not move graph queries, sync, mutation
planning, retry policy or canonical application state into Swift.

Preserve Journals/Favorites navigation, timeline pagination, empty days,
outliner expansion and append, capture and retry, status changes, deletion and
undo, graph selection/cache deletion, E2EE unlock, settings, diagnostics and
error details. Use native typography, symbols, controls and sheet presentation
while retaining the same actions and information hierarchy.

Replace obsolete paths at the final cutover. Do not retain a dual renderer,
Flutter compatibility facade, decoder fallback, data migration or old CLI alias.
Existing database formats, directory selection and Keychain identities remain
the application's current contracts; continuing to use them requires no new
compatibility path.

### Target structure

```text
swift/App.swift + application-owned native services
    BonsaiApplicationView + BonsaiApplicationBridge
        app/native_embed.ml -> Application.app
            Bonsai / Bonsai_swiftui views and handlers
                existing application state and graph requests
                    Bonsai_swiftui.Worker service attachment
                        existing worker -> overlay/storage + sync
```

Proposed new application-owned files live under `swift/`; reusable resources
under `resources/`; native acceptance tests under `apple-tests/`.
`bonsai-swiftui.sexp` uses schema 4, `apple_root apple`, the existing application
entrypoint, and explicit `network` and `sqlite` features. Preserve current bundle
identities, signing and sandbox/Keychain access requirements. Generated Xcode
files under `apple/` follow the target CLI ownership rules; source changes must
not be hidden in generated files.

### Required bonsai-swiftui CLI workflow

Use the installed `bonsai-swiftui` executable from `bonsai_swiftui_tool` as the
application's native build and run entrypoint. Install matching releases of
`bonsai_swiftui`, `bonsai_swiftui_tool` and `bonsai_swiftui_test` through opam.
Record the release/archive identity and matching iOS SDK version. The local
framework checkout is an API reference, not an application build dependency;
do not wire Journal to its `_build` directory, source-path environment variables
or example-build scripts.

The [CLI guide](../../../../../bonsai-ui/docs/swiftui-cli.md) and
[installation guide](../../../../../bonsai-ui/docs/opam-installation.md), checked
on 2026-09-16, document installed-package consumption and automatic iOS object
builds. They report verified local installation, with public package/SDK
publication still pending. Use a reproducible locally delivered opam release
when necessary; do not assume availability in the default opam repository.

For this existing application, prepare the approved Dune dependency changes,
application-owned Swift sources and `bonsai-swiftui.sexp`, preserving the existing
entrypoint and bundle identities. Then adopt from the Journal repository root:

```sh
bonsai-swiftui doctor
bonsai-swiftui init --adopt
bonsai-swiftui sync-host --check
bonsai-swiftui build macos --profile debug
bonsai-swiftui run macos --profile debug
bonsai-swiftui build macos --profile profile
bonsai-swiftui build macos --profile release
```

`init --adopt` preserves existing application sources and does not append Dune
aliases. The CLI owns the generated Xcode project, schemes, plists and
entitlements under `apple/`. Use `bonsai-swiftui sync-host` after supported
configuration changes and require `sync-host --check` to pass. Resolve signing,
authentication package and entitlement requirements through supported host
configuration; if the CLI cannot represent a requirement, record that capability
gap before proceeding. Do not maintain hand-edited generated Xcode files.

For physical iOS, install the matching SDK once if absent, then verify it and
let the CLI compile and validate the application's complete OCaml object:

```sh
bonsai-swiftui toolchain install iphoneos
bonsai-swiftui toolchain verify iphoneos
bonsai-swiftui build ios --profile release --no-codesign
bonsai-swiftui build ios --profile release \
  --development-team "$APPLE_DEVELOPMENT_TEAM"
bonsai-swiftui run ios --profile release \
  --development-team "$APPLE_DEVELOPMENT_TEAM" --device "$DEVICE_ID"
```

The team and device values are deployment inputs, not defaults invented by the
migration. An unsigned build verifies compilation/linking only; signed device
execution remains required. Use `bonsai-swiftui exec -- COMMAND ARGUMENT...` for
native test commands that require CLI-prepared macOS artifacts. Ordinary OCaml
unit tests and formatting may still invoke Dune directly. Build/test scripts
must delegate native artifact preparation to the CLI instead of duplicating its
object verification, staging, Xcode generation or signing pipeline.

### UI mapping and feasibility gates

The interfaces below exist in the inspected target; equivalence still needs
application-specific verification. See its [public API](../../../../../bonsai-ui/ocaml/bonsai_swiftui.mli),
[View API](../../../../../bonsai-ui/ocaml/ui/view.mli),
[native widget API](../../../../../bonsai-ui/ocaml/ui/native_widget.mli) and
[text editing API](../../../../../bonsai-ui/ocaml/ui/text_editing.mli).

| Current surface | Target direction | Required proof |
| --- | --- | --- |
| Material root, header, tabs and routes | `View.Body`, `Toolbar`, `Tabs`, `Navigation_stack` and OCaml route state | Back navigation, graph replacement, modal coverage and scroll-driven root-control visibility dispatch the existing transitions. Native navigation must not become a second route owner. |
| Sliver timeline and bounded row window | `View.Collection` with declared extents and visible-range events | Preserve stable keys, sparse geometry, continuation requests, scroll anchors and the 512 retained-slot / 40 supplied-row / overscan 4 limits. |
| Capture and detail text input | Revisioned `View.text_field` / `View.text_editor` in a launcher/sheet presentation | Preserve session/document/local revision fencing, UTF-16 selection, composition, correction, failed-save draft and retry intent. |
| Swipe/status/delete UI | `View.Swipe_actions`, buttons, menus and sheets | Preserve status choices, delete confirmation where present, staged deletion/undo and scroll-versus-swipe arbitration. |
| Snackbar undo | `Host_effect.show_notice` | Map Action to the existing undo event and other results to their existing non-action consequences. Verify cancellation and timer ownership; do not copy removed `show_snack_bar` result variants. |
| Custom date row, tail fade, root navigation and detail outline | Compose public views first; use a typed `Native_widget.Extension` only for an observed missing native behavior | Match baseline visible-range, reveal/focus, overflow, scrolling and semantic events. A native outliner must not take over expansion, child-loading or mutation state. |
| Material colors/icons and typography presets | `Theme`, `Style`, semantic symbols and application visual tokens | Preserve task-state distinctions, readable hierarchy, preference meaning, accessibility and useful labels without requiring Material glyph assets. |

Two early gates are especially important:

1. **Collection catalog versus retained state.** The target
   `Collection.Catalog.create` requires a complete `keys` list, while Journal's
   timeline keeps `total_count` and `first_retained_index` after evicting old slots.
   Prove a presentation-only mapping for evicted positions, retained keys, sparse
   extents and global/local visible indices. Start with declared geometry to keep
   current sizing behavior. Do not retain all graph rows, synthesize new database
   reads or remove eviction to satisfy the renderer. Measure catalog work as
   history grows; a bounded rendered window alone does not prove bounded memory
   or update cost. If public APIs cannot preserve this contract, record the
   specific framework gap and resolve it before migrating the timeline.
2. **Composer draft ownership.** The target built-in
   `Message_composer` / `Expandable_message_composer` expose an ephemeral native
   draft and text/button observations, not Journal's controlled revisioned value.
   They are not a direct replacement for `Journal_capture.Editor`. Prefer the
   target revisioned editor inside a composed launcher/sheet for that owner.
   Inspect each current composer call site separately: ephemeral presentation
   drafts may use the built-in component only when their existing ownership and
   save/reset behavior match. Do not flatten revisioned edits into strings or
   move canonical draft decisions into Swift merely to reuse a component.

### Worker and native-service continuity

The target [App](../../../../../bonsai-ui/ocaml/runtime/app.mli) and
[Worker](../../../../../bonsai-ui/ocaml/runtime/worker.mli) expose
`create_with_worker`, typed service requests, push events, Eio session contexts,
cancellation and shutdown. This supports retaining the current service design,
but does not establish runtime equivalence. Verify singleton worker lifetime,
backpressure outcomes, topic delivery, stale generations and shutdown delivery
before replacing imports and library dependencies in the service adapter.

Implement a Swift application bridge against the existing
`app/journal_platform.ml` codec and `Logseq_db_worker.Config` startup contract.
The target [application bridge](../../../../../bonsai-ui/docs/application-platform.md)
supports opaque requests/events, connection lifetime and bounded admission.
Port the current payload exactly; do not merge the unrelated exploring
`inherent-logseq-schema-baseline` change into this migration.

Native host work must cover:

- Authentication UI and Cognito capability currently supplied by Amplify Dart:
  authenticated-user lookup, ID-token challenges/correlation and sign-out.
  Use Amplify Swift against the same configured service and currently reachable
  authentication flows. The user permits sign-in the first time online
  authentication is needed after migration. Verify new Swift session persistence
  and generated-host package integration; existing Dart session reuse is not
  required.
- Local account binding before online authentication initialization, immediate
  last-graph rendering, timeline-presented acknowledgment and asynchronous
  online reconciliation. Do not introduce a login gate in front of usable
  local data or a graph-picker flash on a normal warm start.
- Application-support path, canonicalization, startup envelope and
  `typographyPreset` preference. Keep storage destinations and identities exact.
- Background/foreground generations, token revalidation and cooperative quit.
  Bridge events have explicit backpressure; required lifecycle events cannot be
  silently dropped. Verify that the target's presentation/activation gate still
  permits Journal's termination-ready exchange before closing the session.
- Relocate and reuse the non-Flutter logic in
  `flutter/JournalLocalAccountBindingStore.swift` and
  `flutter/JournalE2EECrypto.swift`; preserve Keychain queries, encryption format
  and native exports. Recheck linking of existing OCaml/native crypto and block
  entropy services. Deleting the Flutter directory must not delete these owners.

The user explicitly permits first online reauthentication with Amplify Swift.
Do not convert Dart credentials, add a fallback between SDK stores, or clear
local account binding merely because the new provider has no session. Keep
local data usable before authentication and preserve E2EE secrets in place.

### Execution sequence

| Phase | Work and file boundaries | Exit condition |
| --- | --- | --- |
| 0. Freeze evidence | The platform, visual direction, UX rule replacement and listed build-file scope are approved. Select matching installed framework/CLI releases and iOS SDK, record their source/archive identities, and record the current dirty-tree behavior and test baseline. Apply the approved UX wording before UI implementation. | Reproducible installed dependencies, CLI doctor result and recorded baseline; no unreviewed business change. |
| 1. Prove critical integration | Use disposable external spike applications for worker/Eio, actual Journal native dependency closure, collection eviction, revisioned text, authentication and termination. Read target public APIs; do not bypass `.mli` files. | Each gate above has concrete evidence, or a named blocker. Do not start wholesale view conversion with an unresolved owner mismatch. |
| 2. Replace application host | Add `swift/` sources and schema-4 config; wire `app/native_embed.ml`, the worker adapter and application platform bridge. Relocate shared Swift services. Make only explicitly authorized build-file edits, then use `bonsai-swiftui init --adopt`, `sync-host`, `build` and `run`. | CLI-generated host passes `sync-host --check`; actual Journal worker starts and reopens local data through the CLI-built SwiftUI app; auth/lifecycle/crypto boundaries preserve their contracts. |
| 3. Migrate visible surfaces | Port root/graph states and settings, then rows/timeline/Favorites, then detail/capture/swipe/undo. Adapt mixed UI types without changing domain transitions. Port all current custom Dart widgets' required behavior. | Every baseline flow is reachable and state/effect behavior matches; UI acceptance passes on the agreed platforms. |
| 4. Cut over and remove obsolete paths | Replace test harness imports, native test tooling, package declarations and documentation; remove Flutter sources/config/packages and obsolete icon tooling after relocating required services. | A clean checkout builds and runs with no active Flutter dependency, old CLI path or compatibility adapter. |

Phases are development ordering, not separate shipped backends. Only the final
SwiftUI application is a release candidate. Preserve unrelated working-tree
edits and do not reset the baseline to HEAD.

Expected build changes include `app/dune`, `test/dune`,
`logseq_db_worker/bonsai/dune`, `logseq_db_worker/test/dune`, `dune-project`,
`logseq_journal.opam`, `logseq_db_worker.opam`, native-link/test scripts and
`.gitignore`. Review any additional required build files explicitly before
editing them. The user's 2026-09-16 acceptance explicitly authorizes edits to
these listed build files for this migration, including the listed Dune files.
Do not request that same authorization again.

No OCaml file under any `spec/` directory is an implementation target. If a
protected `.mli` blocks the design, stop and report the exact interface, suggested
change and rationale. Do not modify OCaml files in `bonsai_flutter`. An upstream
framework gap is a separate dependency decision, not permission to patch a
protected contract during application migration.

### Execution checkpoint: 2026-09-16

Phase 0 dependency selection and command-line environment checks are recorded in
the [preflight report](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/README.md).
The approved native-component wording is applied to `docs/ux-guidelines.md`.
All three host packages now use the installed local release with archive SHA-256
`1e4be4d52491d889ff2f848dca358eddfb6687e4ea36f5cbccd929fe0a389f5a`.
The installed iOS framework SDK is `0.1.0~dev.41`; CLI doctor and iPhoneOS
toolchain verification pass. Application source changes present before this
task remain the baseline.

Phase 1 found a blocking generated-host capability gap before application
conversion. The current CLI accepts one global bundle identifier, rejects
platform-specific identifiers and application entitlements, and generates empty
entitlements. Journal currently has different macOS and iOS identifiers and a
required macOS Keychain access group. The installed generator also links only
the framework package, with no application Swift package configuration for the
candidate authentication provider. An external CLI fixture reproduces these
limitations; no generated project workaround is introduced.

The Collection cost probe additionally shows history-sized catalog allocation
and construction cost despite bounded materialized rows. At 100,000 synthetic
keys the OCaml catalog retains approximately 8.17 MB and construction takes
37.9 ms on this machine; at 1,000,000 keys it retains 80.31 MB and takes 421.2 ms.
These are single-run OCaml measurements, not native scroll benchmarks. A bounded
presentation mapping remains unproved and is still a prerequisite for timeline
conversion.

An independent continuation compiled the actual Capture, Detail, Routes and
Worker service interfaces and implementations with only framework import
substitutions in temporary files. All seven existing route/reducer scenarios and
both actual Worker service cases passed. Public runtime diagnostics verified
that the two service sessions share one Worker Domain/backend and that repeated
final shutdown joins once. This narrows interface and Worker-lifetime risk; it
does not establish native editing, topic saturation, authentication or complete
application-host acceptance. Reproduction and input hashes are in the report.

The next dependency decision must cover supported per-platform bundle identity,
application entitlements and Swift package/product configuration in the CLI,
plus a bounded collection strategy. Changes to `bonsai-ui` and a replacement
installed release require separate scope authorization. Authentication session
continuity, actual Journal native dependency closure, remaining worker/editor/
lifecycle gates and physical-device acceptance remain unverified. Do not transition
this proposal to implemented or begin host/view cutover with these gates open.

### Resumed execution: schema 4

The user reported the upstream update. The installed release now has archive
SHA-256 `dbce93fc108e052328dc0b94576930a3c1caceb1d60b84b05e19382f9f1161fc`
and matching iOS framework SDK `0.1.0~dev.42`. Use schema 4 for the implementation;
the earlier schema-3 configuration requirement is superseded by this dependency
update. Independent generation with Journal's existing platform identities and
entitlement inputs passes adoption and read-only synchronization checks. The
three missing CLI configuration surfaces from the earlier checkpoint now exist.

The [follow-up report](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/schema4-followup.md)
records the next gate: Amplify Swift 2.61.0 reads a different credential key and
JSON record format from the currently pinned Dart provider. Its public storage
options cannot select the existing Dart serialization. This candidate therefore
does not satisfy in-place historical session continuity without conversion or
fallback. Pause this authentication path as required above; do not silently
force reauthentication. A user decision on relaxing session continuity or a
different native provider is required before integrating authentication.

The user subsequently approved using Amplify Swift and requiring sign-in the
first time online authentication is needed after migration. This explicitly
supersedes preservation of the existing Dart login session and the prohibition
on that first reauthentication. Preserve local databases, last-opened graph,
local-account binding and E2EE secrets. Do not add credential conversion,
fallback stores or migrations. Local warm-start presentation must still precede
online authentication; lack of a new Swift session must not erase the preserved
local account or gate usable offline data behind sign-in.

The independent native dependency probe now builds the actual Journal worker,
storage, overlay, sync and shared Swift services through the installed CLI on
macOS Debug and unsigned iOS Release (arm64, minimum 18.0). A launched macOS
window displays `Journal worker ready` after a real worker request/response.
This is a minimal application-specific integration probe, not the migrated UI,
online authentication, cooperative termination or physical-device acceptance.

Actual Amplify package resolution remains blocked operationally: two attempts
time out in the CLI's first Xcode dependency-resolution operation after its
fixed 300 seconds. The CLI uses disposable source-package directories and
disables repository caching, so retries repeat large cold downloads. No package
lock is published. The follow-up report provides logs, reproduction and a
concrete upstream request for configurable time limits, reusable downloads and
useful failure diagnostics while preserving atomic lock/host validation.
The earlier configuration-field gap is resolved; this is a distinct execution
failure, not evidence that the chosen authentication SDK is incompatible.

A subsequent user-requested retry completes dependency resolution and reaches
the macOS product build, which fails at Xcode's validation of the AWS
`SmithyCodeGeneratorPlugin`. The user subsequently authorized enabling the
plugin, and an Xcode build of the pinned `AWSCognitoAuthPlugin` succeeded for
My Mac. The next installed-CLI retry again hit its fixed 300-second timeout in
macOS dependency resolution after repeating cold downloads; it did not reach
the product build or publish an application lock. Plugin authorization is no
longer the observed blocker. Configurable operation limits and reusable package
downloads remain the concrete upstream resolver request. The standalone SDK
build does not substitute for CLI product validation on both platforms.

While that external dependency gate remains open, the application-owned Swift
platform and startup codecs are implemented in `swift/`. Cross-language tests
use the unchanged public OCaml codecs to produce requests and validate Swift
responses, lifecycle events and startup configuration. These codecs require no
authentication SDK; Amplify Swift still owns the future native auth capability.
The application entrypoint, domain reducers and generated-host cutover remain
unchanged. This preparation does not waive the collection, editor, lifecycle,
package or physical-device gates.

### Resumed execution: hidden-window lifecycle

A public native bridge fixture now establishes a blocking shutdown prerequisite:
the existing prepare-to-terminate event completes a real worker round trip and
termination-ready request in 0.037 seconds while visible, but remains queued
for over five seconds while the application is hidden. Restoring the window
completes the same queued exchange. This follows the installed framework's
visibility/presentation gate; the public host has no independent lifecycle drain
operation. The [follow-up report](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/schema4-followup.md)
retains the fixture, runtime trace and an upstream API request.

This evidence is a minimal transport failure, not complete Journal shutdown
acceptance. A supported hidden/inactive lifecycle path must be available before
host cutover; forcing foreground presentation or relying on the existing exit
watchdog is not a substitute for cooperative cleanup. No private framework
state, protected interface or application domain behavior was changed.

### Resumed execution: cooperative shutdown release

The user supplied a new installed framework and iOS SDK. All host packages now
use release archive SHA-256
`72ca232e251821d50776f312ee2976c4169d0627703e45dc49d8e567cf3f42a3`;
the matching iOS SDK is `0.1.0~dev.43` with fingerprint
`bff086835f83dffba827f8fa042b6529b2cca69f41678fa713e29fed0176ad9a`.
Doctor, SDK verification, a fresh macOS Debug native dependency build and unsigned
iOS Release build all pass through the installed CLI.

The new public `BonsaiApplicationEvents.beginShutdown` closes the observed
hidden-window transport gap. An updated native fixture completes the actual
worker/platform exchange and teardown in 0.01548 seconds while hidden; repeated
quit preserves one operation, disconnect runs once and closed senders reject
later events. Use this supported terminal path for the eventual native quit
adapter. The [release follow-up](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/shutdown-followup.md)
records evidence and limitations. This supersedes the missing-lifecycle-API
blocker above, without claiming full Journal graph-close or physical-device
acceptance. The same resumed run also completes exact Amplify 2.61.0 dependency
resolution and both macOS/iOS product builds through the installed CLI, which
publishes the fixture's 30-pin lock. `sync-host --check` passes afterward. The
resolver's fixed timeout/cache policy remains unchanged, but the latest package
gate succeeds. Bounded collection/editor gates, actual authentication and final
host integration still require completion.

### Resumed execution: bounded native collection

The observed history-sized built-in catalog is addressed by an application-owned
typed native extension, as permitted by the UI mapping policy. The Swift
geometry stores at most 512 sparse overrides; snapshot validation caps retained
keys at 512 and supplied children at 40. OCaml retains window selection,
overscan 4, data fetching and canonical state. The new renderer observes global
indices and preserves stable-key presentation anchors through insertion,
deletion, eviction and geometry changes. It does not add a second graph owner.

A CLI-built synthetic native fixture displays the million-row tail, keeps its
visible key after deleting an earlier row and evicting 128 cached slots,
preserves that key after row-height changes, processes actual native scrolling,
and resets at graph replacement. macOS Debug and unsigned iOS Release builds
pass. A geometry-only benchmark retains 5,120 incremental heap bytes with 512
shared input overrides at 1,000 through 10,000,000 logical rows; it is not an
application RSS or frame-time measurement. Test-first implementation, numerical
bounds, runtime observations and remaining limitations are recorded in the
[collection report](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/bounded-collection.md).

The bounded presentation strategy is now demonstrated, but production timeline
wiring, real continuation/eviction behavior, navigation/focus, gesture and device
acceptance still require verification. The editor and native platform integration
gates remain open. Do not treat this fixture as the final migrated application.

### Execution checkpoint: revisioned editor

A disposable installed-CLI host now renders the actual `Journal_capture` owner
through the public revisioned text editor. Native macOS observations preserve
Unicode text, UTF-16 emoji selection, failed-save draft and original retry
request; programmatic replacement creates a new session. macOS Debug and unsigned
iOS Release compile. The [editor report](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/revisioned-editor.md)
records the copied-source hashes, public interface suite and acceptance limits.

Current root/Detail composers use ephemeral native drafts with string events;
Detail does not expose a revisioned child-edit API. Final integration must keep
those ownership boundaries explicit. Chinese IME, native correction/stale-event
delivery, keyboard avoidance and full application wiring remain unverified.
Removing a focused editor emitted no blur event in this fixture, so presentation
visibility must not depend on that callback. This checkpoint does not complete
the editor release gate or the application migration.

### Execution checkpoint: native platform services

The Swift platform request owner and concrete Amplify 2.61.0 provider are now
implemented. Tests verify local binding restoration before authentication,
graph-picker reconciliation without a timeline, first-session absence without implicit
sign-out, request correlation, preferences and asynchronous sign-out/connection
fencing. A native macOS acceptance view verifies real Cognito plugin configuration
and repeated configuration after a failing unimplemented-provider run.

Shared crypto and account-binding sources moved to `swift/`; macOS entitlements
moved unchanged to `config/entitlements/`. Existing build/test references were
updated, and crypto, source-boundary and cross-language protocol checks pass.
The production schema-4 configuration and CLI-resolved Swift package lock are
present. The [implementation report](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/native-platform-services.md)
records exact scope and evidence. Final host adoption, authentication UI/events,
OCaml rendering cutover and real application/device acceptance remain incomplete.

### Execution checkpoint: production OCaml renderer

The application renderer and worker attachment now build against the installed
`bonsai_swiftui` release. Timeline rows, headers, native collections, routes,
sheets, symbols and revisioned password entry use target public APIs. The
existing domain decisions remain in OCaml; no Flutter compatibility facade was
introduced. Ten domain/adaptive test programs pass. CLI complete-object builds
pass for actual macOS Debug and iPhoneOS Release application closures.

This does not satisfy the application bundle or UI acceptance gates. The old
semantic test and source boundary assertions still target Flutter and currently
fail. Native sign-in UI, lifecycle delivery, final host entrypoint, obsolete host
removal, full profile builds and physical-device/IME/accessibility acceptance
remain required. [The renderer checkpoint](../../../../test-reports/2026-09-16-bonsai-swiftui-preflight/renderer-cutover.md)
records the verified scope and outstanding work.

### Execution checkpoint: native UI behavior and host entrypoint

The headless UI suite now uses native tree/event APIs and passes sixteen groups.
It reproduced and fixed two view-layer port regressions: extra supporting-line
spacing and a missing account hint. Warm-start/calendar runtime traces remain.
The native event queue is bounded under repeated background/resume backpressure;
authentication form actions and stale completion fencing pass native-owner tests.

The production Swift entrypoint, real Amplify sign-in/challenge/reset adapters,
native auth forms, Hub observation and scene lifecycle hooks are implemented.
Local binding bypasses first-session authentication presentation so the offline
graph stays visible. macOS quit uses the supported cooperative shutdown path.
Host adoption and synchronization pass; final bundle builds and actual lifecycle,
login, IME, accessibility and physical-iOS acceptance remain open. See
[the native UI and host checkpoint](../../../../test-reports/2026-09-16-bonsai-swiftui-preflight/native-ui-and-host.md).

## Alternatives considered

### Rename packages and retain the current widget construction

Rejected: the target uses `View`/`Body`/`Viewport`, native navigation and different
host services. Material widgets, Dart registrations and bootstrap cannot survive
through import changes alone.

### Keep Flutter as a host or a fallback renderer

Rejected: this fails the requested replacement and retains obsolete paths. It
also leaves authentication and lifecycle coupled to the removed framework.

### Rewrite the application in SwiftUI and move reducers into Swift

Rejected: it changes business ownership and requires a second implementation of
already-tested graph, editor and sync decisions.

### Wait for a published SDK before any integration work

Useful if an installable release cannot satisfy the feasibility gates. The
selected approach is to consume matching installed packages through the CLI,
using a reproducible local opam release while public publication is pending.
Release packaging and physical-device verification remain explicit gates. This
document does not claim that publication or application feasibility is complete.

## Validation

The following are the original acceptance criteria. Their outstanding portions
remain limitations at the user-directed stopping point described above.

### Business invariants

- The same public domain events and completions produce the same state and
  requested effects. Existing worker/sync/overlay/storage regression assertions
  remain intact. No schema, outbox, retry, mutation identity, ordering or E2EE
  behavior changes enter this work.
- Warm start opens the same last graph immediately, including offline startup;
  graph switching, sign-out, cache deletion, reconnect and shutdown retain the
  current ownership and failure behavior.
- Capture, task status, detail editing/append, delete/undo, Favorites, pagination
  and stale-response handling retain their current results and error recovery.
- Existing databases, preferences and native secrets are used in place through
  unchanged contracts. The approved first online sign-in initializes the new
  Amplify Swift session; no credential conversion, duplicate local data store
  or account-binding reset is introduced.

### UI and runtime verification

- macOS and the agreed physical iOS/iPadOS targets run the actual Journal OCaml
  application, including native storage, networking and crypto dependencies.
  Build success alone is not physical-device acceptance.
- Exercise timeline eviction and continuation beyond 512 slots, fast scroll,
  resize, deletion before the anchor, navigation return and graph replacement.
  Preserve bounded supplied rows and record catalog memory/update cost separately.
- Exercise rapid edits, Chinese IME, emoji/UTF-16 selection, focus, keyboard
  avoidance, failed-save retry, close/reopen and stale editor events.
- Verify light/dark appearance, large text, high contrast, RTL, reduced motion,
  VoiceOver, narrow windows and iPhone/iPad layout. Keep actions reachable and
  enforce the three-divider limit under the approved native-component UX rule.
- Verify auth/token challenge correlation, native bridge saturation/lifetime,
  background/foreground and cooperative termination through the actual host.

### Test and release boundaries

- Retain existing domain tests. Adapt framework-specific test harnesses to
  `bonsai_swiftui_test` and port relevant Dart/native UI assertions to the new
  host before removing their obsolete harnesses. This is not an opportunity to
  delete inconvenient regression coverage.
- For a discovered regression, identify its production state owner and reproduce
  through public pure reducer events/completions first. If that reproduces it,
  add only pure reducer coverage. Otherwise document the missing ownership
  boundary and test the narrowest executing layer. Do not inject an already
  incorrect external response as a purported pure reproduction or duplicate a
  reducer case in runner, persistence, transport, integration, E2E or UI tests.
- For implementation, run appropriate OCaml build/tests/format checks and native
  bridge/UI checks. Require `bonsai-swiftui sync-host --check`, CLI builds for all
  three macOS profiles, `toolchain verify iphoneos`, CLI iOS builds and signed
  device launch/acceptance. Record commands and results against the selected
  installed package/SDK identities. Revalidate the actual Journal iOS 18
  dependency closure; example apps do not cover its complete library set.
- From a clean application checkout, the installed CLI and dependencies generate,
  build and launch the app without a framework checkout, source-path overrides,
  hand-maintained Xcode project or parallel native build pipeline.
- A source/dependency audit finds no active `bonsai_flutter`/Flutter import,
  Dart host, old configuration, old environment-variable dependency or Material
  font-only tooling. Historical decision documents and reports remain history.
  Static GMP and crypto checks remain with their updated paths.
- Record baseline-versus-final startup, scrolling and memory observations on the
  same machine/device and dataset; investigate material regressions before
  cutover. Run `spec-dev-tool check --all` before completing repository work.

All exploration questions were answered on 2026-09-16. The criteria above
record the intended full release gate. The user subsequently directed closing
this document as implemented at the current checkpoint; see Implementation
status for verified results and the explicitly unfinished portions.

### macOS account and scrolling follow-up

The user confirmed successful first Amplify Swift sign-in and synchronization
in the actual macOS host with the existing local graph. A subsequent scrolling
regression was reproduced at the public renderer boundary: hiding navigation
removed an overlay ancestor and remounted the timeline collection. The fix
retains the ancestor and viewport dimensions; repeated direction reversals
preserve the collection node and actual macOS scroll position. The focused
[verification report](../../../test-reports/2026-09-16-bonsai-swiftui-preflight/timeline-scroll-identity.md)
records reducer ownership, failing/passing regression and native observations.
The first iOS launch was rejected for signing/profile trust. A later reinstall
and launch succeeded, and the user confirmed normal timeline display. Device
authentication/sync, latest-source installation and final renderer cutover
remain unverified or unfinished.

## Consequences

The current worktree is retained at the user-directed stopping point. Further
implementation or release acceptance requires a new user instruction; the
following architectural risks remain relevant.

- **Platform reduction:** moving from an iOS 15 minimum to iOS 18 excludes older
  installations. Simulator is not an available verification substitute.
- **Moving upstream:** both checkouts contain uncommitted changes, and the target
  explicitly reports unfinished acceptance/publication. Pinning HEAD alone may
  omit interfaces used in this exploration.
- **Hidden behavior changes:** application and host files mix UI with business
  state. Whole-file rewrites and blanket string replacements can alter retry,
  auth, pagination or editing behavior without appearing to touch core packages.
- **Collection mismatch:** a full key catalog can reintroduce history-sized work
  even while only a small number of views are mounted.
- **Text and native gestures:** ephemeral composer semantics, IME composition,
  swipe arbitration and native sheet dismissal need application-level evidence.
- **Authentication and storage identity:** a different SDK, bundle identity or
  entitlement can make existing sessions or data inaccessible. Incompatibility
  must be surfaced rather than hidden by fallback, forced reset or migration.
- **Host lifecycle gating:** visibility-gated bridge requests and asynchronous
  shutdown can conflict with the existing quit handshake or offline-first start.
- **Build scope and protected interfaces:** the listed build changes are
  authorized. Additional Dune files still require explicit authorization;
  protected spec interfaces remain outside scope and may expose a technical
  blocker during integration.
