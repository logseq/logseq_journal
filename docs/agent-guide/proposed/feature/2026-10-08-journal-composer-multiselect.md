# Journal Composer multiselect consumption

## Problem

The user requested Journal consume merged LUI PR159, including real attachment layout and multiselect. Journal currently forces a 112pt strip and accepts one native pick at a time; asynchronous pick completion must keep draft/request ownership, temporary resources, and durable import order.

## Proposal

Pin the verified merged main ee51c9747e584edd2ac09cc2cefee130622d8bda. Use the public default 128pt strip/120pt card. Enable ordered Files and Photos multiselect for staged Capture picks; retain single selection for detail imports. Deliver a batch with its original request identity, deduplicate by stable source identity, retain successful picks on partial staging failure, preserve cancellation, discard rejected/stale temporary copies, and retain Journal's existing nine-item limit. Preserve existing durable upload intent owner and import completion behavior; ensure captured attachment import admission stays ordered.

## Alternatives considered

### Only update the dependency pin

Rejected because it leaves the production picker single-select and clips the new cards.

### Copy Gallery send/clear and example limits

Rejected because Journal owns durable staging/upload intents and already has its own attachment limit.

## Consequences

The native consumer and event decoder change together; tests must cover selection order, cancellation, duplicate/removed selections, partial failure and graph/draft fencing. No protected Dune/spec changes are planned. Existing postcommit Capture confirmation Full remains separate; any verification blocked by it will report the minimal additional scope instead of replaying a saved mutation.

## Acceptance criteria

- Exact manifest/lock/source pins agree with verified LUI main.
- Public tests cover batch order, cancellation, duplicate/removal, partial failure, capacity and stale resource ownership.
- Full affected regressions and native synthetic multiselect/layout verification are recorded with honest limits.
- Independent review and a local commit are delivered without Journal publication.

## Risks

- Async native selections can complete after graph/draft replacement and must not acquire a newer request identity.
- Durable staging intents must precede release of source copies; existing Capture Full may block complete UI Send acceptance.

## Authorization

The user explicitly asked to merge LUI PR159 and then adapt Journal to latest LUI. The delegated scope permits necessary Journal consumer implementation, local commits, independent review and isolated synthetic UI tests, with no Journal publishing/merge/phone installation or seven HIG fixes. PR159 merge was verified from GitHub and exact main fetched before pin update. No unanswered design question remains.

## Verification status

The batch ownership boundary was reproduced through public Root_navigation events before implementation. Import admission belongs to Application's effect queue, which the pure reducer cannot execute; its regression uses the existing public app_with_service hooks and real Concurrent Worker lanes. The unsequenced variant starts the second import before the first completes and fails the regression. The initial implementation also failed the public Error info visibility assertion; the final implementation passes both and keeps successful siblings after a failed item.

Final full build and force runtest passed with 21 Alcotest suites / 640 cases, including source boundary and interface checks. The first transport run was blocked by sandbox loopback binding; the unchanged suite passed with local loopback permission. Native bridge 23 cases passed. Exact LUI main CI passed all six jobs; its local OCaml 87 / macOS Apple 167 cases and iOS Simulator static build passed. Independent review findings were resolved. The final production Swift host compiled without diagnostic substitutions.

The native consumer subscribes through the public context.revision contract and keeps a transparent, noninteractive presentation anchor for the otherwise empty Capture adapter. The final production binary (source ca2fa064, SHA256 a799a5949076692fff0009d5c4dcb74b1b73ee9cfe5e4d568d737793ff7b80a8) was installed only in the isolated org.logseq.journal.composer-20261008 bundle on B15AA93D-9889-4D75-8A4A-ABC12F00B478. The user explicitly approved limited XCTest on synthetic data after CUA input failed.

Actual native tests passed Files cancellation/reopening twice, mixed three-file selection, duplicate re-selection, removal/re-addition and discard; Photos selected the synthetic green image first and blue second, preserved this order, retained both after a second picker cancellation, and discarded them. Tests used measured visible coordinates where the system AX node was not hittable. A middle image card's close-center tap did not remove it; later removal passed with the target in the first card position. The image AX frame exceeds the 120pt card width, so the middle-card normal hit boundary remains an unconfirmed risk, not a confirmed upstream defect.

One distinct batch Send was actually performed. It wrote a single queued text mutation (1054f7d6-3d95-4e34-8ad3-7048b47db657, attemptCount 0), collapsed Composer and showed Error info. The subsequent read-only SQLite snapshot had zero asset upload intents. The observation test passed, but this is not successful batch-import acceptance. Exact error detail was not captured; do not classify it as the previously proven Full condition or a DataScript regression. The saved mutation was not replayed. The fixture blocks auth and cannot validate server acknowledgment/upload. Nine-item overflow, horizontal scrolling, partial native transfer failure, graph switch while picking, and successful native batch import remain unverified. Keep this decision proposed. GUI and XCTest are stopped and released to the peer task.
