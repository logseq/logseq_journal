# Simulator acceptance capture

`tool/capture_acceptance.py` is the unified acceptance entry point. It currently
**cannot accept real screenshots**: Journal has an internal Worker graph-state
query but no supported external bridge that proves the graph mounted by the
foreground process. The production observer fails with
`runtime-identity-unavailable` before creating an evidence directory or requesting
a screenshot. This is a blocking interface gap, not a completed runtime check.

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

## Missing runtime interface: follow-up contract

The production state owner is `Logseq_db_worker.graph_state`, exposed internally
by `Get_graph_state` in
[`logseq_db_worker_lui_service.mli`](../logseq_db_worker/lui/logseq_db_worker_lui_service.mli).
Its optional `graph_id` distinguishes open/unknown graph identity. The sync
catalog's persisted selected graph is a selection record, not proof of what is
currently rendered. Existing error-detail Graph ID labels describe an error
occurrence and are not a live observer either.

A separate follow-up must implement and review an App-owned external read-only
bridge plus the CLI transport, without altering graph state or exposing graph
contents. No such bridge or transport is implemented by this PR. Minimum contract:

1. The tool resolves the installed bundle and executable first, then sends a fresh
   random challenge to that App's running process through a supported platform
   channel. Caller-supplied response files/log snippets are not an endpoint.
2. The App answers from current Worker state **and mounted foreground presentation**.
   Selection/loading/error/background states must block. An external transport
   must verify process ownership, executable and foreground status against OS
   evidence, rather than trusting an arbitrary process claiming a bundle ID.
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
5. The bridge returns unknown/error on timeout or missing facts. A future adapter
   must include OS/process-authentication and real synthetic-Simulator integration
   tests before enabling the currently blocked `Simulator.observe` method.

The current Python test backend injects observations at that method solely to
exercise downstream validation/cleanup; these tests do not prove a live runtime
bridge, foreground authentication or actual Journal UI acceptance. Production
code has no injection option in its CLI. This keeps the follow-up scope explicit
without shipping a fake check or unrelated HTTP/UI feature.

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

Run the reusable tests without any Apple device:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tool/test_capture_acceptance.py
```

They exercise real temporary files and Git repositories, mocked system commands,
and a CLI subprocess with a fixture `xcrun`. They cover stale containers, byte and
source mismatches, similar graph identities, runtime transitions, failed/timeout
capture, the production bridge blocker and sensitive-output suppression. Fixtures
are created outside the repository; CI runs this same suite.
