# Keychain Backed Wrapped Graph Key Cache

## Problem

An encrypted managed-sync graph can retain a valid local SQLite mirror and the
user's RSA private key while still requiring an online E2EE graph-key request on
every application launch. `Sync_manager.open_selected_graph` currently creates an
`E2ee_key_access` token challenge for every encrypted graph. The worker fetches the
server's `encrypted-aes-key`, passes that wrapped value to the Apple crypto bridge,
and opens the mirror only after the locally stored private key unwraps a 32-byte
graph key.

This keeps the plaintext graph key in memory only, but it makes encrypted warm
startup depend on a fresh ID token and an HTTP response. Physical iPhone profile
measurement found that catalog restore and mirror admission each took less than
two milliseconds while one E2EE graph-key request took approximately 539
milliseconds. Across nine complete warm launches, time from the Dart entrypoint to
the first locally resolved Timeline frame had a 1.061-second median and a
2.502-second p95. Network variation occurred before engine open even though the
1.1 MB mirror already existed.

The implemented local-Timeline startup decision explicitly excludes an encrypted
mirror when graph-key material is unavailable locally. The missing capability is
not storage of the plaintext AES key. It is durable, device-only storage of the
server-provided wrapped graph key, scoped tightly enough that it can only be
unwrapped with the correct locally retained user private key for the correct
account, sync origin, and graph.

The cache is security-sensitive. An incorrectly scoped entry could open one
account's retained graph while another account is active. Over-retention could
preserve offline access after sign-out or revocation. Over-aggressive deletion
would silently remove the intended encrypted offline capability. Key rotation,
corrupt Keychain items, application reinstall, catalog revocation, graph deletion,
and account replacement therefore need explicit behavior rather than an advisory
best-effort cache with undefined lifetime.

## Decision

Add an application-owned wrapped-graph-key store to the shared Apple native crypto
implementation used by macOS and iOS. Store only the exact bounded
`encrypted-aes-key` value accepted from a successful server response. Never store
the unwrapped 32-byte graph key, an ID token, password, private-key package,
plaintext private key in the wrapped-key item, graph content, or Timeline
projection.

### Use one device-only Keychain item per account, origin, and graph

Use an Apple Keychain generic-password item distinct from the existing E2EE
private-key and local-account-binding services:

```text
kSecClass: kSecClassGenericPassword
kSecAttrService: com.logseq.journal.e2ee.wrapped-graph-key
kSecAttrAccount: lowercase SHA-256 hex of the canonical lookup identity
kSecAttrGeneric: SHA-256 bytes of the canonical account identity
kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
kSecAttrSynchronizable: false
kSecValueData: bounded versioned encoding
```

The canonical lookup identity is a length-delimited encoding of:

```text
version
managed_sync_origin
user_id
graph_id
```

The origin must be one normalized HTTPS origin and the graph identifier must be a
canonical UUID. Hashing the lookup identity keeps raw account and origin strings
out of Keychain account metadata while retaining deterministic lookup. The hash is
an identifier, not an authentication mechanism; every decoded value must repeat
and exactly match the requested origin, user, and graph before use.

The canonical account identity is a separate length-delimited encoding of version,
managed sync origin, and user ID without a graph ID. Store its SHA-256 digest as
`kSecAttrGeneric`. Exact graph lookup continues to use the full
`kSecAttrAccount` digest. Account-wide cleanup queries the service and
`kSecAttrGeneric` digest and calls `SecItemDelete`, which deletes every matching
item without enumerating or decoding the values. A corrupt value therefore cannot
escape sign-out cleanup.

Use a bounded version-1 value with these fields:

```text
version
managed_sync_origin
user_id
graph_id
encrypted_graph_key
```

The complete encoded item must not exceed 128 KiB. The wrapped value must pass the
existing E2EE response bound and Transit-binary validation before persistence and
again after loading. Do not add a legacy decoder, format fallback, migration, or
filesystem copy. Unsupported, malformed, mismatched, or cryptographically
unusable items are deleted and treated as cache misses.

