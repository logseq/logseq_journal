# Startup canvas regression

This is a native layout boundary test. The public OCaml startup owner supplies
valid states and patches, but cannot execute SwiftUI safe-area proposals or
recovery-button geometry. Do not duplicate the frame regression in the reducer.

Build `JournalStartupLayoutFixture.swift` as the disposable host entry point with
the production `swift/` sources (excluding `App.swift`), the declared LUI Apple
SDK, and the existing native linking object. Bundle `startup-patch.json` as a
resource. It is the accepted first public patch from the synthetic startup host
at Journal `6d4fc15763bd2f98f29384b45d8eb2f7d71e1a13`, with no personal graph.
The fixture never starts JournalRuntime or a worker. It applies public patches
through the production extension registry and verifies the actual recovery event.

Use host bundle ID `org.logseq.journal.startup-layout-20261012`. Add
`JournalStartupLayoutTests.swift` to an XCTest UI target and run the four methods
on an isolated iPhone 13 / iOS 26.1 Simulator. Keep generated hosts, runner
projects, build caches, result bundles, screenshots and logs outside the repository.

The tests compare the actual text frame through native preparation, LUI navigation
handoff, action insertion and removal at 390/320 points with normal and
accessibility3 text. Every phase retains its raw screenshot and accessibility tree.
Recovery must remain enabled, hittable, and deliver the public press event.
The fixture uses the same root GeometryReader environment as JournalRuntimeHost;
it does not duplicate the production surface or extension layout implementation.
