# App boundary target contracts

`logseq_journal.app_spec` is a compiled Dune virtual library, following the
interface-only structure in `logseq_sync/spec`. It deliberately has **no default
implementation**. The current `app` library and Worker service do not implement or
link this target contract. This change specifies a later migration; it does not
fix the observed Capture failure or change existing deletion/ownership policies.

The public modules are `Worker_api` (typed boundary values and operations), `Core`
(pure request, observation and view owner), and `Effect_runner` (trusted Worker
adapter/interpreter obligations). No fake implementation or adapter is included.
Generations, sessions, tickets, receipts and observation handles are abstract;
queries and replies retain their result type. `Worker_api.issuer` is the explicit
trusted integration factory: the runner binds its validating `ISSUER` to the real
Worker/account connection. This factory is not authentication or permission to
construct a fake authorized backend. Typed query/observation getters expose results
to rendering; unit tickets acknowledge release and `Schedule_drain` drives bounded
continuations. The issuer validates/encodes outbound requests and cancellations as
well as inbound replies. Revocation permits only tracked cleanup and terminal ACKs,
never new reads/writes or session resurrection. Runtime equality, authorization,
revocation, durable commit and resource quiescence still require validation.

## Review findings and runtime gaps

| Finding | Contract | Existing implementation still to migrate |
| --- | --- | --- |
| Capture reads up to 200 full children before insertion, which can exceed encoded-byte limits | `Worker_api.Append`, immutable `append_intent`, bounded read queries | `journal_graph_runtime.ml` still calls `capture_children` before insertion. The new atomic append and receipt adapter do not exist. Preserve the final read budget check introduced in `a9df8c5`. |
| Scoped and implicit-current APIs coexist; generations can be mixed | Abstract `session`, separate generation types, Worker-issued projection/presentation | `Application.dispatch_worker` still fills a current scope, Service still exposes both request forms, and existing Sync scopes are public records. Execution sessions and presentation remain distinct; see `1d61aeb`. |
| Request/result pairing and receipt identity are runtime-only | GADT `request`, typed Core tickets/completions, `ISSUER.reply`/`receipt`/`confirmation` | Existing independent command/outcome variants and request tables remain. The adapter must validate value-level IDs as well as type-level result kind. |
| Cancellation and presentation failures obscure whether a write committed | `Not_admitted`, `Interrupted`, `mutation_progress`, durable intent encoding/recovery | Existing Worker outcome/failure routing is unchanged. Preserve the stable status intent identity fixed in `69146ff` and target confirmation ownership extracted in `6eceac6`; do not equate Timeline membership with commit, as `c8a8cae` demonstrated. |
| Separate membership/state publications and hand-written equality can hide progress | One immutable versioned `projection`, selected presentation/residents/deletion, `Core.equal_view` | Existing pushes and equality are unchanged by this PR. Preserve focus repair from `089b2b2`; comparison of `local_deletion` and the final-graph transition are requirements here. The separate Force Delete implementation is not included. |
| Querying and observation retention/epochs are implicit side effects | Separate `Query`, `Observe`, `Refresh`, `Release`, abstract handle/epoch | Existing App interest tables remain. Preserve the empty-page fix in `d135571` and invalidation-owned reconciliation epoch in `ad2b7ce`. |

The contracts model these six boundary issues, not every existing UI feature.
They intentionally do not expose Sync/Overlay implementation records or DB
handles to App clients. Ordinary Delete keeps its current/resident/auth/catalog
rules. Force Delete still requires fresh destructive confirmation and trustworthy
resource ownership; no signature authorizes deleting real user data.

## Checks

`dune build @app/spec/all` compiles the virtual interfaces without linking a runtime
implementation. `dune build @test/app-spec-contracts` runs sealed-client
positive/negative compilation via `test/app_spec_contract_test.py`; these checks
do not bypass the `.mli` files and do not claim runtime or Simulator acceptance.
The same rule is included in the existing workspace `dune runtest` alias.
