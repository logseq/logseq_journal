# Retire Pre-Reducer Sync Runtime Residue

## Problem

The pure-core cutover replaced the mutable `Logseq_sync.Api` orchestration with
`Logseq_sync.Core` and `Logseq_sync.Effect_runner`, but several private runtime
modules still retain state, parsers, and helpers whose only consumers were
deleted by that cutover.

`logseq_sync/lib/core/catalog.ml` is the clearest example. The current runtime
uses only `Catalog.decode` to validate a remote graph catalog. The module still
defines a second catalog-cache model with `base_url`, selected graph, and mirror
status; merge and selection policy; and a complete JSON codec. Its former
production consumers were the deleted `logseq_sync/lib/api.ml` and
`logseq_sync/lib/storage/catalog_store.ml`. The current cache contract and codec
now live in `Logseq_sync.Core.catalog_cache`, and `Effect_runner` persists that
opaque value through `Core.encode_catalog_cache` and
`Core.decode_catalog_cache`.

The same residue appears in three other private runtime helpers:

- `Bootstrap.decode_baseline`, `decode_snapshot_metadata`, their result types,
  and `maximum_gzip_layers` have no current consumer. The deleted `Api` used the
  two parsers; `Core` now owns `decode_snapshot_baseline` and
  `decode_snapshot_uri`. `Effect_runner` still legitimately consumes only
  download progress, row-count validation, cleanup, and bounded gzip peeling.
- `E2ee.unavailable_crypto`, `protected_attributes`, `unlock_graph_key`,
  `transform_attribute_value`, and `encrypt_value` have no current consumer.
  The current runner owns scoped graph-key handles and batch encryption, while
  `Platform_crypto` consumes only `private_key_package` and `binary`, and the
  encrypted snapshot path consumes `decrypt_value`.
- `Http.websocket_uri` and `redacted` have no current consumer. `Core` now emits
  the WebSocket URI as data, and request diagnostics no longer use `redacted`.
  The `Post` method and optional request body are also unexercised because every
  current HTTP request constructor creates a `Get` request without a body.

These modules are private in `logseq_sync_impl`; tests may not import them under
the implemented public-API-only test boundary. Repository-wide exact-name and
qualified-reference searches therefore cover all supported consumers. Keeping
the retired surface creates two apparent owners for catalog and snapshot
parsing, preserves dead crypto policy, and makes the effect runtime look more
capable than it is.

## Proposal

Trim each private runtime module to the operations consumed by the current
`Effect_runner` and platform adapter:

- reduce `Catalog` to the remote graph-catalog decoder and its private decoding
  helpers;
- reduce `Bootstrap` to download progress, row-count validation, cleanup, and
  bounded gzip peeling;
- reduce `E2ee` to private-key-package decoding, binary graph-key decoding, and
  protected-value decryption, with the narrowest crypto callback shape required
  by those operations; and
- remove the unused WebSocket URI, request-redaction, POST, and request-body
  surface from `Http` if a final constructor search still proves that every
  request is bodyless GET.

Delete the matching declarations from the private `.mli` files instead of
leaving aliases or compatibility wrappers. Do not move the removed policy into
another helper: catalog-cache persistence, snapshot response interpretation,
WebSocket planning, and protected-value batch planning remain owned by `Core`;
filesystem, transport, platform-secret, and cryptographic execution remain
owned by `Effect_runner` and its runtime adapters.

This change must not modify `logseq_sync/spec/*.mli`, any Dune file, public
constructors, effect ordering, wire payloads, error messages on live paths,
artifact cleanup, key zeroization, or worker authority. The expected result is
net deletion from private implementation modules and one source of truth for
each policy.

## Decision

Remove the retired private runtime surfaces and keep only the operations consumed
by the current `Effect_runner` and platform adapter. `Catalog` retains remote
catalog decoding, `Bootstrap` retains bounded artifact processing, `E2ee` retains
platform-envelope decoding and protected-value decryption, and `Http` retains
bodyless GET request construction and response validation.

Do not add aliases, compatibility wrappers, fallback parsers, or replacement
policy helpers. `Core` remains the sole owner of catalog-cache persistence,
snapshot response interpretation, WebSocket planning, and protected-value batch
planning.

## Alternatives considered

### Keep the residue as private implementation documentation

Private dead code does not document the active boundary reliably. Several
helpers already describe the deleted mutable `Api` architecture and duplicate
code in `Core`, so retaining them makes future edits more likely to target the
wrong owner.

### Make `Core` call the old parsers and cache model

That would restore runtime-module dependencies to the dependency-restricted
pure core or move effectful modules into the pure library. It conflicts with the
implemented pure-core boundary and replaces deletion with dependency churn.

### Delete all helper modules and inline their live operations

`Catalog.decode`, bounded artifact processing, platform envelope parsing, and
HTTP request construction each retain multiple live operations and focused
policy. Inlining them into the 660-line effect runner would relocate complexity
rather than remove it.

### Merge outgoing and incoming transaction codecs

The outgoing logic in `pure_core.ml` stabilizes entity references and prepares
encryption; `pure_tx.ml` validates untrusted remote Transit and applies decrypted
values. Their opposite trust directions and error contracts are active policy,
not obsolete runtime residue.

## Acceptance criteria

- `Catalog` exposes and implements only the remote catalog decoding needed by
  `Effect_runner`; the obsolete cache, mirror-status, selection, merge, and cache
  JSON surfaces are deleted.
- `Bootstrap` contains no baseline or snapshot-metadata response parser and no
  unused gzip-layer constant; its live bounded artifact behavior is unchanged.
- `E2ee` contains no unavailable adapter, old graph-key unlock composition,
  protected-attribute traversal, or outgoing value encryption helper; the live
  platform envelope and protected-value decryption behavior is byte-for-byte
  compatible.
- `Http` contains no unused WebSocket URI or redaction helper. POST/body support
  is deleted only if a final production and test consumer search remains empty.
- No alias, fallback, deprecated symbol, or alternate cache/snapshot parser is
  introduced.
- `logseq_sync/spec/core.mli`, `logseq_sync/spec/effect_runner.mli`, Dune files,
  public worker behavior, wire values, errors on live paths, and side effects are
  unchanged.
- `dune runtest logseq_sync/test`, `dune runtest`, `dune build @all`,
  `dune build @fmt`, `git diff --check`, and the source-boundary tests pass.

## Risks

- A constructor reached through a first-class value could evade a qualified-name
  search. The implementation must pair exact symbol searches with reading every
  current module that links the private runtime helpers.
- Removing POST/body support is safe only while every current request constructor
  remains bodyless GET; otherwise that portion must be retained without weakening
  the rest of the decision.
- Tightening the E2EE crypto callback can accidentally change malformed-envelope
  behavior. Existing encrypted snapshot and authoritative-pull contract tests
  must preserve exact success and failure results.
- The current worktree also contains an in-progress encrypted-read-path fix.
  Implementation must begin from its final state rather than editing around
  intermediate unstaged code.

## Consequences

The private runtime boundary is smaller and no longer presents the deleted
pre-reducer orchestration as an available architecture. Catalog-cache and
snapshot-response policy have one active owner in `Core`, while transport,
artifact, platform-secret, and cryptographic execution remain in the effect
runtime.

All current HTTP runtime requests are represented as bodyless GET operations.
Adding a future write request will require a new explicit transport decision
rather than reactivating the retired generic POST/body surface.

## Questions

- None.
