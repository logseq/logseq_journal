# Encrypted Offline Warm Start Validation

## Problem

The application has unit coverage for online E2EE endpoint orchestration, private-
key Keychain attributes, password unlock, local-account binding, graph opening,
and the generation-fenced Timeline presentation barrier. It does not have a
repeatable path proving that a terminated macOS or iOS application can open an
encrypted local mirror when every network future is unavailable.

Wrapped-graph-key persistence crosses the Apple Security framework, the native
crypto bridge, OCaml E2EE session state, sync-manager effects, mirror admission,
engine open, progressive feed loading, and Flutter frame acknowledgement. A unit
test that only round-trips bytes through a fake store would miss account or graph
scope errors. A physical launch observation alone would miss corrupt-item,
rotation, revocation, generation, teardown, and failure behavior.

The performance boundary also needs an explicit baseline. Current iPhone profile
measurement of an encrypted graph with an existing 1.1 MB mirror observed a
1.061-second median and 2.502-second p95 TTFT across nine complete samples. One
detailed sample spent approximately 539 milliseconds in the remote E2EE graph-key
request, while catalog load, mirror inspection, graph info, page discovery, and the
first page-tree read were individually below six milliseconds. The new capability
must demonstrate removal of the network dependency without hiding a large
Keychain or RSA-unwrapping cost.

## Decision

Validate the capability at four layers: native storage and crypto, OCaml state
transitions, compiled application integration, and signed profile builds on real
Apple platforms. Tests must use synthetic identities, graph UUIDs, wrapped keys,
private keys, and graph content. No developer Keychain item, production account,
or personal graph may be copied into a committed fixture or test log.

### Test the native Keychain contract without sharing production items

Extract the wrapped-key query, identity encoding, value encoding, and storage
operations behind a narrow native store that can use an in-memory backend in
ordinary unit tests. The test backend exists only in debug/test compilation and
must be rejected in profile and release builds.

Run the same behavioral suite for macOS and iOS:

- exact service, class, accessibility, synchronizable, and account-digest
  attributes;
- exact graph digest in `kSecAttrAccount`, account digest in `kSecAttrGeneric`, and
  macOS data-protection Keychain selection;
- deterministic separation by managed origin, user, and graph;
- bounded version-1 encode/decode round trips;
- add, replace, load, delete-one, and delete-account behavior;
- duplicate saves and missing deletes are idempotent;
- malformed encodings, unsupported versions, oversized ciphertext, invalid HTTPS
  origins, invalid UUIDs, and embedded NULs are rejected;
- a decoded item's repeated identity must match the lookup identity;
- no query or value contains a plaintext graph key, token, password, private-key
  package, graph content, or Timeline data;
- the existing private-key and local-account-binding services remain disjoint.
- the retained private-key service uses the same origin-and-user account scope and
  is deleted together with wrapped graph keys on sign-out.

Add a small signed platform test for each OS that exercises an isolated randomized
test service in the real Keychain, verifies device-only accessibility and
non-synchronization, and removes the item in teardown. Normal unit tests must not
depend on a user's interactive Keychain permission prompt.

### Drive every sync-manager branch deterministically

Extend the closed E2EE platform test contract with explicit wrapped-key load, save,
and delete operations. Cover at least:

- local private key plus valid cached wrapped key emits `Open_graph` without an
  `E2ee_key_access` challenge;
- missing cached key retains the authenticated `Fetch_e2ee_graph_key` flow;
- the remote response is persisted only after successful decode and unwrap;
- missing private key cannot use the cached wrapped key and enters the existing
  user-key/password recovery path;
- corrupt, oversized, wrong-origin, wrong-user, wrong-graph, and unwrap-failing
  items are deleted and cannot open the engine;
- a stale Keychain result is ignored after account, graph, or presentation
  generation changes;
- a newer successfully unwrapped server value replaces the cached value;
- a failed rotation response preserves the last valid cache entry but cannot keep
  an unauthorized current session open;
