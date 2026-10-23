# Ocaml Evidence Boundaries

## Problem

At main 5abaab43b2943c89df5ce236e51c25718fa4df56, snapshot metadata,
download scope, cursor and activation are independently constructible; unlock
submission state is spread across Core and Application options/booleans; asset
decode returns ordinary strings and runner error classification compares English
messages. PRs #107, #108 and #102 already fix the known runtime defects. The
requested change strengthens the interfaces while retaining those protections.

## Proposal

Keep all three changes local to their existing owners and modules. No dependency,
Dune, persistent format, transport format or Swift packet-layout change is planned.

### Snapshot attempt

In logseq_sync/spec/pure_reducer/core.mli, make snapshot_download and
snapshot_activation_request abstract. A metadata-waiting attempt captures its
unique identity and graph_scope; accepting metadata preserves its original
Server_cursor.t and URL in the downloading phase. The download interpreter reads
request accessors and returns an artifact receipt tied to that request, replacing
the arbitrary id/scope artifact factory. Core must compare the returned receipt
against the active attempt, not just the graph scope, before producing activation.
Activation carries the bound artifact/cursor/scope/key as one value. Successful
and failed activation receipts also carry the original abstract request, and Core
matches it against the current Activating phase before consuming either. Worker reads
accessors and retains its current key checks, staged database validation and atomic
publication. No public activation constructor accepts independent fields.

Use an internal bootstrap phase ADT instead of snapshot_scope,
snapshot_server_t, active_snapshot_download and pending_snapshot_activation as
independent authority. Preserve ticket admission, generation/current scope checks
and cancellation. Same static phase does not establish same dynamic identity.
Keep metadata t as the catchup lower bound even when the live stream includes
later writes. Preserve the legacy baseline request behavior where still exposed.

### Unlock phases

Add abstract challenge/submission/attachment evidence within Core's existing
interface, with a narrow unlock phase projection. Core creates a challenge only
when the actual key packages are available. Submission consumes that challenge
and records an operation identity; the real successful Graph_attached handling
creates attachment evidence after current scope and pending attachment checks.
The presentable phase is reached before Timeline appearance acknowledgement.
After key success, a missing mirror uses a separate bootstrapping phase: it is
not yet presentable, but password_pending is false so download progress can show.
Failure/cancellation/reset retires the matching operation; a retry-password
projection retains a valid challenge. Retain runtime owner/operation checks for
late success and failure, and keep password/key material out of UI projections.

Application consumes the typed phase/receipt, replacing its independent
e2ee_submission_pending and e2ee_submission_error authorities. Password text can
remain a separate editing model. Graph_service forwards the typed projection;
existing Swift/FFI UI booleans are derived from it. Preserve manager-first and
graph-first notification behavior from PR #108 and scoped Timeline_presented.
Do not make Ready a prerequisite for leaving the password screen.

### Asset decoding and publication

In logseq_sync/spec/effect_runner/asset_codec.mli, keep raw/envelope/plaintext roles internal and expose abstract verified plus
finite decode errors. Classification and decoding preserve
PR #102's conservative candidate policy, with no authentication/parse failure raw
fallback. Verified binds bytes to the expected asset version, produced only by
successful bounded decoding/validation. Provide read access for private cache IO,
with no arbitrary verified_of_string constructor.

Change private Bootstrap.Asset_cache.publish to consume verified, deriving the
version from it. Retain independent current, maximum-file-size, checksum, disk,
lease and atomic publication checks. Both network download and the existing
local staged-import publication call must cross the verification boundary; avoid
leaving a plaintext publication overload as a bypass. Runner maps finite errors
to existing domain failures without comparing error wording. Keep crypto callback
byte adapters at the platform boundary rather than extending the whole crypto
system. The public asset_cache.mli currently exposes only abstract types; change
it only if an implementation type equality actually requires it.

## Decision

The user explicitly authorized the required protected spec .mli changes on
2026-10-23, as relayed by the parent with the direct question and answer. Proceed
within these three boundaries. Build/test/Simulator work still waits for an
explicit resource handoff; no Dune or pin changes are authorized.

## Alternatives considered

### Implementation-only wrappers

Insufficient: Core's public activation record and arbitrary staged_artifact
factory would still admit independent data, and public codec decode would still
return ordinary bytes/string errors. The requested protection needs changes to
the protected virtual-library interfaces.

### One global application state machine

