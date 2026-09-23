# Native warm-start acceptance

Build the isolated host from the current production OCaml object and Swift views:

```sh
python3 tool/test_swiftui_warm_start.py --rows 500 --children 135
```

For distinct graph selection and draft scoping, use `--graphs 2 --rows 5
--children 0`. The bounded graph count is 1–4. Each graph has its own database,
identity and checkpoint, a numbered catalog name and a numbered first entry.
Block UUIDs deliberately repeat across graphs. The version 2 fixture JSON has a
required `graphs` array; regenerate earlier single-graph fixture files.

Create and close a Capture draft in graph 1, select graph 2 through Account menu
and verify Capture is empty. Retain a different draft in graph 2, return to graph
1 and save only its original draft, then save graph 2's draft there. Inspect each
outbox separately and restart with graph 2 selected to verify direct restoration.
These are local acceptance steps; authentication remains blocked.

The builder prints its temporary directory and launch commands. Run those commands
with both memory-only E2EE storage variables; the executable rejects other secret
storage. Authentication deliberately waits instead of contacting a remote service.
Only the generated graph and test preferences are used.

Inspect the actual native content as well as `*.observations.jsonl`. The status
label records startup or shutdown outcomes; a startup PASS does not establish
that a later mutation, navigation or pagination operation succeeded.

The **Active scene** checkbox supplies `.active` or `.inactive` through SwiftUI's
public scene environment. It permits same-process resource comparisons without
changing macOS preferences. It is a controlled host input, not an actual system
lifecycle or Reduce Motion test. Leave it selected for normal acceptance and
restore it before exercising application interactions.

For resource characterization, sample the executable's PID with `ps` and collect
an idle stack using `sample PID 5 -file OUTPUT`. Record the loaded row count, build
configuration, scene setting, sampling timestamps and whether UI automation was
running. Calculate interval CPU from differences in cumulative CPU time; command
latency and the instantaneous `%cpu` column do not measure rendering frame rate.
Report resident memory separately from the physical footprint reported by
`sample`. Debug macOS measurements do not close iPhone Release performance gates.

Use **Shutdown real Journal** to verify cooperative shutdown before quitting the
host. The missing-key case exercises offline recovery admission; it cannot prove
successful password verification while remote authentication is blocked.
For alternate-graph recovery, start with a fresh missing-key fixture and press
**Check recovery admission** while the error is visible. Then choose another
graph and open graph 2. The host records recovery admission before accepting the
later timeline presentation. Regenerate this fixture before repeating the case:
successful selection persists graph 2 as the next launch target.

## Isolated iPhone host

Build the simulator host (device builds additionally need the shared iOS OCaml
toolchain object — see tool/build_journal_apple.sh):

```sh
python3 tool/test_swiftui_warm_start.py --platform ios-simulator \
  --rows 500 --children 135 --graphs 2
```

Use `--native-object PATH` only when that file is the current verified production
object for the selected platform. The builder records its hash alongside copied
Swift source hashes. iPhone uses Release optimization with DEBUG enabled solely
for the test host's memory-only secret stores. It is not a production keychain or
remote performance test.

Install the printed `JournalWarmStartProbe.app` in the distinct
`org.logseq.journal.warm-start-probe` container. Copy `valid.json` and the complete
`support-valid` directory into that app's Documents directory using devicectl.
Launch with:

```text
--fixture valid.json --support-root support-valid
```

Set both `LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE=memory` and
`LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE=memory`. iPhone paths must be relative
to Documents without `..` components; the test host rebases generated graph paths.
The iPhone host uses the actual scene phase and compact test controls. Its extra
status area cannot establish production toolbar or safe-area visual acceptance.

`JournalIPhoneAcceptance.swift` is an XCTest UI source for this isolated bundle.
Add it to a signed UI testing target on the available device. Use a fresh fixture
with 500 roots, 135 children and two graphs. It exercises Capture save/status after
scrolling to the saved record, Append across partial child pagination, native
child swipe deletion with timed cancellation, restart persistence and outline
navigation. Each test launches independently; a failed sheet must not obstruct
later cases. A root with many child previews can exceed the viewport, so open its
visible title instead of tapping the off-screen center of the entire row.