- graph switch retains or deletes entries according to the architecture decision;
- local-cache deletion, catalog revocation, account replacement, and sign-out
  perform the selected idempotent cleanup;
- graph close clears only in-memory plaintext key state and does not accidentally
  publish key material in snapshots or effects.

Exercise the local secret actions through the serialized worker owner. Verify that
load failure returns a sealed scope-matched failure receipt, verified save failure
does not fail the current online session, account cleanup runs after all earlier
secret writes, and a cleanup completion from an old account cannot mutate a
replacement account.

Add negative capability tests proving that a restoring witness and textual reason
cannot create recovery, that a failure receipt cannot be used with another restore
scope, and that a recovery ticket cannot be reused. Retain an old network permit
across every generation change and assert that no network executor receives the
resulting stale action or completion.

Tests must continue to assert that only the serialized worker owner calls
`Engine.execute`. Keychain and network completions return typed, generation-scoped
events and never call the engine from a concurrent callback.

### Add scoped compiled integration fixtures

Build a synthetic managed-sync fixture containing:

- one account-scoped cached catalog and selected encrypted graph;
- one admitted local mirror with deterministic Timeline rows;
- one test private key and matching wrapped graph key supplied through the test
  secure-storage capability;
- controllable network token, catalog, E2EE, WebSocket, and pull executors that can
  fail fast, never resolve, or deliver an injected authoritative result.

From a fresh compiled application runtime, assert this sequence:

```text
local account restored
-> cached encrypted graph selected
-> mirror admitted
-> wrapped key loaded and locally unwrapped
-> engine opened
-> graph info and first progressive feed chunk applied
-> Timeline_presented
```

The valid cache-hit fixture must show the same locally resolved entries or truthful
empty state as a normal-network run. It must not emit `Fetch_e2ee_graph_key` on the
local critical path, must not wait for any network result, and must preserve the
post-presentation reconciliation barrier.

Use separate expected outcomes for failure and lifecycle cases:

| Case | Required result |
| --- | --- |
| Valid cached key with never-resolving network | Reach `Timeline_presented` with every network counter at zero before presentation. |
| Cache miss | Emit no network action in the failing local transition; enter `Recovering_online Wrapped_graph_key_unavailable` after consuming the sealed recovery ticket. |
| Corrupt, wrong-origin, wrong-user, or wrong-graph item | Queue idempotent item deletion, do not open Engine, and enter the matching recovery state. |
| Missing private key | Do not use the cached ciphertext; enter `Recovering_online Local_private_key_unavailable`. |
| Never-resolving network after recovery | Remain in the explicit recovery state without presenting a false local success or silently stalling in an unlabelled phase. |
| Immediate revocation | Present the valid local Timeline first, inject an authoritative post-presentation reconciliation event, delete the wrapped key, close access, and retain the encrypted mirror. |
| Termination | Clear abstract in-memory graph-key state, cancel pending work, restart, and load and verify the persisted wrapped key again. |
| Graph or account switch | Ignore stale Keychain and network completions by scope, and never open or mutate the replaced graph or account. |

Never-resolving executors prove that the valid cache-hit path is network
independent. Failure fixtures assert their explicit recovery terminal state rather
than incorrectly requiring `Timeline_presented`.

### Retain a controlled signed macOS profile benchmark lane

Provision the synthetic or dedicated test graph once while online on a physical
Mac, confirm the mirror, local account binding, private key, and wrapped-key item
exist, terminate the application, and then make sync endpoints unreachable. Do not
infer offline behavior merely from connectivity UI; record that token, HTTP,
WebSocket, and pull operations cannot resolve. A physical-iPhone profile run is
not required for this decision to transition to implemented.

When making a hardware performance claim, capture three terminated-app warm
launches per measured scenario on the physical Mac, with monotonic milestones for:

- Dart entrypoint;
- native startup facts;
- runtime start;
- local account binding;
- catalog cache load;
- mirror inspection;
- wrapped-key Keychain load;
- local RSA unwrap;
- engine open;
- graph info;
- first feed chunk;
- Timeline frame presentation;
- first online token and transport work.

