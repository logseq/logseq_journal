# Nullable Pull Outliner Op

## Problem

A signed physical-iPhone bootstrap reaches the populated `ocaml-sync-test` graph
but pauses sync with `outliner-op must be a string`. A read-only shape probe against
the same deployed pull endpoint captured 115 transactions: 111 contain a string
`outliner-op`, while transactions 112 through 115 contain the field with JSON
`null`. No transaction omitted the field and no other value type was observed.

`Sync_protocol.decode_pull_tx` currently uses the generic optional-string decoder,
which accepts an omitted field or a string but rejects JSON `null`. The deployed
pull contract therefore cannot replay the latest authoritative transactions, even
though `outliner-op` is metadata and the transaction payload itself is valid.

## Decision

Decode pull-transaction `outliner-op` as an optional nullable string: a string
becomes `Some value`, while an omitted field or JSON `null` becomes `None`.
Continue rejecting numbers, booleans, arrays, and objects.

Keep the change local to `decode_pull_tx`. Other optional protocol fields retain
their current contracts; in particular, a present null checksum, rejection data,
or transaction ID remains invalid unless independently verified against the
deployed contract. The client encoder continues omitting `outliner-op` when it has
no value because this decision only models current server pull responses.

## Implementation evidence

The sanitized deployed fixture now records the accepted transaction at server
cursor 115 with `"outliner-op": null`. Protocol tests exercise that fixture through
the HTTP pull decoder and retain coverage for a string value, an omitted value, and
an invalid numeric value.

After the decoder change, the signed physical-iPhone app replayed the deployed
graph and rendered its journal without the former `outliner-op must be a string`
sync error.

## Alternatives considered

### Reject null and require a server migration

Rejected because null is the current deployed response for accepted transactions
and prevents clients from completing authoritative catch-up.

### Make every optional string nullable

Rejected because it would silently relax unrelated checksum, rejection, and
transaction-ID contracts without server evidence.

### Convert null to an empty string

Rejected because an absent outliner operation and an empty operation name are not
the same typed value. The existing OCaml representation already models absence as
`None`.

## Acceptance criteria

- A pull transaction with string `outliner-op` decodes to `Some value`.
- A pull transaction with omitted `outliner-op` decodes to `None`.
- A pull transaction with JSON null `outliner-op` decodes to `None`.
- A pull transaction with a non-string, non-null `outliner-op` is rejected.
- The deployed duplicate-tx fixture preserves the captured null field and decodes
  through the HTTP pull path.
- The signed physical-iPhone app completes authoritative replay without the former
  `outliner-op must be a string` failure.

## Consequences

- Treating null as absent discards any distinction the server might intend between
  omitted and null. The current engine has no consumer for that distinction, and
  the deployed endpoint currently emits null rather than omission.

## Questions

None.
