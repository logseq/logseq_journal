# Standalone Sync Protocol ADT

> The protocol schema and validation decisions in this document remain current.
> Its original duplicate-ADT and adapter implementation was superseded by
> [Split Sync Pure Reducer Effect Runner Libraries](2026-08-29-split-sync-pure-reducer-effect-runner-libraries.md),
> which makes the public protocol ADT the single representation used directly by
> the reducer and effect runner.

## Problem

`logseq_sync` does not have one module that owns the application-level WebSocket
protocol between the sync client and server. The current implementation spreads
the contract across `logseq_sync/lib/pure_core.ml`:

- `authoritative_message` models only the authoritative subset of inbound
  messages;
- `parse_authoritative_message` decodes `pull/ok`, `hello`, `changed`, and
  `tx/batch/ok` directly from JSON;
- `pull_payload` and `submission_payload` construct outbound JSON without a
  client-message ADT; and
- `pong` and `online-users` are represented by a sentinel error string rather
  than typed messages.

The public `Core` interface consequently exposes raw WebSocket payloads as
`string`. Protocol syntax, protocol validation, authoritative-state policy, and
transport dispatch are coupled in the same implementation file. A message can be
added to one branch without being added to the complete protocol model, as shown
by the currently proposed `tx/reject` fix: the server message is part of the
deployed contract but the current decoder reports it as unsupported.

This structure makes the supported wire contract difficult to review and test.
It also prevents compiler exhaustiveness checks from identifying every sync state
transition affected by a new client or server message.

The repository previously had a private `Protocol` module with a broader server
message ADT. That module is no longer present. The authoritative message set and
field shapes for the replacement are the schemas and handlers in the checked-out
Logseq repository at `~/gh-repos/logseq/`, especially
`deps/db-sync/src/logseq/db_sync/malli_schema.cljs`. That source defines five
client messages (`hello`, `presence`, `pull`, `tx/batch`, and `ping`) and nine
server messages (`hello`, `online-users`, `presence`, `pull/ok`, `tx/batch/ok`,
`changed`, `tx/reject`, `pong`, and `error`). The current Journal client implements
only part of that contract and currently sends `t` instead of the canonical
optional `since` field in `pull`. The new module must replace that local divergence
rather than preserve it.

## Proposal

Add `logseq_sync/spec/sync_protocol.mli` as the single canonical OCaml contract
for application-level messages exchanged over the sync WebSocket. Add a matching
default implementation under `logseq_sync/lib/` and make it the only owner of
message JSON encoding and decoding.

The module should model direction explicitly:

```ocaml
type cursor = int
type checksum = string

type rejection_reason =
  | Stale
  | Db_transact_failed
  | Empty_tx_data
  | Invalid_tx
  | Invalid_t_before
  | Snapshot_upload_in_progress

type rejection =
  { reason : rejection_reason
  ; t : cursor option
  ; checksum : checksum option
  ; success_tx_ids : Logseq_db_types.Graph_types.Uuid.t list
  ; failed_tx_id : Logseq_db_types.Graph_types.Uuid.t option
  ; missing_block_uuids : Logseq_db_types.Graph_types.Uuid.t list
  ; error_detail : string option
  ; data : string option
  }

type user_presence =
  { user_id : string
  ; email : string option
  ; username : string option
  ; name : string option
  }

module Client : sig
  type transaction =
    { tx : string
    ; tx_id : Logseq_db_types.Graph_types.Uuid.t option
    ; outliner_op : string option
    }

  type message =
    | Hello of { client : string }
    | Presence of { editing_block_uuid : string option }
    | Pull of { since : cursor option }
    | Tx_batch of
        { client_revision : string option
        ; t_before : cursor
        ; txs : transaction list
        }
    | Ping
end

module Server : sig
  type pull_transaction =
    { t : cursor
    ; tx : string
    ; outliner_op : string option
    }

  type message =
    | Hello of
        { t : cursor
        ; checksum : checksum option
        }
    | Pull_ok of
        { t : cursor
        ; checksum : checksum option
        ; txs : pull_transaction list
        }
    | Changed of { t : cursor }
    | Tx_batch_ok of
        { t : cursor
        ; checksum : checksum option
        }
    | Tx_reject of rejection
    | Online_users of { online_users : user_presence list }
    | Presence of
        { user_id : string
        ; editing_block_uuid : string option
        }
    | Error of { message : string }
    | Pong
end

type direction = Client | Server

type error_kind =
  | Invalid_json
  | Expected_object
  | Missing_field of string
  | Unexpected_fields of string list
  | Unsupported_message_type of string
  | Invalid_field of { expected : string }
  | Limit_exceeded of { maximum : int }

type codec_error =
  { direction : direction
  ; message_type : string option
  ; path : string list
  ; kind : error_kind
  }

val encode_client_message
  :  Client.message
  -> (string, codec_error) result

val decode_server_message
  :  string
  -> (Server.message, codec_error) result

val decode_client_message
  :  string
  -> (Client.message, codec_error) result

val encode_server_message
  :  Server.message
  -> (string, codec_error) result

val error_to_string : codec_error -> string
```

