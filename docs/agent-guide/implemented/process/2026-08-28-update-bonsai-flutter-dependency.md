# Update Bonsai Flutter Dependency

## Problem

The project pins `bonsai_flutter` and `bonsai_flutter_test` to revision
`1755441c24d718206a3d61af0882c0727f810d46`, while upstream `main` and the
installed host packages are at revision
`f4377637a33cdc450204734d033bbcbb861e06bb`. The project lockfiles therefore do
not reproduce the framework used by the local build tool and omit the upstream
Flutter integration, protocol, Material component, and native-widget fixes made
since the pinned revision.

## Proposal

Update every project-owned `bonsai_flutter` and `bonsai_flutter_test` source pin
to the committed upstream revision
`f4377637a33cdc450204734d033bbcbb861e06bb`. Synchronize the generated Flutter
host packages with the installed `bonsai-flutter` tool, regenerate dependency
locks through the project toolchain where required, and adapt application code
only if the new framework exposes a compile-time or tested behavioral break.

Do not modify the `bonsai_flutter` repository, add compatibility paths, or change
unrelated dependency versions. Preserve the existing uncommitted application,
sync-package, and lockfile work in this worktree.

## Decision

Pin `bonsai_flutter` and `bonsai_flutter_test` to upstream revision
`f4377637a33cdc450204734d033bbcbb861e06bb` in both project OPAM manifests and
their lockfiles. Update `source_boundary_test` to require this revision at every
project-owned source pin and to reject the displaced revision as obsolete.

The installed `bonsai_flutter`, `bonsai_flutter_test`, and
`bonsai_flutter_tool` packages already resolve to the selected revision. The
generated Flutter host is also current according to `bonsai-flutter sync-host
--check`, so no generated host source needs to change.

## Alternatives considered

### Keep the existing project pin

This keeps repository builds reproducible at the older revision but leaves them
out of sync with the installed host tool and excludes fixes already selected by
the user through the requested update.

### Pin a moving `main` reference

This would make future installs pick up upstream changes automatically, but it
would make builds non-reproducible. The project must continue to lock an exact
committed revision.

## Acceptance criteria

- All project-owned Bonsai Flutter source pins resolve to
  `f4377637a33cdc450204734d033bbcbb861e06bb`.
- `bonsai-flutter sync-host --check` reports no generated-host drift.
- Relevant OCaml and Flutter tests pass with the updated framework.
- The application completes a Bonsai Flutter native build for macOS.
- `spec-dev-tool check --all` passes.

## Risks

- The upstream protocol changed between the two revisions, so updating only the
  OCaml package pins without synchronizing the Flutter host would create a wire
  incompatibility.
- New framework APIs or rendering behavior may require focused application or
  golden-test changes.
- Regenerating locks in a heavily modified worktree can overwrite unrelated
  dependency work; every generated diff must therefore be reviewed and narrowed
  to the Bonsai Flutter update.

## Consequences

Fresh project dependency installs now select the same committed Bonsai Flutter
revision as the active host tool. The source-boundary test prevents either the
old revision or a moving branch reference from silently returning.

The updated dependency compiles without application adaptation. Full OCaml
tests, Flutter analysis and tests, generated-host verification, and a debug
macOS application build pass with the selected revision. The verified iPhoneOS
toolchain also produces an unsigned debug iOS application whose embedded native
framework passes architecture, deployment-target, and app-bundle verification.
Existing skipped golden tests remain skipped; this update does not change their
scope.

## Questions

- None. The user explicitly requested updating `bonsai_flutter`; the repository
  already uses exact upstream revisions, and upstream `main` is a committed
  revision currently installed in the active OPAM switch.
