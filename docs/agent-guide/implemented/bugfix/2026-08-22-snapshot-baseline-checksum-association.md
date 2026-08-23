# Snapshot Baseline Checksum Association

## Problem

The snapshot bootstrap transport requests the current pull state and then obtains a
separate snapshot stream URL. It currently passes the pull response checksum to the
worker as though that checksum authenticated the separately returned snapshot.

The deployed service does not bind the pull checksum to the snapshot download
metadata. For `Lambda RTC`, the pull checksum is `ea7cc3e749a3dd0d` while the
downloaded snapshot computes to `c27f6e30b0aee65a`. The worker therefore rejects a
structurally valid, fully imported snapshot and the graph cannot open. The pinned
upstream download flow uses the pull `t` as the remote cursor but does not apply its
checksum to snapshot import.

## Decision

Keep validating the optional checksum field in the pull response, but do not attach
it to the independently downloaded snapshot bootstrap. Return a null bootstrap
checksum so the worker computes and persists the checksum from the imported local
mirror.

The pull `t`, snapshot row count, stream framing, E2EE handling, and later replay
checksum validation remain unchanged.

## Alternatives considered

### Reject when the pull and snapshot checksums differ

Rejected because the deployed APIs provide no version or checksum association
between those two responses, and the pinned upstream client does not make this
comparison.

### Persist the pull checksum without validation

Rejected because it would record a checksum that was not computed from the local
mirror and would make subsequent local integrity checks inconsistent.

### Remove checksum validation from later sync replay

Rejected because replay responses are versioned against an existing local cursor;
their checksum has an association that the separate snapshot endpoint lacks.

## Acceptance criteria

- The snapshot transport test proves a pull checksum is validated but is not emitted
  as the downloaded snapshot checksum.
- Snapshot bootstrap computes and persists a checksum from the imported mirror when
  no snapshot-bound checksum exists.
- A signed macOS Release downloads, imports, and opens `Lambda RTC`; its SQLite
  mirror passes `PRAGMA integrity_check`. The download ingests 65,145 framed rows,
  E2EE materialization compacts them into 20,371 local `kvs` rows, and the mirror
  persists its computed checksum `c27f6e30b0aee65a`.

## Consequences

`Lambda RTC` no longer fails against the unrelated pull checksum. Snapshot import
continues to validate framing, row count, graph identity, schema, SQLite integrity,
and local computed checksum persistence; later cursor-bound replay checksum checks
are unchanged.

## Risks

- Snapshot bootstrap cannot authenticate graph contents with the pull checksum.
  Structural import validation, graph identity admission, SQLite integrity checks,
  HTTPS transport, row-count validation, and later cursor-bound replay checks still
  apply.

## Questions

- None. The deployed responses and pinned upstream download implementation establish
  that the pull checksum is not snapshot-bound.