This is a direction-setting interface sketch, not yet the final `.mli`. The final
contract should use documentation comments for every type and value and should
state the corresponding JSON discriminator and field names. It should use typed
UUIDs so malformed transaction identifiers cannot cross the decoder boundary.
The canonical Logseq wire schema makes `tx-id` optional even though Journal policy
can require every locally submitted transaction to have one.

Codec failures must retain direction, the decoded message discriminator when it
is safe and available, a JSON field path, and a stable error category. An
unexpected-field failure must name every unexpected field in deterministic order
and identify the containing object. Error values and rendered errors must never
include the rejected raw message, transaction contents, credentials, or another
field value that can contain graph data.

The selected message set is the complete application-level WebSocket contract in
the checked-out Logseq repository. It includes application-level `hello`,
`presence`, `ping`, and `pong`; these are distinct from WebSocket control frames.
It does not include HTTP pull, HTTP transaction submission, snapshot, asset, or
semantic API payloads. The canonical pull request uses optional `since`, with an
absent value interpreted by the server as zero. It does not use Journal's current
`t` request field.

The canonical top-level wire inventory is:

| Direction | `type` | Fields other than `type` |
| --- | --- | --- |
| Client | `hello` | required `client` string |
| Client | `presence` | optional nullable `editing-block-uuid` string |
| Client | `pull` | optional `since` integer |
| Client | `tx/batch` | optional `client-revision` string, required `t-before` integer, required `txs` array |
| Client | `ping` | none |
| Server | `hello` | required `t` integer, optional `checksum` string |
| Server | `online-users` | required `online-users` array |
| Server | `presence` | required `user-id` string, required nullable `editing-block-uuid` string |
| Server | `pull/ok` | required `t` integer, optional `checksum` string, required `txs` array |
| Server | `tx/batch/ok` | required `t` integer, optional `checksum` string |
| Server | `changed` | required `t` integer |
| Server | `tx/reject` | required `reason` plus the optional rejection fields below |
| Server | `pong` | none |
| Server | `error` | required `message` string |

A client `tx/batch.txs` element has required `tx` string, optional `tx-id` UUID,
and optional nullable `outliner-op` string. A server `pull/ok.txs` element has
required `t` integer and `tx` string plus optional nullable `outliner-op` string.
A `tx/reject` may contain `t`, `checksum`, `success-tx-ids`, `failed-tx-id`,
`missing-block-uuids`, `error-detail`, and `data`; the codec validates their
types and the selected reason-dependent combinations. `checksum` is included
because the current Logseq server handler emits it on a partially applied
`db transact failed` response even though the current Malli rejection schema
omits it.

`online-users` preserves its complete canonical payload. Each element contains a
required `user-id` string and optional nullable `email`, `username`, and `name`
strings. The separate server `presence` message contains required `user-id` and
required nullable `editing-block-uuid` fields. Decoding may map both an absent
optional nullable field and an explicit JSON `null` to `None` only where the
canonical schema marks the field optional; a required nullable field must still
be present on the wire.

The protocol module should own structural validation that is true for every
consumer:

- JSON shape and discriminator validation;
- exact allowed field sets for every top-level and nested object;
- non-negative cursors;
- the 16-character hexadecimal checksum shape;
- transaction field types and collection bounds;
- UUID parsing;
- reason-dependent `tx/reject` field validation; and
- explicit byte or scalar-value limits for server-controlled text.

