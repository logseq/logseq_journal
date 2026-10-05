# Keep Photos change blocks off the main actor

## Problem

Actual PR47 XCTest taps Save on a generated blue image, accepts the add-only Photos dialog, then the fixture crashes. The crash report identifies _dispatch_assert_queue_fail and Swift executor checking in closure #1 in closure #3 in JournalPhotos.dependencies(feedback:), called by PHPhotoLibrary _performCancellableChanges on its background queue. No asset/success was claimed.

## Decision

Declare Photos change and completion blocks as explicit @Sendable closures. The change block captures only the staged URL and creates the resource inside Photos' required transaction context; it must not inherit MainActor. Completion explicitly hops to MainActor for the public save owner. Keep add-only authorization and original-file lifetime unchanged.

The production owner for this defect is the native JournalPhotos adapter's callback isolation. JournalPhotoSave's public state events can exercise save sequencing but contain no Photos transaction thread or Swift executor check, so its reducer/owner tests cannot reproduce this crash. Retain those tests and use the narrow real native Photos save UI regression for this adapter-only failure.

## Alternatives considered

### Move Photos transaction work onto MainActor

Rejected: Photos owns the callback execution queue; the resource must be created within its change block.

### Suppress the Swift runtime isolation check

Rejected: the callback must have the correct execution contract rather than bypass safety.

## Acceptance criteria

- The same normal UI Save succeeds without queue assertion after the already recorded add-only grant.
- The new asset is verified through actual Photos UI against the selected synthetic image and original dimensions.
- Existing save-owner/bytes tests and native compilation pass; no read permission, shared API, Dune/spec or unrelated cache change.

## Consequences

The same actual UI Save no longer traps on Photos' background change queue. Two normal XCTest Save runs reached the native success alert and Photos showed newly created synthetic blue assets; the actual Photos viewer and info panel identified the selected blue PNG and 640 by 420 dimensions. The public save-owner and staged-file tests pass, including duplicate/stale callbacks, permission failures, close/file lifetime and exact byte preservation. Swift 6 iOS Simulator compilation passes. No Photos read permission is added.

Actual acceptance artifacts remain Gitignored under docs/test-reports/pr47-ios-ui. The native paging investigation is separate and unresolved; this repair does not authorize merge or imply complete Application UI acceptance.

## Risks

- Closure captures must stay Sendable; all UI/owner completions return to MainActor.
- This fixes only the real save crash; the first-image paging/dismissal failure remains separately tracked.

## Questions

None: the user authorized minimum fixes for actual PR47 defects, Photos add-only acceptance and synthetic saving on the independent Simulator.