On macOS, set `kSecUseDataProtectionKeychain` to true for wrapped-key and retained
private-key operations so
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is enforced. On iOS, use the
signed application's default Keychain access group. Neither platform synchronizes
the item through iCloud. The opt-in signed Keychain lane must verify the exact
access group, accessibility, device-only behavior, and non-synchronization on both
platforms.

Scope the retained private-key item by the same canonical account identity digest
rather than the raw user ID. The wrapped-key item and private-key item remain in
distinct services, but an origin and user pair now selects exactly one retained
private key and supports exact sign-out deletion.

### Save only after validation and successful local unwrap

When a current-generation `Fetch_e2ee_graph_key` response arrives:

1. parse the response through the existing closed E2EE response decoder;
2. ask the native crypto bridge to unwrap and verify it with the account-scoped
   locally stored private key without returning the plaintext key to the manager;
3. require native unwrap to produce an exact 32-byte plaintext graph key;
4. atomically add or replace the scoped wrapped-key Keychain item;
5. return only the verified wrapped key and continue opening Engine, which owns its
   own unwrap and abstract in-memory key lifetime.

The native verify-and-save operation receives the wrapped value, never the
plaintext result.
A Keychain write failure must be observable as non-secret diagnostic state but must
not discard the successfully unwrapped in-memory key or fail the current online
session. It only makes the next launch ineligible for the encrypted local fast
path.

An authoritative online graph-key response that differs from the cached wrapped
value replaces the cache only after successful unwrap. A response that cannot be
unwrapped must not overwrite the last valid item. Current-session authorization
and rotation handling may still close the graph according to the existing
generation-fenced reconciliation policy.

### Attempt local unwrap before creating an E2EE token challenge

After a current selected encrypted graph passes normal mirror inspection, perform
the local sequence in the serialized manager lane:

```text
load scoped wrapped key
-> validate identity and value
-> require the scoped local private key
-> unwrap and verify an exact 32-byte graph key inside native crypto
-> return only the verified wrapped key
-> Open_graph
```

A valid local result must not create an `E2ee_key_access` challenge and must not
wait for Amplify, ID-token refresh, the E2EE graph-key endpoint, catalog HTTP,
WebSocket state, or pull. Online authentication and reconciliation may continue in
the independent online lane established by the local-Timeline startup decision.

A missing item, missing private key, corrupt item, identity mismatch, or unwrap
failure deletes any unusable item and follows the normal authenticated E2EE
recovery path. This is the primary cache-miss behavior, not a backward-
compatibility layer. It must remain generation-scoped so a late Keychain result
cannot open a replaced account or graph.

The manager and `Sync_e2ee_session` retain only the wrapped key and verification
state. The plaintext graph key may exist only as an abstract, non-string
`Sync_graph_key.t` inside the Engine crypto execution boundary. It must never
appear in a manager action, event, snapshot, serialized configuration, catalog
cache, Dart startup payload, preferences, diagnostics, or logs. Engine close,
graph switch, account change, sign-out, cancellation, and process termination
perform best-effort zeroization of its mutable backing storage.

### Give native code a narrow storage contract

Extend the shared `JournalE2EECrypto` bridge with bounded operations equivalent to:

```text
loadAndVerifyWrappedGraphKey(origin, user_id, graph_id)
verifyAndSaveWrappedGraphKey(origin, user_id, graph_id, encrypted_graph_key)
deleteWrappedGraphKey(origin, user_id, graph_id)
deleteAccountSecrets(origin, user_id)
```

Native Swift owns Keychain query construction, canonical identity hashing, value
encoding, unwrap verification, and deletion. OCaml owns account, graph, action
ordering, and generation decisions. `deleteAccountSecrets` deletes every wrapped
graph key selected by the account digest and the retained private key from its
separate service, and reports per-component success without returning secret data.
Flutter must not receive wrapped or plaintext graph keys, and the `LDB1` startup
envelope remains credential-free.

### Define invalidation as part of the security boundary

The lifecycle is:

