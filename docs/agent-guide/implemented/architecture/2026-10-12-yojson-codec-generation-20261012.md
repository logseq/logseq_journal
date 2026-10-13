# Generate repository JSON codecs with Yojson PPX

## Problem

The worker protocol and other OCaml JSON domain codecs construct and inspect JSON objects manually. This duplicates type definitions and complicates validation and format changes.

## Proposal

Use the existing ppx_deriving_yojson 3.10.0 generator for all OCaml type codecs. Internal request, response, push and persisted formats use generated representations with no legacy compatibility. Keep domain validation after generated decoding, including UUID normalization, cursor length, asset constructors, scope variants, cardinality and byte/count bounds. Measure the existing 256 KiB budgets against the actual new encoding.

Preserve external server and DataScript contracts using generated DTOs with key/default attributes and domain conversions. Generic JSON AST traversal, Transit containers and non-OCaml Swift/JS/Python codecs are separate technical boundaries. Coordinate Swift native bridge consumers when changing OCaml native bridge payloads; preserve native bridge field contracts unless explicitly changing both sides.

Initial owner inventory at main 061595439401702d5a116f6d51455482d5b363f7 (25 production OCaml files, plus 6 tool files, 3 typed Apple test fixtures/probes and generated audit report code):

- Worker: contract/protocol.ml (68 codec/scalar helper declarations), config.ml (4), error.ml (6), effect_runner/effect_runner.ml (JWT exp decoder).
- Sync: 6 production files, including sync_protocol, core, catalog, e2ee, platform_crypto and bootstrap.
- Storage/overlay: 7 production files, 11 codec groups; 27 existing derivations still contain manual variant dispatch and scalar helpers.
- App: 8 typed native JSON producer/decoder files. journal_startup already delegates to Config. Swift JournalStartupConfiguration still constructs the old Config wire and must be updated with the internal protocol. Native crypto key-management request/response DTOs need coordinated OCaml and Swift changes; external Transit ciphertext stays stable.
- Overlay tools: 6 OCaml files and 4 Python audit scripts which generate OCaml JSON report code.

Internal persisted outbox mutations, terminal receipts and asset upload intents contain irrebuildable operation identity/account/origin/graph/staged-file state. Old formats must fail explicitly as unsupported; do not silently discard or reset actual user data. Change garbage-collection receipt classification to use generated decoding rather than peeking at old acceptedBatch JSON and ignoring malformed receipts.

The user explicitly authorized the eight Dune files, graph_types.mli and asset_descriptor.mli, dune-project and five package manifests, and explicit old-internal-format rejection paths on 2026-10-12. Implementation starts from merged main b2c32aa including PR 66. Worktree: codex/yojson-codecs-20261012 under the current task directory. Do not modify another checkout or shared pins/switch. Parallel feed work owns app/journal_graph_runtime.ml and its tests.

## Decision

Generate OCaml typed JSON codecs with the existing Yojson PPX. Internal wire and persisted formats use the generated representations without legacy fallback; external contracts use generated DTOs. Preserve validated constructors, generic JSON safety checks and actual encoded byte budgets. The approved lockfile additions use existing resolved versions.

## Alternatives considered

### Keep old internal wire through hand-written DTO mapping

Rejected by the user: generated formats take precedence and legacy internal formats are intentionally unsupported. DTO conversion remains appropriate only for external/native contracts and validated private domain types.

### Derive through abstract/private types without validation

Rejected because it would bypass Uuid.of_string, Cursor.of_string, asset version/create, error safety validation and existing bounds.

## Acceptance criteria

- All actual OCaml typed JSON codecs use generated encoders/decoders; remaining generic AST or Transit operations are explicitly classified.
- Generated roundtrip tests cover all request/outcome/push constructors, int/int64 limits, options, errors, UUID/cursor/asset/scope validation, duplicate fields and actual byte boundaries.
- Old internal protocol/persistence fixtures are rejected. No internal compatibility fallback remains.
- External server and DataScript fixtures retain their contracts.
- Direct App/worker/native callers, persisted outbox/asset intents and tools run with new codecs.
- Full dune build @all app/native_embed.exe.o and dune runtest --force pass. The new decision passes spec-dev-tool check; any pre-existing check --all failures are recorded against the baseline.
- Isolated synthetic Simulator product chain runs after coordination; no real graph/account purge or phone installation.
- Formal non-draft PR is pushed, exact head CI reaches terminal status, SHA is frozen and reported for independent journal-code-review session. No merge.