The suite mutates disposable data. Regenerate the fixture before repeating the
whole suite, and copy its databases back for exact graph/block/outbox checks.
Do not run this suite against the user's production graph. Separate read-only
production appearance checks from isolated mutations. Whole-screen XCTest
screenshots are preferred for rotation evidence: application-only screenshots
on this device were cropped despite correct landscape accessibility bounds.
Compilation, AX assertions and screenshots establish different facts; retain
failed runs and inspect the actual images before claiming visual acceptance.


## Scoped accessibility size on iPhone

Pass `--accessibility-size` to the isolated host to supply the UIKit window
trait `accessibilityExtraExtraExtraLarge`. The host-only
`acceptance-dynamic-type` element reports the inherited size as its accessibility
value. Without this option, the environment is unmodified and the readout is absent.
This uses the public UIKit window trait override and does not change device
settings. The host diagnostic banner is independently kept at normal size to
avoid taking excessive space from the application under test.
Use it for production-view layout, navigation and composer acceptance on the phone.
It does not establish device-wide preferences, system large-content viewer behavior,
VoiceOver speech or the full accessibility matrix. Retain whole-screen images and
separate the host's diagnostic controls from actual application content.

## Keep accessibility inspection separate from idle sampling

The 5,000-root macOS run in batch 33 showed that a full accessibility-tree read
can cause native AppKit List callbacks to report off-screen materialized rows as
visible and admit more pagination. A no-interaction cold-start control remained
at 64 roots. Record whether AX inspection preceded each resource interval, and
measure a separate interval without any UI/AX automation. A startup status PASS
or an instantaneous CPU reading is insufficient to label an interval idle.
This behavior has not been established on iPhone. Include the same controlled
comparison when actual iPhone large-list/VoiceOver acceptance resumes; macOS
measurements do not substitute for that gate.

## Physical local-write failure acceptance

Use a fresh, disposable two-graph fixture and a named SQLite trigger on graph 1:

```sql
CREATE TRIGGER acceptance_reject_outbox
BEFORE INSERT ON sync_outbox
BEGIN
  SELECT RAISE(ABORT, 'acceptance injected outbox write failure');
END;
```

This models a real local transaction rejection. It does not model remote conflicts
or disk exhaustion. Verify restoration, persistent failure feedback, Details/Close
and Dismiss without a queued write. Terminate the host before copying its storage
back. Check integrity and zero outboxes, copy that readback for recovery, remove
only this trigger, and transfer the database with its complete WAL/SHM set as
explicit files. A deliberate native retry must enqueue only the intended block
and agree with restart. Batch 40 contains the executed test and exact outboxes.

Keep the SQLite preparation connection quiescent and open during transfer, then
close it afterward. The current native read-only checkpoint path returned
CANTOPEN for a fixture whose last Python SQLite connection removed WAL sidecars;
opening it read-write and transferring the complete sidecars restored admission.
Do not classify that fixture-startup failure as mutation-failure evidence.

Do not use devicectl `--remove-existing-content` for an app-container subdirectory:
in batch 40 it cleared the isolated Documents domain, including fixture JSON,
rather than just the named support directory. Use fresh destination names or
explicit file replacement with the host stopped. Restore/regenerate earlier
scratch fixtures before rerunning their tests; their Mac readbacks remain intact.

## Date-header layout fixtures

Use `--history-days 4` with the builder to add four historical sections, each with
twelve rows including one long multiline row. `--application-only` at host launch
hides the test status controls so that the production native view owns the whole
content area. `--light-appearance` and `--dark-appearance` select a host-only
appearance for screenshots. The existing `--accessibility-size` trait override
can be combined with these flags. None changes system preferences.

For floating error-control layout, `--auth-failure` makes the isolated host's
`freshIDToken` throw the existing unavailable failure instead of waiting. This
executes the production authentication failure path without remote access or
changes to system settings. It is a native layout fixture, not reducer regression
coverage or a successful remote authentication test.
