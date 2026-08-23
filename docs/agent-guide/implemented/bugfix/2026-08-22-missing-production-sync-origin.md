# Missing Production Sync Origin

## Problem

The production adapter obtains its sync origin only from
String.fromEnvironment with the LOGSEQ_SYNC_BASE_URL key.

An ordinary bonsai-flutter build macos or bonsai-flutter run macos invocation
does not provide that compile-time definition, and the repository contains no
production build wrapper or documented command that supplies it. The shell
environment was also unset during the macOS end-to-end run. A shell environment
variable alone would not satisfy String.fromEnvironment; Flutter must receive a
matching dart-define at compile time.

After Amplify configuration completes, this path fails application payload
creation with LOGSEQ_SYNC_BASE_URL must name the managed sync origin. The App
therefore cannot reach graph discovery from its standard project build command.

The end-to-end test could proceed only by explicitly compiling with the production
origin https://api.logseq.io, which matches the current upstream Logseq db-sync
default.

## Decision

Make the production sync origin deterministic by defining the fixed application
URL https://api.logseq.io in production configuration. Standard Debug, Profile,
and Release builds must use this URL without requiring a dart-define, shell
variable, or environment-specific selection.

Keep test injection through createBonsaiFlutterHostAdapter for isolated tests.
Remove the implicit unsupported path in which a production bundle contains no
origin.

### Implementation outcome

The production host factory now supplies the single fixed origin
`https://api.logseq.io`. Startup payloads contain only that validated origin and
mechanical host facts; the obsolete `LOGSEQ_SYNC_BASE_URL` compile-time path was
removed. Tests retain explicit constructor/factory injection for isolated origins.

Debug, Profile, and Release macOS builds all completed without environment defines.
A real signed-in launch discovered the production 13-graph catalog and opened the
retained production mirror, confirming the fixed origin reaches the managed sync
service.

## Alternatives considered

### Read the process environment at runtime

Rejected for distributed macOS applications because Finder launches do not inherit
the developer shell environment, and the production origin is deployment metadata
rather than user session state.

### Keep the current runtime error

Rejected because the standard build command succeeds and produces an unusable App.
This is a packaging/configuration failure and should be detected before launch.

### Select the origin per release environment

Rejected because this App has one production sync service. Build-time environment
selection would add configuration paths that are not required by the deployment
model and could produce a valid bundle pointed at the wrong service.

## Acceptance criteria

- The documented macOS Debug, Profile, and Release build workflows all use the
  fixed https://api.logseq.io origin.
- A standard supported build reaches graph discovery without an extra undocumented
  flag.
- Unit tests can still inject an isolated origin without contacting production.
- Production startup does not read LOGSEQ_SYNC_BASE_URL from a dart-define or the
  process environment.

## Consequences

- Standard production bundles always target the managed Logseq sync service.
- Test suites can still inject isolated origins without creating a production
  environment-selection path.
- Changing the production deployment origin now requires an intentional source
  and release decision.

## Risks

- Changing the production service URL requires an application release.
- Test-only origin injection must remain structurally separate from production
  configuration so it cannot override the shipped URL.

## Questions

- None. Production builds use the fixed https://api.logseq.io origin.
