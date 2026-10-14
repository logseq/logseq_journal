# Open external OCaml JSON inputs and keep owned contracts closed

## Problem

A real Journal sync error rejects pull/ok.txs[0].tx-id before transactions are applied. Both the generated server DTO and the structural whitelist reject external response extensions. External services can add fields Journal does not consume without changing required fields.

## Decision

Limit this PR to OCaml JSON codecs, as explicitly requested by the user. Keep PPX. External WS and E2EE HTTP records use separate input-only open readers, including nested records; declared required fields, types, nullability, supported variants, semantics and size budgets remain validated. Unused pull tx-id is ignored. Owned client/output DTOs remain closed, and existing internal Config/Protocol/full persistence admission stays closed. Catalog and snapshot metadata retain open input behavior with decode-only derivations. Outbox metadata readers remain decode-only projections rather than full-record admission.

All Swift codec behavior and its compiler/test/CI configuration are restored exactly to the PR's merge-base. The generic Swift decoder, native call-site replacements, native boundary tests and offline provider compile mode are outside the narrowed scope.

The user additionally approved the smallest test-only correction for the existing CI failure in Application's retained root feedback checks. The fixture's global title lookup can select Detail's same-title node instead of the root node. Add an optional identity predicate to that test helper and restrict root-content observations to the root navigation owner; retain the original layout and node identity assertions. This does not change production UI behavior.

## Alternatives considered

### Declare only tx-id

Would still reject the next external extension. The user requested open external input schemas.

### Make shared input/output DTOs open

Would spread external tolerance into owned contracts. Keep separate input-only readers and closed output DTOs.

### Add strict Swift receiving infrastructure

Not part of the narrowed OCaml scope. Generated Encodable/PPX writers already emit their declared fields; strict receiving is a separate defensive policy. Restore Swift and dependent wiring to their prior behavior.

## Consequences

Open object validation checks declared fields and duplicate safety without applying the owned-field whitelist. Output uses the original generated closed DTOs and readers with semantic/budget validation. Internal full-record codecs stay closed; projections do not expose encoders. All Dune/spec/Swift/CI files have no net changes relative to the merge-base. No UI changes, real account/graph writes, new diagnostics, merge or phone installation belong to this PR.

## Validation and coverage

Tests were written first. Against unchanged main953, public WS extension/declared-control tests failed, and public Runner/local TLS HTTP tests failed four extension-acceptance assertions; required/type/null/duplicate controls passed. Core metadata and internal Config controls passed at baseline. These are synthetic regression payloads, not live service compatibility claims.

| Boundary | Actual evidence | Public regression boundary |
| --- | --- | --- |
| WS server/client | Materialized and viewed screenshot establishes pull/ok.txs[0].tx-id rejection; payload and deployed SHA unknown | Sync_protocol: all supported variants and rejection reasons, root/nested extras, ignored tx-id shapes, required/type/null/semantic/variant failures, closed client/output and limits |
| Catalog/E2EE HTTP | Prior authorized type-only App logs show catalog/user-key HTTP 200 and graph-key behavior before/after PR72; no fresh signed-in payload collection | Runner with independent localhost TLS peer and generated readers |
| Snapshot metadata/baseline | Upstream schema, no live signed-in response | Core raw completions preserve required/type/null/HTTPS URL checks |
| Internal/outbound | No real account record accessed | Config rejects root/nested extras; existing Protocol and persistence suites retain closed full admission; generated client/server output round trips |
| Transit/snapshot/assets | No new live graph/asset samples | Existing envelope/size/transaction/snapshot/asset regressions; formats unchanged |

Frozen upstream dev 949a4f0e72cddb2dad34091393bfa09592171944 declares optional non-null UUID tx-id in server entries; old 015cc9f does not declare that server field. Both use open Malli maps. This source evidence does not establish the screenshot value/type or deployment revision: [frozen schema](https://github.com/logseq/logseq/blob/949a4f0e72cddb2dad34091393bfa09592171944/deps/db-sync/src/logseq/db_sync/malli_schema.cljs#L10). Journal does not consume tx-id.

After scope removal, rerun the OCaml build/native embed and regression suite, review the exact new head in the existing independent Codex session using journal-code-review, and track its CI to success. Prior Swift-inclusive review/CI snapshots are superseded. spec-dev-tool check --all has three preexisting invalid historical decisions unrelated to this change.

The unchanged root-feedback assertion was reproduced on both 953d4a7 and 9293bad by randomizing only the test observer table's hash order. The root body has one stack candidate; both snapshots preserve root content node 180, while the global title lookup may select Detail node 259. The candidate correction passes the two fixed public Application cases in five randomized runs per snapshot (20 case executions). All original containment and node identity comparisons remain. Diagnostic mirrors and logs stay outside the repository.