- graph switch: retain the previous graph's item because its local mirror remains;
- explicit local-cache deletion: delete the graph's wrapped-key item;
- authoritative graph deletion or catalog revocation: delete the graph's item when
  post-presentation reconciliation applies the revocation, but retain the encrypted
  mirror until explicit local-cache deletion;
- successful key rotation: replace the item only after validating and unwrapping
  the new wrapped value;
- private-key replacement or unusable cached ciphertext: delete the affected item
  and require normal E2EE recovery;
- account replacement: make the prior account inaccessible immediately through
  identity scoping, then delete that account's wrapped graph keys and retained
  private key;
- explicit sign-out: delete the account's wrapped graph keys and retained private
  key;
- application uninstall or missing mirror: never use or enumerate an orphaned item
  to select a graph; mirror and catalog admission remain authoritative.

All deletion operations are idempotent. Failure to delete must not expose a key to
another account because every lookup remains fully scoped, but it must surface a
non-secret error suitable for retry during orderly shutdown or later
reconciliation.

Keychain load, verify-and-save, graph deletion, and account deletion are serialized
local actions. Sign-out first advances the account generation and clears access to
the old account, then executes `deleteAccountSecrets` with the captured old account
identity after all earlier secret writes. Its completion may update only non-secret
cleanup diagnostics and cannot mutate a replacement account.

## Alternatives considered

### Persist the plaintext 32-byte graph key

Rejected. This removes the local private-key unwrap boundary, unnecessarily
increases the impact of a Keychain item disclosure, and permits accidental use
without proving that the correct account private key is still present.

### Store the wrapped key in the catalog cache or SQLite mirror

Rejected. Both are filesystem state rather than the selected device-only secret
store. The catalog is advisory and contains graph selection metadata; the mirror
contains encrypted graph data. Adding wrapped key material to either broadens
backup, logging, copying, and file-permission exposure and contradicts the existing
startup decision.

### Store one item containing every graph key for an account

Rejected. Updating or deleting one graph would rewrite unrelated secrets, corrupt
data would affect every graph, and least-privilege cleanup after graph deletion or
revocation would be harder to prove.

### Cache only the unwrapped graph key in process memory

Rejected as insufficient. The current session already retains the plaintext key in
memory. Process memory cannot support a terminated-app warm launch or an offline
device restart.

### Require network access for every encrypted launch

Rejected because it leaves encrypted graphs outside the selected local warm-start
contract even when all graph content and the user's private key already exist on
the device. The physical-device measurement shows that this request dominates the
otherwise local path and creates its long tail.

## Acceptance criteria

- macOS and iOS store one device-only, non-synchronizable generic-password item per
  normalized origin, user, and graph under a service distinct from all existing
  Journal Keychain services.
- Exact graph identity uses `kSecAttrAccount`; account-wide cleanup uses a separate
  origin-and-user digest in `kSecAttrGeneric` and does not enumerate item values.
- macOS uses the data-protection Keychain for these items so the selected
  `AfterFirstUnlockThisDeviceOnly` accessibility is effective.
- The item contains only a bounded versioned wrapped graph key and its lookup
  identity. No plaintext graph key, private key, token, password, graph content, or
  Timeline content is persisted or logged.
- A valid local mirror, local account binding, scoped private key, and scoped
  wrapped key open an encrypted graph without `E2ee_key_access`, fresh ID token, or
  `Fetch_e2ee_graph_key` being a dependency of `Timeline_presented`.
- A cache miss follows the current authenticated server recovery flow and saves the
  wrapped value only after successful validation and unwrap.
- Unsupported, corrupt, mismatched, or cryptographically unusable items are never
  used, are deleted, and do not open a graph under the wrong account, origin, or
  graph generation.
- Key rotation replaces a cached value only after the new response unwraps to an
  exact 32-byte key. A failed response cannot poison the last valid item.
- Graph deletion, local-cache deletion, revocation, account replacement, and
  explicit sign-out follow the defined lifecycle without retaining an accessible
  stale item. Revocation deletes the wrapped-key item but retains the encrypted
  mirror until explicit local-cache deletion.