Unknown fields are errors at every object level, including transaction entries,
presence entries, and rejection envelopes. The error must report the direction,
message type, containing JSON path, and unexpected field names without echoing
their values. Unknown message discriminators use the separate
`Unsupported_message_type` category.

The module should not own synchronization policy. Pull cursor continuity,
checksum comparison with local state, authoritative replay, outbox transitions,
terminal handling of `tx/reject`, reconnect behavior, and diagnostic presentation
remain in `Core` or the worker-owned persistence boundary. This separation allows
the same decoded `Tx_reject` value to be structurally valid while its terminal
product behavior remains governed by the dedicated rejection decision.

Journal-only submission requirements also remain policy. In particular, the
canonical schema permits an absent `tx-id` and an empty `txs` collection so that
the server can return its typed `empty tx data` rejection. Journal may require a
stable ID and a non-empty batch before sending, but the shared protocol codec must
still represent and symmetrically encode/decode the canonical wire shapes.

Refactor `Pure_core` as a functor over an abstract typed protocol adapter. The
instantiated public `Core` consumes `Sync_protocol.Server.message` and emits
`Sync_protocol.Client.message`; its adapter converts exhaustively to and from the
lower internal representation used by reducer policy. Remove `authoritative_message`,
`parse_authoritative_message`, `pull_payload`, and `submission_payload` rather
than retaining adapters or fallback decoders. Raw strings should exist only at
the transport codec boundary. No compatibility path should accept Journal's
non-canonical `pull.t` shape or another retired shape.

Put the codec implementation in `logseq_sync_pure_core`, for example as
`Sync_protocol_core`. `logseq_sync_impl` provides only this thin implementation
of the public `Sync_protocol` virtual module:

```ocaml
include Logseq_sync_pure_core.Sync_protocol_core
```

The public `logseq_sync/spec/sync_protocol.mli` is the source of truth and must
declare every public type independently. It must not refer to
`Logseq_sync_pure_core`, `Sync_protocol_core`, or another implementation module,
and the public spec library must not depend on the pure-core implementation
library. The thin implementation adds no validation or fallback behavior, while
the `Core` implementation owns exhaustive typed conversions across the nominal
public/internal boundary. This layout preserves the pure-core compile-time
boundary and avoids a library dependency cycle without making the public spec
depend on its implementation.

The public surface should be tested at `Logseq_sync.Sync_protocol`, while reducer
tests should construct typed messages instead of duplicating JSON fixtures except
where codec behavior itself is under test. Both codec directions should be public
and tested. Protocol codec tests should cover one canonical wire example per
constructor, bidirectional round trips, ordering preservation, bounds, malformed
fields, unexpected fields at every nesting level, unsupported discriminators,
and the complete `tx/reject` matrix.

## Decision

Make `Logseq_sync.Sync_protocol` an installed public virtual module. Define the
complete current application-level WebSocket message set from the checked-out
Logseq repository, rather than limiting the client ADT to the two messages the
Journal reducer currently sends. The client ADT therefore contains `hello`,
`presence`, `pull`, `tx/batch`, and `ping`; the server ADT contains `hello`,
`online-users`, `presence`, `pull/ok`, `tx/batch/ok`, `changed`, `tx/reject`,
`pong`, and `error`.

Expose all four directional codec operations: client encode, client decode,
server encode, and server decode. Reject every unexpected field at every object
level. Return a structured error that identifies direction, safe message type,
JSON path, and unexpected field names without including their values or the raw
payload.

Preserve the complete `online-users` payload using the canonical `user-id`,
`email`, `username`, and `name` schema. Also model the separate bidirectional
presence flow: the client sends nullable `editing-block-uuid`, and the server
broadcasts `user-id` plus nullable `editing-block-uuid`.

Declare the public ADT directly in `logseq_sync/spec/sync_protocol.mli`, with no
reference to its implementation. Keep the codec implementation in
`Logseq_sync_pure_core.Sync_protocol_core`, and keep the default public
virtual-module implementation as only:

```ocaml
include Logseq_sync_pure_core.Sync_protocol_core
```

