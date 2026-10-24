# Safe Sync Error Reasons

## Problem

Authoritative integrity failures discard their producer reason in the effect runner, then the Worker ledger discards details again. Similar mappers flatten useful bounded reasons, while raw source strings may contain graph content or secrets.

## Decision

Preserve producer-owned reason codes and bounded numeric context through the existing Error details and Diagnostic signal path. Integrity diagnostics contain checkpoint, expected cursor, batch through, frozen interval, outbox operation/state and datom counts when available, never transaction values or custom property names. Keep existing error variants, blocking and durability behavior. Audit comparable catch/mapping sites and preserve known safe native account messages. Retain the existing uncommitted Local tx / Remote tx enhancement.

## Alternatives considered

### Forward raw error strings

Rejected: some payload mismatch strings contain private property names, and external exceptions can contain paths, URLs or credentials.

### Change public sync variants or validation

Rejected: this is diagnostic work. Existing string payloads can carry validated versioned metadata without changing protected spec interfaces or synchronization decisions.

## Acceptance criteria

- A real synthetic own-echo mismatch propagates a specific safe reason and context into Last error and Worker errors without advancing the checkpoint or consuming the outbox.
- All known integrity sources have stable distinct reason codes. Invalid or unknown diagnostic input fails closed; 64-bit cursor values remain exact strings.
- Similar error mappings are catalogued with fixes or explicit safety/recovery rationale. Known safe native account errors retain their text; cancellation and retired owners remain quiet.
- Existing applicable tests pass. An isolated Simulator fixture renders a concrete integrity reason and Local tx / Remote tx without touching the authorized live graph.
- No spec/ or dune modifications; no PR, release, production sync algorithm or real graph fault injection.

## Risks

- Unknown raw exceptions cannot safely be exposed verbatim; only controlled categories are shown until a producer supplies structured context.
- Host-restamped Simulator acceptance remains experimental and does not prove full target ABI equivalence.

## Questions

- Scope and authorization are resolved by the explicit user request to expose error reasons and inspect swallowed messages. No additional product decision is needed.

## Consequences

The producer now emits twelve finite integrity reasons (plus unknown), preserving safe checkpoint/through/expected cursor, frozen interval, outbox operation/state, and datom counts when available. Exact int64 cursors remain decimal strings. The former attribute-name shape concatenation is removed. Worker Error details and the scoped diagnostic signal preserve these fields into Last error and Worker errors. Existing Error.code values, failure branches, commit checks and outbox retention behavior remain unchanged.

Other repaired mappings include local commit, outbox, snapshot activation, open/listen/inspect, close, lower SQLite stage/source forwarding, known native account errors and current retry failures. HTTP/WebSocket TLS setup retains finite DNS/address/configuration/authentication categories; Upgrade retains its numeric status. Unknown external text is reduced to a safe class, not echoed. Existing cancellation/cleanup rules remain. Diagnostics are published only when Sync accepts the associated failure; existing pure tests caught both snapshot and inherited late-restore/authoritative scope misattribution before the common fence repair.

Regression ownership is split by actual boundary: the pure worker reducer owns stale diagnostic publication; it cannot execute database integrity comparison, protected replay, runner mapping, service-carrier validation or native account presentation. A public temporary Database fixture creates and accepts a local mutation, then the actual runner applies a distinct authoritative echo. It verifies specific reason propagation, unchanged checkpoint and retained outbox. The existing service tests own strict carrier decoding/privacy/bounds. The existing storage test verifies safe snapshot-parser forwarding. Native submit/retry tests use their actual presentation owners. No protected spec or Dune file changed; the public lib-only SQLite diagnostic formatter and bounded diagnostic interfaces are ordinary implementation APIs.

Final applicable checks pass: 318 sync cases (including nine new real transport cases), 50 worker runner cases, 20 worker pure reducer cases, 85 storage cases, 98 overlay sync cases, and the service suite. Native authentication/services/Cognito suites and build-helper checks pass (54 helper tests, one skipped). Standalone source-class/forwarding probes demonstrate rejection of sensitive sentinels, invalid descriptors, duplicate fields and noncanonical/overflowing cursors.

An account-free, bundle-isolated Simulator fixture mounts the production Diagnostics page using values exported by the synthetic runner failure; Local tx 0 / Remote tx 1, payload-mismatch, datom counts, frozen interval and accepted outbox state are visually readable. It uses the production extension registry. The ordinary local candidate 1.0 (1.5877.6504) also starts on A135 with the authorized test graph, Current/Ready/Open, Local tx 930 / Remote tx 930, outbox 0 and no Last error row. No new graph blocks or real fault injection were performed. CoreSimulator reassigned its data-container path during update; existing test markers, checkpoint and outbox metadata remained present. These are host-restamped experimental builds with cross_abi_validated=false, not full iOS ABI proof or a TestFlight release.

Two external source audit inventories and the final disposition report distinguish repaired mappings from safe generic/optional/cancellation behavior and enum/nil/native-boundary information already erased upstream. This is not a claim to expose arbitrary raw exception messages or to have diagnosed the user's original Capture failure. Future detailed asset/native-platform causes need producer-owned safe metadata; no protected-interface changes were made speculatively.

All reports, temporary probes, generated hosts, cache contents and screenshots remain in the task's external evidence directory. The decision passes its own validation; the repository-wide decision check has the same five pre-existing unrelated format failures. No commit, push, PR, merge or release was performed.
