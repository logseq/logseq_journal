# Open external JSON inputs and close owned JSON contracts

## Problem

A real Journal sync error rejects the extra tx-id field on pull/ok.txs[0] before any transaction is applied. The generated server DTO and manual structural whitelist both reject it. External services can extend responses without changing the fields Journal consumes. Shared input/output DTOs also obscure which side owns a schema; synthesized Swift internal decoders currently tolerate unknown fields.

## Decision

Follow the user-approved boundary policy. External server/HTTP JSON input DTOs derive open PPX readers, including nested records; validate declared required fields, their types and domain semantics. Continue rejecting unsupported message variants and malformed JSON. Ignore unused pull tx-id regardless of its value. Keep generated closed output DTOs separate, with semantic and wire budget checks; client wire validation remains closed. Internal OCaml commands, outcomes and persistence domain codecs remain closed. Swift-owned internal/native receivers use a recursive Decoder wrapper that rejects keys absent from synthesized CodingKeys; external Cognito and Transit readers do not use it. Keep generated Codable/PPX construction, existing keys and formats.

The existing metadata-only outbox/format readers are projections of a complete record, not full-record admission or constructors; make decode-only derivations explicit where applicable. Their extra declared owner fields must not be rejected as projection extras. The domain owner remains responsible for the full closed contract.

## Alternatives considered

### Declare only tx-id

Rejected because the user explicitly authorized open external inputs, including nested future fields. Adding a whitelist entry would leave the same failure for the next external extension.

### Make all shared DTOs open

Rejected because it would extend open semantics to internal receivers and weaken validation of owned output. Use separate external-input and closed-output DTOs.

## Acceptance criteria

- Public Sync_protocol API accepts top-level and nested server extensions while preserving required/type/null/semantic, cursor/budget and discriminator failures; all client input remains closed and generated outbound shapes contain only contract fields.
- Public Runner requests exercise open HTTP catalog/E2EE inputs through the existing isolated TLS peer. Core public completions retain snapshot metadata field/URL validation.
- Native public wire and closed-decoder utility tests reject root/nested/array extras, retain required/type/null/default behavior and leave external Cognito decode open.
- Tests are written before implementation and demonstrably RED for the old behavior, then GREEN. Existing targeted regressions and appropriate broader checks pass.
- No Dune/spec files, UI PR73 checkout, user graph, credentials, phone installation or temporary diagnostic observer is changed.
- Create a formal PR, freeze head SHA, wait for that exact head CI terminal results, then request independent journal-code-review. Do not merge.

## Risks

- Open schemas still enforce standard JSON safety and declared semantic constraints; unknown event types are not extension fields.
- Swift native receiver fields must match the complete OCaml producer contract. Nested checking must preserve optional nulls, arrays and dynamic dictionaries rather than guess field lists.
- Public Core receives already-decoded WS messages and HTTP key values, so it cannot reproduce raw field rejection. The narrowest raw WS boundary is public Sync_protocol; HTTP raw parsing belongs to the public Runner and its transport peer. Do not inject an already incorrect parsed result into a reducer as a reproduction.
- Existing live evidence covers the reported WS extra-field rejection and historical catalog/E2EE paths, plus a public JWKS read. Synthetic tests are not live service validation; actual signed-in response variants remain unobserved.

## Questions

- None. The user expressly authorized this policy change and a separate formal PR; any necessary Dune/spec edit would require a separate minimal-diff request.

## Consequences

WS server records now have separate input-only open PPX DTOs. The discriminator remains owned by its header reader and semantic validator. Open object validation checks declared values and duplicate safety without running the owned-field whitelist. Output uses the original closed DTO serializers and generated closed readers, plus existing semantic and size validation. HTTP E2EE inputs are open; catalog and snapshot metadata retain their already-open behavior but expose no encoders. Internal Config/Protocol/full persistence codecs stay closed. Decode-only outbox indexing and account-format projections remain explicitly separate from full-record admission.