Because the public interface intentionally hides the lower module's nominal type
identity, instantiate `Pure_core` with an adapter that exhaustively converts
public server messages to the reducer representation and reducer-produced client
messages to the public representation. The adapter performs no serialization,
fallback decoding, or unsafe cast.

This decision intentionally replaces Journal's current partial and divergent
wire implementation. It does not retain aliases, fallback decoders, or legacy
message shapes.

## Alternatives considered

### Keep protocol types private inside `Pure_core`

This avoids a new public module but leaves wire syntax and synchronization policy
under the same owner. It also provides no canonical client-message ADT and does
not meet the requested `spec/sync_protocol.mli` boundary.

### Restore the retired private `Protocol` module

The removed module already modeled most server messages and rejection reasons,
but it encoded obsolete client behavior and was not the public canonical spec.
Restoring it would preserve stale protocol variants and allow the public spec and
implementation to drift.

### Define one undirected `message` type

A single sum type is shorter, but permits the client to encode server-only
messages and makes direction-specific exhaustiveness less clear. Separate
`Client.message` and `Server.message` types express protocol authority in the
type system and allow both directions to reuse wire constructor names such as
`Hello` and `Presence` without constructor-name collisions.

### Expose raw `Yojson.Safe.t` payloads in the ADT

This preserves unknown server data, but moves schema ambiguity across the
protocol boundary. The canonical `online-users` and `presence` schemas provide
the required typed representation; raw JSON should not become a general
extension mechanism.

### Keep the codecs client-directional

Publishing only `encode_client_message` and `decode_server_message` would be
sufficient for the production client. It is not selected because symmetric
codecs make the declared client-to-server and server-to-client formats executable
in both directions and allow fake servers and fixtures to use the same canonical
contract.

## Acceptance criteria

- `logseq_sync/spec/sync_protocol.mli` is the only hand-written public definition
  of the client and server message ADTs. It contains no reference to
  `Logseq_sync_pure_core`, `Sync_protocol_core`, or another implementation module.
- The public `logseq_sync` spec library does not depend on
  `logseq_sync.impl.pure_core`.
- The installed package exposes `Logseq_sync.Sync_protocol`, and its default
  implementation is only an include of
  `Logseq_sync_pure_core.Sync_protocol_core`.
- `Client.message` contains exactly the five canonical Logseq client messages,
  and `Server.message` contains exactly the nine canonical Logseq server
  messages.
- Every selected client message is encoded from `Client.message`; `Core` no
  longer assembles protocol JSON.
- Every selected server message is decoded to `Server.message` before sync policy
  handles it; `Core` no longer branches on JSON discriminators or sentinel parser
  error strings.
- The `Core` implementation converts between public and reducer protocol values
  with exhaustive typed pattern matches, without JSON round trips or unsafe casts.
- All four public codec operations share the same ADTs and validation rules and
  pass bidirectional round-trip tests.
- The selected wire keys are documented and fixture-tested, including canonical
  optional `pull.since`, optional `client-revision`, optional `tx-id`, nullable
  `outliner-op`, checksum absence, presence fields, and all valid `tx/reject`
  shapes including the server-emitted optional rejection checksum.
- `online-users` preserves the required `user-id` and optional nullable `email`,
  `username`, and `name` fields for every element.
- Protocol validation rejects negative cursors, malformed checksums, invalid
  UUIDs, invalid reason-dependent rejection fields, oversized text, unsupported
  message discriminators, and unexpected fields at every object level. The codec
  still represents canonical empty batches and absent transaction IDs; Journal
  submission policy rejects those before sending.
- Every unexpected-field error reports direction, message type, containing JSON
  path, and deterministically ordered field names without reporting field values
  or raw payloads.
- Cursor continuity, local checksum comparison, replay, persistence, retry or
  terminal rejection policy, and UI diagnostics remain outside `Sync_protocol`.
- The retired private protocol implementation and raw JSON helpers are removed;
  no compatibility decoder accepts Journal's current `pull.t` shape or another
  retired shape.
- Public contract tests, focused sync tests, the complete repository test suite,
  `git diff --check`, and `spec-dev-tool check --all` pass.

## Implementation evidence

- `logseq_sync/spec/sync_protocol.mli` defines the installed public ADTs,
  structured codec errors, and all four codec operations directly, without an
  implementation-module reference.
