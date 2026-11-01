# App boundary target contracts

`logseq_journal.app_spec` is a compiled Dune virtual library, following the
interface-only structure in `logseq_sync/spec`. It has **no default implementation**.
The current `app` and Worker service do not implement/link this target contract.
This PR does not migrate runtime code, fix the Capture failure, or include the
separate Force Delete implementation.

`Core` covers Worker request/observation/session/result coordination only. Its view
is not the entire App model: navigation, Timeline/feed planning, Favorites, media,
Capture editing and other business/UI state remain with their current owners.

The eventual `app/impl/effect_runner.ml` connects directly to the existing typed
`Journal_worker` client and `Logseq_db_worker_lui_service`. There is no extra
worker_adapter directory, generic WORKER module, or dependencies factory. Application
owns the shared client, pump and event delivery and forwards actual envelopes to
`Effect_runner.on_event`; the runner does not install an unremovable second handler
or stop the client on shutdown. It uses existing runtime epoch/worker generation
and Accepted mailbox IDs for lifetime checks and cancellation.

`Worker_api` owns sealed sessions, separate generation types, immutable intents,
read-only page/block accessors and validating `ISSUER` mapping. Requests/responses
use the actual in-process Service/Protocol OCaml types, not an invented bytes
transport. Only durable intent persistence retains a bytes encoding. Runtime
identity, authorization, receipt evidence, revocation and resource quiescence
remain checks; types alone cannot prove them. Existing structured Error.t values
are preserved when available; a code/message-only protocol failure cannot recover
an already lost trace.

## Review findings and runtime gaps

| Finding | Contract | Existing implementation still to migrate |
| --- | --- | --- |
| Capture reads up to 200 full children before insertion, which can exceed encoded-byte limits | Atomic `Append`, durable intent and bounded reads | Current Service has separate create-page/insert operations. Until backend transaction/outbox/idempotent receipt semantics exist, return Unsupported_request before enqueue; wrapping those calls is not atomic. Preserve the final encoded-byte check from `a9df8c5`. |
| Scoped and implicit-current APIs coexist; generations can be mixed | Sealed session, distinct generations, concrete mailbox lifetime | Existing dispatch still fills current scopes. Future runner maps only to scoped requests and fences old mailbox generations; preserve `1d61aeb` recovery behavior. |
| Request/results and receipts can be mismatched, and opaque results were unusable | GADT requests/tickets, real Service reply validation, page/block UUID/title accessors | No runtime implementation exists yet. Positive clients now consume Journal page identity, request Children, render block identity/content and consume observations, including empty/error/refusal branches. |
| Cancellation/presentation failure obscure commits | Not_admitted, Unsupported_request, Interrupted, mutation_progress and durable intents | Existing Worker outcomes remain unchanged. Use Accepted mailbox IDs for cooperative cancel, never infer rollback. Preserve stable status intent IDs (`69146ff`) and target confirmation (`6eceac6`, `c8a8cae`). |
| Independent membership/state pushes and equality can hide progress | Versioned projection, selection/deletion consistency, Core.equal_view | Service.state and separate/coalesced Graph_states lack an atomic versioned baseline. A Worker-owned sample/registration or version replay handshake is required; otherwise return Unsupported_operation and no fabricated ready state. Preserve focus repair `089b2b2`; last-graph/local_deletion transitions remain requirements. |
| Query and observation ownership/epochs are coupled | Query/Observe/Refresh/Release, typed results/unit ACK and Drain | Current Service does not offer the target observation registration/epoch/ACK protocol. Ordinary reads plus unsequenced pushes are insufficient. Reject unsupported operations explicitly; preserve empty-page `d135571` and invalidation-owned epoch `ad2b7ce`. |

The target covers these six issues, not every current Worker command. Append and
lossless observation/projection are explicit backend migration gaps, not claims
about today's Service. Ordinary Delete keeps its product rules. Force Delete
requires confirmation, trustworthy resource ownership and truthful partial cleanup;
no spec authorizes deleting real user data. Revocation allows only tracked cleanup
and terminal ACKs, never new data operations or resurrection of a removed session.

## Checks

`dune build @app/spec/all` compiles the interfaces without linking an implementation.
`dune build @test/app-spec-contracts` runs sealed-client compilation checks,
including complete one-shot/observed Journal-to-Children rendering clients and
rejection/error branches. The same rule belongs to workspace `dune runtest`.
These checks prove interface usability/type constraints, not runtime behavior,
backend atomicity, lossless registration or Simulator/device acceptance.