Swift native wire, extension properties, persisted token/binding/recovery records and the crypto bridge use the closed recursive Decoder. It derives allowed keys from each Decodable container's synthesized CodingKeys, including nested arrays/enums; dynamic dictionaries keep their intentional key space. Foundation's Data/Date/URL/Decimal decoding is preserved. External OAuth/JWT/JWKS/Transit readers keep their existing open behavior. Unknown-field diagnostics omit unknown names and values.

The user explicitly approved the one-line JournalInternalJSON.swift dependency in the existing wrapped-key crypto Dune rule. It is the only Dune change; all OCaml spec files remain untouched.

## Validation and actual-data coverage

Tests were added first. With production at main953, the public WS codec failed its two new extension/declared-constraint tests, native wire/binding plus recursive utility behavior failed five extension assertions, and the public Runner/local TLS peer failed four E2EE extension-acceptance assertions. Existing required/type/null/duplicate controls passed. The Core metadata and internal Config controls passed at baseline. These fixtures are synthetic, including the independent local TLS peer and signed Cognito issuer.

| Boundary | Real evidence | Regression coverage |
| --- | --- | --- |
| WS server/client | Materialized and viewed error screenshot proves pull/ok.txs[0].tx-id rejection; full payload and deployed SHA unknown | All supported server variants/rejection reasons, top/nested extensions, ignored tx-id shapes, required/type/null/semantic/variant errors, closed client/output and wire limits |
| Catalog and E2EE HTTP | Earlier authorized App type-only logs: catalog/user keys HTTP 200; graph key before/after PR72; no new signed-in response collection | Public Runner with independent localhost TLS peer, valid extensions and invalid consumed fields |
| Cognito OAuth/JWT/JWKS | Public JWKS read returned 200, two RSA keys and decoded through the existing Swift reader; no tokens recorded | Existing production owner with synthetic signed issuer; open response and authentication failure controls |
| Snapshot metadata/baseline | Upstream schema only; no live signed-in response | Public Core raw completions verify extension tolerance, required/type/null and HTTPS URL constraints |
| Transit sync/snapshot/assets | No new live graph/asset samples | Existing envelope/size/transaction/snapshot/asset regression suites; no format changes |
| Owned native/persistence/output | OCaml producer emitted real generated bytes to the Swift public receiver in an isolated harness; no real account store accessed | Native wire round trip, nested closed decoder, optional/dictionary behavior and account recovery; existing OCaml closed persistence tests |

Current upstream dev `949a4f0e72cddb2dad34091393bfa09592171944` declares optional non-null UUID tx-id on server tx-log entries; old `015cc9f` does not declare that server field. Both use open Malli maps. This is source evidence, not the screenshot field's observed type or deployed revision: [frozen dev schema](https://github.com/logseq/logseq/blob/949a4f0e72cddb2dad34091393bfa09592171944/deps/db-sync/src/logseq/db_sync/malli_schema.cljs#L10). Journal does not consume tx-id, so its external input reader ignores it.

The complete build (`@all` and native embed), full regression recheck (259 sync cases), 10 native JSON boundary assertions, account/recovery/event and synthetic signed-Cognito suites, public OCaml-to-Swift wire round trip and production iOS SwiftUI typecheck passed. The initial concurrent full run exposed one existing 20ms/30ms RFC Pong timing failure; both original and restored protocol single-case checks then passed, followed by the full regression recheck. No transport timing or production transport code was changed. The document passes spec-dev-tool; check --all reports three unchanged preexisting invalid historical decisions.

A preliminary independent read-only review of the uncommitted diff using journal-code-review found no evidenced P1/P2. It does not replace the independent Codex session review of the formal PR snapshot.

The formal independent Codex review of head 3511e42 found one P2: the deployed E2E provider compiler still passed only JournalE2EECrypto.swift. Its actual compiler function now includes JournalInternalJSON.swift. A compile-only public executable mode stops before provider loading, environment/credential reading, Keychain creation or networking; this mode reproduced the missing-type compiler error (exit 2) and passed after the source-list fix (exit 0). CI runs this offline compiler regression after building targets. No online E2E was executed.