Report every observed TTFT plus the median and maximum, Keychain-load duration,
unwrap duration, graph size, device/model, OS version, build profile, and whether
the app process and device were warm or cold. The encrypted cached-key maximum
should not exceed an equivalent unencrypted local-mirror maximum by more than
`max(50 milliseconds, 5% of the unencrypted maximum)`. A never-resolving network
must not increase the cached-key maximum by more than the same tolerance, and every
measured launch must present the local Timeline within the existing three-second
bound.

Measurements are artifact reports rather than universal CI timing thresholds.
Correctness and lifecycle transition gates remain deterministic; hardware-specific
duration comparisons run only in the controlled profile benchmark lane and are not
required when no new performance claim is made.

## Alternatives considered

### Test only the Swift Keychain wrapper

Rejected. It cannot prove that the manager avoids the E2EE token challenge, that a
stale result is generation-fenced, or that Flutter presents a locally resolved
Timeline.

### Test only with mocked secure storage

Rejected as insufficient. A fake is necessary for deterministic branch coverage,
but it cannot verify Apple Keychain attributes, signing/access-group behavior,
macOS Keychain selection, or device accessibility.

### Use a developer's existing encrypted graph as the regression fixture

Rejected. It is not deterministic, may contain private data, and makes test results
depend on mutable server and account state. It remains useful for a separate manual
profile confirmation.

### Assert one fixed TTFT budget in normal CI

Rejected. Debug/profile builds, Apple hardware, device thermal state, display rate,
and CI load are not comparable enough for one universal duration threshold. The
controlled profile lane can compare encrypted and unencrypted paths on the same
device while normal CI asserts state, operation, and security invariants.

## Acceptance criteria

- macOS and iOS unit tests prove the exact Keychain query, bounded value format,
  identity separation, replacement, and deletion contract without reading or
  mutating production Keychain items.
- Native query tests prove the account digest permits one account-wide
  `SecItemDelete` without enumerating value data and that macOS requests the
  data-protection Keychain.
- Signed platform tests exercise isolated real-Keychain items on both operating
  systems and clean them up reliably.
- Sync-manager tests prove that a valid cached wrapped key and private key open the
  graph without `E2ee_key_access` or `Fetch_e2ee_graph_key` on the local path.
- Cache-miss, corrupt-cache, missing-private-key, mismatch, rotation, revocation,
  graph-switch, account-switch, sign-out, and termination branches are covered.
- A never-resolving-network compiled fixture reaches `Timeline_presented` with the
  same deterministic local feed as the normal-network fixture.
- Failure fixtures terminate in their specified recovery state, while authoritative
  revocation is injected only after local presentation and verifies key deletion
  with mirror retention.
- Negative capability tests reject fabricated or cross-scope failure receipts,
  reused recovery tickets, stale permits, and stale completions.
- No test fixture, structured result, failure output, Timeline event, or log emits
  a plaintext or wrapped key, token, password, private-key package, or personal
  graph data.
- The controlled signed macOS profile procedure records three launches and the
  selected milestones whenever a hardware performance claim is made.
- A recorded profile run applies the selected `max(50 ms, 5%)` tolerance and the
  existing three-second bound; normal CI does not substitute debug-host timing for
  that hardware result.
- Existing E2EE, sync-manager, worker-service, application, Flutter, native host,
  and source-boundary tests remain green.

## Risks

- Real-Keychain tests can prompt, persist orphaned test entries after interruption,
  or vary with signing and host configuration. They require isolated service names,
  bounded cleanup, and a dedicated test lane.
- An in-memory backend can accidentally diverge from Keychain update and deletion
  semantics. The same contract cases must run against the real platform backend.
- macOS data-protection Keychain behavior differs from the prior unsandboxed query
  path and must be exercised by the opt-in signed lane.
- Network blackholing can be incomplete if Amplify or the OS serves cached auth
  state. Tests must observe the worker's typed network operations and unresolved
  completions rather than trusting connectivity UI alone.