- `logseq_sync/lib/sync_protocol_core.ml` owns the lower protocol representation
  and strict JSON implementation. `logseq_sync/lib/sync_protocol.ml` contains only
  `include Logseq_sync_pure_core.Sync_protocol_core`.
- `logseq_sync/lib/pure_core.ml` exposes `Make`, parameterized by abstract public
  client, server, and codec-error types. `logseq_sync/lib/core.ml` instantiates it
  with exhaustive public/internal conversions. `logseq_sync/lib/effect_runner.ml`
  owns the remaining raw inbound decode and outbound encode boundary.
- `logseq_sync/test/sync_protocol_contract.ml` exercises every client and server
  constructor, symmetric round trips, all rejection reasons, canonical pull
  syntax, strict nested fields, safe diagnostics, malformed values, and bounds.
  `logseq_sync/test/core_contract.ml` verifies typed server events reach policy
  without raw JSON parsing.
- `test/source_boundary_test.ml` enforces the standalone public type declarations,
  absence of spec-to-implementation references and dependencies, virtual-module
  layout, exact thin include, typed Core boundary, installed module, and removal
  of obsolete raw protocol helpers and sentinel paths.
- `dune runtest`, `dune build @all`, `ocamlformat --check` for the touched OCaml
  sources, `git diff --check`, the install-manifest audit, and
  `spec-dev-tool check --all` pass.

## Consequences

`Logseq_sync.Sync_protocol` is now the installed, exhaustive application-level
WebSocket contract. Client and server code can share the same public ADTs and
four symmetric codecs. The public interface is self-contained and has no
dependency on the lower implementation library.

`Pure_core` remains independently compilable by accepting abstract protocol
types through a functor. The `Core` implementation performs exhaustive typed
conversion at instantiation time, so public variants remain authoritative while
lower policy code can reuse the pure codec representation. A protocol constructor
change now produces compile failures in the public implementation and adapter
until both are updated.

Raw protocol JSON is confined to `Effect_runner`: inbound frames are decoded
before becoming `Core` events, and outbound typed messages are encoded immediately
before transport submission. Adding or changing a protocol message therefore
requires an explicit public type and codec update, and compiler exhaustiveness
checks identify affected policy branches.

Strict field validation makes an uncoordinated additive server rollout a visible
protocol error instead of silently discarding data. Diagnostics identify the
direction, discriminator, path, and field names needed to investigate the
failure, but never retain or render the rejected payload or field values.

The Journal client now sends canonical `pull.since` requests. The former
`pull.t` shape, private authoritative-message decoder, raw payload constructors,
and sentinel parser result are removed with no compatibility path.

## Risks

- The current reducer consumes raw frames and delegates authoritative inspection.
  Moving decoding to a typed boundary can accidentally change generation fencing
  or the ordering of delegated work if the event flow is refactored at the same
  time.
- Publishing concrete variants makes additions to the server protocol a public
  OCaml API change. That is desirable for exhaustiveness but increases the cost
  of accepting experimental server messages.
- Strict field validation intentionally rejects additive fields introduced by
  the server until the public ADT and codec are updated together. A server rollout
  that adds fields without coordinating the client will become a visible protocol
  failure.
- `tx` and rejection `data` remain strings because Transit payload semantics and
  display-safe diagnostics belong to later boundaries. Their size limits must be
  explicit so the ADT does not legitimize unbounded server-controlled values.
- The thin public include and `spec/sync_protocol.mli` can drift structurally if
  the build does not compile the include against the virtual interface in every
  supported target. Contract and install-manifest tests must enforce this layer.
- The nominal public/internal split requires explicit conversion functions in
  `core.ml`. Their exhaustive matches deliberately turn protocol additions into
  compile-time work rather than silently accepting an incomplete mapping.
- The canonical Logseq schema permits an absent `tx-id`, while Journal's durable
  outbox requires stable transaction identity. The protocol ADT must represent
  the optional wire field, and Journal policy must reject omission before it
  creates or submits a local durable batch.

## Questions

- None. The user selected the public module, complete Logseq-repository message
  set, symmetric codecs, strict unknown-field rejection with structured safe
  errors, complete typed presence payloads, a standalone public `.mli` as the
  source of truth, and a thin public virtual-module implementation over the lower
  pure codec.