- Plaintext key material is represented only by abstract `Sync_graph_key.t` inside
  the Engine crypto boundary, never as a manager/session/action/event string, and
  is cleared on every graph and account teardown path.
- The dependent typed-startup decision owns the required `spec/*.mli` and Dune
  changes. The `LDB1` payload and Flutter startup payload remain credential-free,
  and no bonsai_flutter repository file changes.

## Implementation evidence

The shared `flutter/JournalE2EECrypto.swift` implementation now owns normalized
origin and canonical graph identity validation, length-delimited SHA-256 account
and graph digests, the version-1 bounded item encoding, the distinct wrapped-key
service, data-protection Keychain selection on macOS, device-only accessibility,
non-synchronizable queries, verified save/load, graph deletion, and account-wide
secret deletion. The same origin-and-user digest scopes retained private keys.

`Sync_manager` performs mirror inspection, wrapped-key load and verification, and
Engine open as serialized local actions. Cache failure carries a sealed receipt
from the local interpreter and enters `Recovering_online` without constructing
network work. `Begin_online_recovery` consumes the matching one-shot ticket before
the existing E2EE flow can request a token. Sign-out, account replacement, local
cache deletion, and catalog revocation emit the scoped cleanup actions described
above.

Plaintext graph keys are abstract `Sync_graph_key.t` values owned by Engine. The
manager, E2EE session, actions, events, snapshots, configuration, and startup
payloads carry no plaintext key string. Engine close clears the mutable key bytes.

Validation evidence includes the standalone RSA-4096 Swift contract harness,
signed macOS RunnerTests, the opt-in isolated real-Keychain macOS test, successful
iOS app and RunnerTests build-for-testing, focused manager/E2EE/Engine tests, the
encrypted worker fixture, compiled application integration, source-boundary
checks, Flutter tests, and the complete `dune runtest` suite.

## Consequences

Encrypted mirrors with complete local key material now participate in the same
network-independent warm-start contract as unencrypted mirrors. The application
owns one additional device-only secret per retained encrypted graph and must keep
its cleanup ordering, origin/account scoping, native validation, and Engine
zeroization behavior covered whenever sync startup changes.

## Risks

- Device compromise after first unlock may expose both the private-key item and the
  wrapped-key item to code running with the application's Keychain entitlement.
  This proposal improves offline availability; it does not defend against a fully
  compromised unlocked device.
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` permits background and warm
  startup after the first device unlock but is less restrictive than requiring the
  device to be currently unlocked.
- Keychain items may outlive application files or an app reinstall. Catalog and
  mirror admission must remain authoritative, and explicit cleanup can still fail.
- The macOS data-protection Keychain path differs from the previous unsandboxed
  query behavior and requires signed-host validation.
- Retaining per-graph items increases secret-lifecycle complexity for revocation,
  account replacement, and key rotation.
- A stale but cryptographically valid wrapped key can open retained local data
  before online revocation is known. This is the same explicitly accepted offline
  access trade-off as the local-Timeline startup decision.
- Synchronous Keychain access and RSA-4096 OAEP unwrap add local latency to engine
  open. They must be measured separately from network latency.

## Decisions

- Explicit sign-out deletes both the account's wrapped graph keys and its retained
  private key.
- Wrapped-key items use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so unattended warm and
  background startup can use them after the device's first unlock.
- Authoritative graph deletion or catalog revocation deletes only the wrapped-key
  item. The encrypted mirror remains until explicit local-cache deletion.
- `kSecAttrGeneric` stores the account-scope digest, and account-wide cleanup uses
  one matching `SecItemDelete` query rather than service-wide value enumeration.
- Retained private keys use the same origin-and-user account scope, and explicit
  sign-out executes one serialized `deleteAccountSecrets` operation.
- macOS uses `kSecUseDataProtectionKeychain` so the selected
  `AfterFirstUnlockThisDeviceOnly` accessibility is enforceable.
- Plaintext graph keys are confined to abstract `Sync_graph_key.t` values inside
  the Engine crypto boundary and never enter manager actions, events, or sessions.

## Questions

- None.
