# Cached graph startup diagnostics

Set `JOURNAL_STARTUP_DIAGNOSTICS=1` for a launched process to enable stage timing.
It is off by default; it does not enable networking, change startup ordering, or
write graph data. With an already installed app on an explicitly selected iOS
Simulator:

```sh
SIMCTL_CHILD_JOURNAL_STARTUP_DIAGNOSTICS=1 xcrun simctl launch \
  --stdout="$EVIDENCE_DIR/startup.stdout" --stderr="$EVIDENCE_DIR/startup.stderr" \
  "$SIM_UDID" com.logseq.journal
```

Use an external evidence directory. Terminate the app separately before each
process-cold sample; retain its container and Keychain. Do not use a finite-lived
`simctl launch --console` observer whose termination can also terminate the app.
Verify the selected graph and Current / Ready / Open state before timing; first
download, sign-in and unlock are separate scenarios.

## Stages

`journal-startup:` stderr records contain only fixed stage names and numeric
timings. Swift uses monotonic process uptime and records begin/end pairs or
point markers:

| Stage | Boundary |
| --- | --- |
| `host_prepare` | Application services setup and startup payload preparation |
| `backend_init` | Native LUI backend construction |
| `ocaml_start` | Synchronous `lui_ocaml_start`, including callbacks it executes |
| `initial_platform_requests` | Initial platform reply barrier |
| `root_appeared` | SwiftUI runtime root's `onAppear` callback |
| `timeline_acknowledged` | Native receipt of the timeline presentation acknowledgement |

Worker `mirror_inspection` includes local retirement recovery and durable mirror
metadata inspection. Its `clock=wall` duration uses the existing Unix clock (and
can be affected by wall-clock adjustment); other durations use monotonic clocks.
Overlay `local_attach` encloses the owned database open;
its subspans are `outbox_read`, `receipt_validation`, `outbox_migration`,
`storage_open` and `datascript_restore`. Overlay records include wall elapsed
time and **process-wide** CPU time, not per-fiber CPU usage.

The existing bounded `journal-timeline:` reporter additionally emits
`stage: "startup-feed"` when enabled. `elapsedMs` measures from the feed scan's
creation (before the first root/day query) to a feed publication. `complete`
distinguishes incremental publications from the completed result;
`requestGeneration` correlates publications within a scan. These records add no
graph identifiers, credentials or journal content. Other existing log categories
can contain private metadata; review and redact raw logs before sharing them.

## Interpretation

- Spans can nest or overlap; do not add their durations as serial launch time.
  In particular, `local_attach` includes its subspans.
- A span ending means its call returned or unwound, not that the operation
  succeeded. Pair with the normal outcome/error observations.
- Point markers are lifecycle callbacks, **not first displayed content frames**.
  Use screenshots/recording or Instruments for that boundary and for pre-main
  time, which these application-level markers do not measure.
- Do not subtract timestamps across clock sources. Feed durations include queue,
  worker query and projection time; they are not isolated SQLite query timings.
- Timings are diagnostic overhead-bearing samples, not a performance gate. Bind
  results to the actual build manifest and final source revision; experimental
  host-restamped Simulator results do not establish device performance or ABI.
