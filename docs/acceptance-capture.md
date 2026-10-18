# Simulator acceptance capture

`tool/capture_acceptance.py` is the unified acceptance entry point. The App's
read-only observer is compiled only for iOS Simulator and is off by default.
It must be enabled on an authorized matching App with launch environment
`SIMCTL_CHILD_JOURNAL_ACCEPTANCE=1` (the child receives `JOURNAL_ACCEPTANCE=1`).
Coordinate ownership before any launch/install; the tool never performs those
operations. Missing/unready observers fail with `runtime-identity-unavailable`
before screenshots or evidence directories are created.

The current change has synthetic process/state/native-callback validation.
**Real Simulator socket, mounted-presentation and capture integration remain a
required acceptance gate until a coordinated synthetic run is recorded.** Green
CI alone does not prove this runtime success path.

## Inputs and checks

Use a successful `status: built` manifest from
[the maintained builder](../.agents/skills/journal-build/SKILL.md). Retain the App,
source checkout, original native producer records, native objects and final link
files. The tool reads the builder's current manifest format directly, without a
second manually maintained identity manifest. Supply expectations independently:

```sh
python3 tool/capture_acceptance.py \
  --manifest /external/build/run-example/manifest.json \
  --source-root /path/to/clean/build-checkout \
  --output /external/private-evidence/new-capture \
  --udid 11111111-1111-4111-8111-111111111111 \
  --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
  --bundle-id example.synthetic.journal --version 1.2.3 --build 42 \
  --source-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --graph-id 22222222-2222-4222-8222-222222222222
```

All identities above are synthetic examples. Use the authorized actual expected
values locally; never infer graph identity from a name or picker position.
The command exits 1 with a fixed JSON reason when blocked and exits 0 only after
an accepted record is written. No `--actual-*`, observer executable, arbitrary
JSON response file, or skip-check flag exists.

The preflight checks:

- Exact available, booted iOS Simulator UDID and device type from `simctl list`.
  Aliases and physical-device UDIDs are refused. It never boots, installs,
  launches, changes a graph, accesses a database, or reads credentials.
- Clean Git checkout and actual source bytes, with complete source coverage in
  the same scope as the builder; expected commit, bundle, version/build and build
  input digest. Dirty builds require a clean committed rebuild for this workflow.
- Hash-bound original producer source/link records and retained native inputs;
  the native source map must match current compiled source. Final native object,
  target C, Swift object and link-map bytes must match the successful receipt.
  Historical compiler/archive paths marked historical by the builder stay
  historical; this tool does not replay compilation or execute recorded argv.
- Packaged App files and `Info.plist`, followed by a **fresh**
  `simctl get_app_container UDID BUNDLE app`. Every installed packaged file and
  the executable hash must match; version or source strings alone never suffice.
  Actual installed Mach-O architecture/platform are read via `lipo`/`vtool`.
- Live observation before and after screenshot capture, with equal process
  instance, graph and presentation generations. It rechecks device, container,
  installed/build bytes and source after capture. Any failure discards the new
  evidence directory. An existing output directory is never overwritten.

Each system command has a 30-second timeout and captured output. Errors expose
fixed reason codes, never raw command stdout/stderr, manifest fields or local
paths. Successful records use an explicit allowlist, not a manifest/log dump.
Local builder receipts are trusted provenance records with rechecked bytes, not
signed attestations against a malicious local author. Do not forge or rewrite
receipts to turn a failed check into a pass.

## Runtime identity interface and evidence contract

The production state owner is `Logseq_db_worker.graph_state`, exposed internally
by `Get_graph_state` in
[`logseq_db_worker_lui_service.mli`](../logseq_db_worker/lui/logseq_db_worker_lui_service.mli).
Its optional `graph_id` distinguishes open/unknown graph identity. The sync
catalog's persisted selected graph is a selection record, not proof of what is
currently rendered. Existing error-detail Graph ID labels describe an error
occurrence and are not a live observer either.

The App joins a fresh correlated `Get_graph_state` response to the pure
`Journal_startup.Acceptance` owner: selected graph UUID, ready feed, matching
Worker generation, startup presentation, foreground and error state. Every relevant
transition advances an epoch, including away-and-back to the same graph. The
read-only `Journal_bridge` C callback copies owned metadata and releases the OCaml
runtime before returning to Swift. It reads no database, catalog or secret.

