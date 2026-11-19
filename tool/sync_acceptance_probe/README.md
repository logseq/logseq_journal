# Separate Simulator sync-network probe

This diagnostic entry registers the real `Application.For_testing.app_with_service`
with the production facade and its production overlay, auth, calendar and platform
dependencies. Only the facade's Registration network capability is wrapped.
`app/native_embed.ml` and the ordinary service never read the probe environment.
No SyncService, DSL or Execute public API changes are involved.

## Build and ownership gate

Arrange independent read-only review of the final diff **before producing a new
Simulator App or doing UI acceptance**. Source/object compilation is not runtime
acceptance. The main acceptance owner alone creates/installs/launches the new
Simulator; do not reuse ordinary A/B devices or bundles.

Use the maintained producer/importer, not raw object injection. After review:

```sh
BUILD=.agents/skills/journal-build/scripts/build_journal_apple.sh
LUI="$HOME/.opam/logseq-journal-lui/.opam-switch/sources/lui/platform/apple"
bash "$BUILD" macos --producer-only --sync-network-probe \
  --switch logseq-journal-lui --lui-package "$LUI" --cache-dir "$EVIDENCE/build-cache"
# ENVELOPE is producer.envelope.path from this run's manifest, not an old receipt.
bash "$BUILD" ios-simulator --sync-network-probe --experimental-host-restamp \
  --native-manifest "$ENVELOPE" --lui-package "$LUI" --cache-dir "$EVIDENCE/build-cache"
```

Select the existing prepared locked LUI path from the current switch/manifest if
it differs; never move it, re-pin dependencies, or edit immutable old evidence.
Unset ambient tool lookup overrides as required by the builder. `$EVIDENCE` must
be an owned external directory. These build commands never install or launch.

Alternatively the authorized main owner can run the maintained
`.agents/skills/journal-build/scripts/run_isolated_simulator.py` with its existing
required evidence/switch/LUI/runtime/device-type arguments plus
`--sync-network-probe`. It passes the role to both builder invocations, verifies
current sources, creates a fresh device, and records the private control paths in
`session.json.network_probe`. Do not run this install/launch route merely to
validate the tooling.

The explicit role selects only `tool/sync_acceptance_probe/native_probe.exe.o`.
Role/target, native probe sources and current Dune/lock configuration are bound
in producer evidence. Cross-role imports fail closed. The default production
target and commit-based build-configuration guard are unchanged. Probe builds
use the real maintained Swift sources, the `logseqjournal` auth redirect scheme,
bundle ID `com.logseq.journal.sync-probe`, and `JournalSyncNetworkProbe=true` in
the packaged plist. Both manifests record `production_acceptance=false` and keep
`cross_abi_validated=false`. Host restamping is experimental, not verified iOS
cross-compilation or ordinary production acceptance.

## Launch inputs and signal protocol

For a manual launch by the main owner, create a **fresh** directory in the new
probe App's data-container `tmp` directory. Resolve its absolute canonical path,
keep mode 0700 and current-user ownership, and pass only that path as
`SIMCTL_CHILD_JOURNAL_SYNC_NETWORK_PROBE_DIRECTORY` to `simctl launch`.
The test entry reads `JOURNAL_SYNC_NETWORK_PROBE_DIRECTORY`; ordinary entries do
not read it. No account/password/graph secret environment is inspected by this
probe. Login remains the real App UI's responsibility.

The instance exclusively creates `status.json` (0600, O_CREAT|O_EXCL). O_EXCL
also rejects a pre-existing final symlink; the retained descriptor is never
reopened through a pathname. Existing status files reject reuse: use a fresh
private directory for every service instance/launch. The directory contains only
local control/status, no graph data, credentials or payloads.

- Online: the `offline` signal file is absent.
- Offline: create an empty, owned mode-0600 regular `offline` file exclusively.
- Online again: remove only that owned signal file.
- Wait for the observed status transition before changing the signal again.
  Rapid unobserved create/remove pulses are not a supported fault command.

The switch-owned fiber samples every 100ms. An offline transition physically
shuts down both directions of every tracked live stream; it does **not** close
those resources. New stream connects fail with an explicit injected
`Unix.ENETDOWN` backend inside an Eio network connection error. A connect that
suspends across a fault generation is shut down and rejected before return,
even when online has already resumed. Original networking, flows and TLS remain
real outside faults. Original flow operations are forwarded unchanged; the
close hook removes its own ledger entry and release hook. The ledger is bounded
to 256 simultaneous streams; overflow is a diagnostic error, not a silently
untracked connection. Switch release removes entries, cancels/joins the monitor,
and closes its status descriptor. There is no global cache or production state.

This is **Registration stream fault injection**, not the OS radio being offline.
It covers actual sync/WebSocket and HTTP assets using that capability. DNS,
UDP/QUIC, Cognito/CFNetwork and other capabilities are not claimed offline.
No DYLD/SPI injection, host firewall, fd scan, daemon, re-signing of existing Apps,
or host protection change is used.

## Main acceptance status gates

The bounded numeric schema is exactly:

```json
{"schema":1,"heartbeat":1,"offline":0,"generation":0,"live_flows":0,"connect_failures":0,"shutdowns":0,"errors":0}
```

All counters saturate at 1,000,000,000; `live_flows` is 0..256 and `offline` is
0 or 1. Reads can race a small in-place status write: retry an incomplete JSON
read within the supervision window; never accept an old sample as liveness.
After the file first appears, require heartbeat advancement within **500ms**
throughout the acceptance case; stale/missing status or `errors != 0` invalidates
the case. Cold App startup has its own explicit timeout, not an assumed heartbeat.

For offline acceptance require `offline=1` and an increased `generation`.
To claim an existing live connection was cut, require a positive shutdown delta;
to claim a new connect was refused require a positive `connect_failures` delta.
For recovery require `offline=0`, another generation increment, a live heartbeat
and actual UI-observed synchronization. Counter changes alone are not evidence
of persistent offline/retry/conflict behavior or an actual server pass. Main must
run the actual App UI cases; no unit tests of this diagnostic substitute for them.