Rejected: local access, online sync, UI editing and presentation have independent
lifecycles. The change concerns only bootstrap attempts, unlock operations and
asset decode/publication boundaries.

## Acceptance criteria

- Separate compiler rejection evidence from dynamic behavior evidence: callers
  cannot construct activation records/artifacts independently, submit without a
  challenge, mint attached from a bool, or publish unverified strings.
- Run existing Core, recovery, codec, asset-cache, runner, worker and Application
  regressions applicable to the changed interfaces. Adapt fixtures to the public
  producer paths; do not expose construction backdoors just for fixtures.
- Temporary external fixtures cover two same-type attempts with distinct identity,
  late metadata, graph replacement, stale download success/failure, original
  metadata cursor catchup, full bootstrap, current/key scope and publication
  invalidation.
- Unlock fixtures cover correct/wrong password, retry, cancellation, queue failure,
  stale responses, owner replacement, both notification orders, password-screen
  dismissal before Timeline, and first appearance acknowledgement.
- Asset fixtures cover clear and encrypted bytes, conservative JSON candidates,
  authentication failure with a checksum matching the wire bytes, malformed/size
  errors and stale cache publication. No candidate failure becomes raw success.
- After the parent releases shared resources, run a real Simulator workflow with
  isolated synthetic data covering bootstrap, sign out/login/unlock and assets.
  Do not touch real graph credentials or reset device
  1446A493-492B-4F2D-974D-3AED9DA5C97B. Reuse A135 after release, with at most
  three devices and no new device for this work.
- Independent review, final applicable tests and actual Simulator evidence precede
  a non-Draft PR. No merge or TestFlight. Host-restamp evidence remains explicitly
  experimental-host-restamp with cross_abi_validated=false; unsafe simulations
  are recorded as untested.

## Risks

- Abstract types do not revoke old values or establish identity, response freshness,
  authentication, disk success or liveness. Existing dynamic checks remain required.
- Type migration must update real producers and consumers together; parallel old
  factories or UI authorities would undermine the intended protection.
- Existing regression behavior is already correct, so behavioral tests may remain
  green before the refactor; do not invent a regression or claim a RED run that
  was not observed. No build/test process was started during resource hold.

## Consequences

The three boundaries are implemented within their existing owners. Public compiler
negative tests reject arbitrary activation/challenge/attached/verified construction
and the old artifact factory. Core retains ticket/generation/current/request identity
checks; cache publication retains current, size, checksum, disk and lease checks.
The slow-bootstrap regression was reproduced through public Core events before
fixing publication of Unlock_bootstrapping ahead of metadata work.

Final production-source build @all and repository runtest pass. Applicable reruns
include Sync 305, Application 144, runtime locality 152, worker integration 15,
worker reducer 20 and LUI service 49; existing overlay storage 85 also passes.
Independent read-only review of source commit b6b61a7 found no remaining proven
issue. Temporary logs, hosts and screenshots remain outside the repository.

The same source modules were tested on the existing A135 iOS 26.1 Simulator with
an isolated synthetic account/graph, a memory secrets adapter and a loopback server.
The temporary test entry is not committed; production native_embed is unchanged.
The real UI covers wrong-password retry, cancel/reselect, sign out/login/unlock,
retained-mirror attach, and a fresh 412-row snapshot with delayed delivery. Password
pending clears in bootstrapping, before attachment and Timeline appearance. The
persisted metadata cursor is 42, SQLite integrity_check is ok, and diagnostics show
Sync Current, Startup Ready and Graph Open. Clear and Apple AES-GCM attachments
publish the expected plaintext; a corrupted-auth envelope whose wire checksum
matches is rejected and never published. Sign out clears decoded cache files and
memory secrets; relogin downloads and verifies attachments again.

The first temporary server used the wrong pull reply spelling; its affected run
was not accepted. The corrected server and final source were rerun successfully.
No real account/keychain or graph was accessed. No device was created or reset;
the protected 1446 device was untouched. Host-restamp remains experimental with
cross_abi_validated=false; these checks do not establish complete cross-ABI support
or production authentication-service acceptance. Disk-full/hardware faults and
pending-operation UI cancellation were not simulated on-device; applicable existing
runtime regressions remain separate evidence. A135 and this task's processes were
released after verification. No merge, TestFlight or deployment is authorized.

## Questions

None. The user answered the protected-interface authorization question with
“允许”. Resource release is an execution gate, not an open design question.
