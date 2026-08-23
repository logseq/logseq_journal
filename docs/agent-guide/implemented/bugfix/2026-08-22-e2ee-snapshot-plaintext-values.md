# E2ee Snapshot Plaintext Values

## Problem

Deployed E2EE snapshots can contain both Transit AES-GCM envelopes and ordinary
plaintext strings in the protected `block/title` and `block/name` attributes. The
current worker assumes every protected string is an encrypted envelope. Importing
the deployed `Lambda RTC` snapshot therefore rolls back when it reaches a plaintext
title, and the application reports that the graph storage is corrupt or incomplete.

The pinned upstream Logseq implementation treats a protected string that is not
valid Transit as plaintext and preserves it. It only attempts AES-GCM decryption
when the decoded value has the encrypted envelope shape.

## Decision

Match the pinned upstream protected-value decoding contract in
`Sync_e2ee.decrypt_value`:

- preserve a source string verbatim when it is not valid Transit;
- return a valid non-encrypted Transit value without invoking crypto;
- decrypt an actual `[iv, ciphertext]` Transit binary envelope and decode its
  plaintext Transit value;
- continue rejecting authentication failures, malformed encrypted payloads, and
  protected values that do not materialize as strings.

This changes only protected-value decoding during snapshot and transaction import.
It does not bypass graph-key verification, weaken AES-GCM authentication, change the
protected attribute set, or modify any public `.mli` contract.

## Alternatives considered

### Require every protected value to be encrypted

Rejected because it contradicts the pinned upstream decoder and prevents a real,
authorized E2EE graph from opening.

### Disable E2EE materialization for snapshot bootstrap

Rejected because it would persist ciphertext in the local mirror and expose encoded
values in the application instead of fixing the protected-value contract.

### Ignore all decrypt failures

Rejected because a valid encrypted envelope with a wrong key or damaged
ciphertext must still fail AES-GCM authentication.

## Acceptance criteria

- Unit tests prove plaintext protected strings pass through without a crypto call.
- Unit tests prove valid encrypted envelopes are still decrypted and authenticated.
- The deployed snapshot contract imports the captured `Lambda RTC` snapshot with
  mixed plaintext and encrypted protected values.
- A signed macOS Release downloads, imports, and opens `Lambda RTC`; its local
  SQLite mirror passes `PRAGMA integrity_check`. The download ingests 65,145 framed
  rows and E2EE materialization compacts them into 20,371 local `kvs` rows.

## Consequences

Mixed deployed E2EE snapshots materialize as plaintext mirrors without weakening
graph-key verification or AES-GCM authentication. Plaintext protected values no
longer cause the entire bootstrap transaction to roll back.

## Risks

- A protected string that is not valid Transit is intentionally treated as
  plaintext. This is the deployed upstream behavior; valid encrypted envelopes
  remain fail-closed when authentication or decoding fails.

## Questions

- None. The captured deployed artifact and the pinned upstream implementation
  establish the required behavior.