- The three-launch macOS profile check is a smoke gate rather than a statistically
  strong performance sample. Every observation and the controlled device state
  must be recorded so regressions are not hidden by aggregation.
- A synthetic encrypted graph may not represent very large production mirrors.
  Graph size and encrypted row count must accompany every performance report.
- Testing deletion and revocation paths against real Keychain items is destructive
  to those test items. Production service names and real accounts must never be in
  scope.

## Decisions

- The optional controlled profile lane runs three terminated-app warm launches per
  measured scenario on a signed physical Mac before making a hardware performance
  claim. A physical-iPhone profile gate is not required.
- Normal CI runs the in-memory secure-store contract and native Keychain query
  construction tests only. Real-Keychain mutation runs in an opt-in signed lane.
- Valid cache-hit is the only fixture required to reach `Timeline_presented` while
  all network futures remain unresolved. Missing or invalid prerequisites terminate
  in explicit scoped recovery states.
- Immediate revocation is tested by injecting an authoritative reconciliation event
  after local presentation, then asserting wrapped-key deletion and mirror
  retention.
- Capability tests cover fabricated and mismatched failure receipts, recovery-ticket
  reuse, stale permits, and stale completions.

## Questions

- None.

## Implementation evidence

The native contract suite uses synthetic RSA-4096 material and debug-only in-memory
storage to verify query attributes, identity separation, bounded Transit values,
verified load/save, Engine-only unwrap, and account cleanup without touching a
production item. Both platform test targets compile the same shared Swift source.
An opt-in test uses a randomized service name in the signed host, verifies
`AfterFirstUnlockThisDeviceOnly` and non-synchronization, proves deletion, and
never addresses the production service. It was executed successfully on the
signed macOS RunnerTests host; the iOS app and RunnerTests targets completed
unsigned device build-for-testing.

OCaml capability tests cover stale Timeline acknowledgement, cross-scope failure
receipts, receipt replay, recovery-ticket reuse, account recovery, scope mismatch,
and connection permits. Manager tests cover encrypted cache hit, cache miss,
corrupt-item recovery, distinct missing-private-key recovery, stale completion,
verified save, sign-out/account cleanup, graph cleanup, revocation, graph switch,
and post-presentation reconciliation. The local failure transition emits no
network action; the explicit command is the only consumer of its ticket.

The compiled Bonsai worker fixture restores a synthetic encrypted catalog and
mirror, loads one locally verified wrapped key, opens Engine, applies the retained
cursor, and reaches Timeline presentation with no auth push before presentation.
Application integration and source-boundary tests prove the serialized owner and
local/network interpreter split. `dune runtest`, Flutter analyze and tests, the
standalone native harness, macOS RunnerTests, macOS real-Keychain opt-in test, iOS
app build, and iOS RunnerTests build-for-testing all passed on 2026-08-26.

The compiled macOS lane was rerun on 2026-08-30 with a generated encrypted mirror
and both cache-hit and missing-key fixtures. That run aligned catalog persistence
with the fixture's origin-and-account SHA-256 path, removed the obsolete
`pending-intents-v1.json` file when opening a managed mirror, held catalog and
WebSocket authentication behind local Timeline presentation, and made missing-key
recovery an explicit user action. A late same-account authentication result cannot
clear that recovery state, and client command acknowledgements no longer carry a
staleable state snapshot. The Flutter harness explicitly resumes the test lifecycle
when the macOS test launcher cannot foreground the app. The cleaned compiled lane
reached Timeline locally with zero pre-presentation token requests and reached the
explicit recovery UI with zero token requests in the missing-key case.

No new physical-profile TTFT numbers are claimed by this implementation. The
three-launch procedure and tolerance remain the required artifact format for a
future hardware performance claim; the prior iPhone baseline in the Problem
section remains historical context rather than evidence for this implementation.

## Consequences

Normal CI now proves the security and state-machine invariants with synthetic,
deterministic fixtures and cannot silently depend on network completion. Real
Keychain mutation remains opt-in and isolated. Hardware timing claims require the
separate signed profile artifact procedure, so debug-host test duration is never
presented as product TTFT.