## Risks

- Generated record decoders do not reject duplicate field names by default. The shared Json_codec AST validator rejects duplicate names, invalid UTF-8 and nonstandard JSON; its Result boundary catches numeric conversion failures. External sync retains its generic shape validation for precise indexed diagnostics.
- Generated int64 uses JSON integers/Intlit rather than the old internal string form. Verify bounds and external numeric-cursor safe integer rules.
- Sync codec_error.path retains precise indexed diagnostics through generic shape validation; sync_protocol.mli is unchanged.
- Asset cache creation now validates every manifest before any cleanup. Old or invalid formats return a visible error with their bytes and associated files retained.
- Old irrebuildable internal persisted content becomes unsupported; code migration authorization does not authorize destructive deletion on any user's device.

## Implementation and validation

The worker protocol derives its actual request/response/push declarations. Graph_types owns generated nested codecs and validated UUID/cursor adapters. Asset_descriptor validates generated input through version/create. Error and Config preserve their safety and constructor boundaries after generated decoding.

Storage/overlay use outbox format 17 and receipt format 2; upload checkpoints and asset cursors use generated records and variants. Reopen and garbage collection validate irrebuildable receipts and fail explicitly on old/invalid JSON. Existing SQL layout support is separate from JSON format compatibility.

External HTTP/WebSocket codecs use generated wire DTOs and keep existing keys, omissions, numeric cursor ranges and rejection constraints. Swift native counterpart codecs use synthesized Codable/Decodable; external JWT/OAuth fields and Transit ciphertext remain stable. Typed tool reports, fixture generators and generated audit instrumentation also use PPX.

Remaining AST operations are generic duplicate/UTF-8/sync-shape validation, the external Transit reader, arbitrary LUI primitive maps, and dynamic metric-map normalization. They do not decode domain records.

Targeted RED/GREEN checks cover 20 request constructors, 15 outcome constructors, both push constructors, all property/internal variants, int64 extremes/overflow, constructor invariants, duplicate fields and exact 1 MiB request/256 KiB response/64 KiB push/32 KiB error budgets. Direct Worker/Lui/App callers, upload/outbox storage, actual localhost TLS/HTTP/WebSocket, Swift crypto/platform wire and small synthetic tool audits pass. Full build @all plus native_embed object and full dune runtest --force pass (705 Alcotest cases plus existing custom suites). The source-boundary check scans original source files and excludes generated .pp.ml/.pp.mli artifacts; actual production access restrictions remain enforced.

The baseline spec-dev-tool check --all reports missing sections in three unchanged historical documents: implemented/bugfix/2026-10-06-timeline-soft-scroll-edge.md, implemented/bugfix/2026-10-09-favorites-native-soft-header.md and implemented/feature/2026-09-28-bottom-lui-capsules.md. The same failures occur in the original checkout; this decision validates independently.

The actual isolated iOS 26.1 Simulator host uses the production native object and Apple LUI source pinned at 4fdb9136026af7863a8d025133871e34864eace1. Three XCTest cases pass: encrypted Timeline/detail/Back with actual background/foreground transitions, cooperative shutdown, and visible missing-key recovery. Production object SHA-256: cd19dd5871622bf57e7ed6e09c3501fd6179740d459c0bd14d574e10ea265c88. No real credentials, remote service success, mutation UI, phone installation or large benchmark was exercised. Fixture-only assertions were corrected to observe the actual request/detach lifecycle rather than assume observer ordering.

The image-preview fixture now uses the public Core.step/Effect_runner.submit asset pipeline instead of previously sealed cache execution functions. Its isolated three-image HTTPS fixture run verifies PNG bytes/checksum/size/type and cache close/reopen through public requests. It writes generated metadata and never copies private manifest codecs.

## Consequences

Old internal JSON cannot be loaded by the new codecs. Unsynced outbox records, receipts, upload intents and account bindings require explicit recovery decisions outside this code change. No real graph, account, pending upload or Keychain was purged. External protocols and binary formats retain their contracts.

## Questions

None for the approved implementation scope. The user explicitly authorized the two minimal types/storage lockfile dependency additions on 2026-10-13; they add existing resolved versions without changing pins or the switch. sync_protocol.mli is unchanged; any necessary additional protected-file change must be separately reported.