`JournalRuntime` requires a mounted root matching the applied backend, healthy
patch application and an active UIKit foreground scene. It brackets a native
two-display-tick barrier with fresh Worker samples and equal epochs; root/lifecycle
transitions also invalidate the response. The private observer is compiled only
for Simulator and explicitly enabled by environment. Its fixed same-user Unix
socket lives in `/tmp/lj-identity-UID-UDID/identity.sock` (directory 0700, socket
0600), is nonblocking and has bounded request/response deadlines. No TCP listener,
new entitlement or persistent diagnostic log is introduced.

The tool authenticates Darwin `LOCAL_PEERPID`, `getpeereid`, and `proc_pidpath`
against the freshly installed executable path and hash before reading any reply.
Thus a JSON pid/bundle claim or handwritten response file is not trusted. Protocol:

1. The tool resolves the installed bundle and executable first, then sends a fresh
   random challenge to that App's running process through a supported platform
   channel. Caller-supplied response files/log snippets are not an endpoint.
2. The App answers from current Worker state **and mounted foreground presentation**.
   Selection/loading/error/background states must block. An external transport
   verifies kernel process ownership and executable path/hash. Foreground facts
   come from UIKit in that authenticated App, rather than a JSON claim by an
   arbitrary process.
3. The response has exactly the fields below. No token, user/email, graph name,
   graph body, database location or diagnostic payload is permitted:

```json
{
  "schema_version": 1,
  "challenge": "fresh request UUID echoed by the App",
  "udid": "11111111-1111-4111-8111-111111111111",
  "bundle_id": "example.synthetic.journal",
  "executable_sha256": "64 lowercase hexadecimal characters",
  "source_sha": "40 lowercase hexadecimal characters",
  "graph_id": "22222222-2222-4222-8222-222222222222",
  "graph_generation": 7,
  "presentation_generation": 7,
  "phase": "open",
  "foreground": true,
  "pid": 123,
  "process_instance": "33333333-3333-4333-8333-333333333333"
}
```

4. `process_instance` is fresh per process launch. Graph generation must increase
   monotonically for every close/open/switch/loading transition, including a
   switch away and back to the same graph; mounted presentation generation must
   match it. Observer reads must be serialized with state/presentation commits.
   Before/after equality therefore rejects transitions and restarts around the
   screenshot. A transport unable to guarantee this must block; two graph UUID
   strings alone cannot exclude stale presentation or a switch away and back.
5. The bridge returns unavailable on timeout or missing facts. Real synthetic-
   Simulator integration must verify the App sandbox and displayed graph alongside
   the existing OS/process-authentication fixtures before claiming live acceptance.

The current Python test backend injects observations at that method solely to
exercise downstream validation/cleanup. They do not prove real Simulator socket
access, displayed-frame synchronization or Journal UI acceptance. Production code
has no injection option in its CLI; real App integration is a separate evidence
gate. No unrelated HTTP listener or UI feature is part of the bridge.

## Evidence and privacy

A successful future production run produces `screenshot.png` and `acceptance.json`
in a newly created private external directory. The record binds expected and
observed identities, build/manifest/executable hashes, timestamp, process and graph
generations and screenshot SHA-256. It labels `platform: ios-simulator`,
`build_mode: experimental-host-restamp`, `cross_abi_validated: false`, and
`real_device_acceptance: false`. Stubs, probes, preflight-only manifests and
real-device Apps are refused. Simulator success never establishes phone or full
iOS ABI correctness.

Screenshots can contain private graph content even though the record contains
only identities. Keep both private, review pixels before sharing, and never
commit generated evidence. Public tests use synthetic files and identities.

Run the reusable tests without any Apple device (local Unix IPC tests require
normal supported execution-sandbox approval when socket binding/connection is restricted):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tool/test_capture_acceptance.py
PYTHONDONTWRITEBYTECODE=1 python3 tool/test_acceptance_ipc.py
```

They exercise real temporary files and Git repositories, mocked system commands,
and a CLI subprocess with a fixture `xcrun`. They cover stale containers, byte and
source mismatches, similar graph identities, runtime transitions, failed/timeout
capture, the production bridge blocker and sensitive-output suppression. Fixtures
are created outside the repository; CI runs this same suite.
