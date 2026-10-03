# Journal Current DataScript Storage Compatibility

## Problem

Current DataScript main cannot compile the Journal storage boundary: stored nodes use arrays, store_node accepts an optional existing address, store returns an adopted database, and storage_root replaces index-order-version with schema identity metadata. Existing mirrors must remain readable without migration or deletion.

## Proposal

Adapt only the public storage/codec call sites. Keep the existing verbose Transit representation, physical children address column, staged SQL transaction and rollback boundary. Convert arrays at the codec edge, retain the existing encoded index order marker, accept legacy roots without schema identities, and preserve new identities. Honor node addresses only inside the staging buffer. Retain store's adopted database where needed; explicit snapshot persistence may discard it.

## Decision

Implement the minimal API adaptation with the existing Journal codec and staged storage. New schema identity pairs roundtrip in the schema map; missing pairs in legacy roots decode as empty. Preserve the existing encoded index-order marker and verbose Transit format. Node arrays convert at the physical codec boundary. Reuse supplied addresses only through the staging capture and atomic SQL upsert/rollback path. Snapshot-only store calls explicitly ignore the adopted database; the deliberately non-persisting authoritative connection callback returns its input.

## Alternatives considered

### Pin the older dependency

The user requires current main; pinning old code hides the API mismatch.

### Rewrite mirrors with the upstream codec

Changing physical encoding or migrating data is unnecessary. Journal's codec remains the owner.

## Acceptance criteria

- Journal builds with current DataScript and sorted-set main, preserving C and child image grouping.
- Legacy synthetic root/leaf/branch payloads roundtrip with datoms, metadata and child addresses intact.
- New schema identities survive roundtrip; mirror restore, compaction, rollback and reopen pass.
- Regression tests use public codec/storage boundaries; full build and runtest pass.
- No user graph writes, cleanup, migration, old dependency fallback, global opam changes, deployment, push or PR.

## Risks

- Address reuse must remain in the current staging buffer and SQL transaction: failed persistence must not publish altered nodes.
- Store returns an adopted database rather than a receipt. No-persistence context callbacks return their input database.
- Array node representation does not change Transit arrays on disk. Keep verbose payloads and the Journal order marker.

## Consequences

Journal now builds against current DataScript and sorted-set main. No migration, rewrite-on-open, file cleanup or user graph writes are required. The unchanged LUI feature branch is still needed because current LUI main lacks FileImage fit/fill. Native build and install consumers must use the recorded dependency checkout paths rather than the old opam-installed storage API.

## Regression boundary

No public application reducer owns the dependency record types, disk codec or physical index callbacks. It cannot reproduce these mismatches without an injected incorrect storage result. Test only public Logseq_sqlite_codec and Storage_session stage/commit/restore boundaries; do not duplicate transport/UI/E2E coverage. Existing tests receive only required API maintenance.

## Questions

None. The user authorized minimal compatibility work and preserving old data. Stop and report before any irreversible migration.

## Implementation evidence

Current DataScript main c1e1be788870f25f569926f3b096cf7986aaeab7 and sorted-set main 695223e0a28cec1ff13a6ac7e870e4983ad3bb46 build the actual Journal packages. The original Journal compiler errors are captured outside Git. Four new regressions use only public codec/session/storage interfaces: legacy root/leaf/branch roundtrip, schema identity and snapshot count roundtrip, existing-address compaction commit/reopen, and actual SQL failure after an existing node was successfully rewritten. Staging leaves all legacy fixture rows byte-identical, rollback restores all rows byte-identically, and reopen preserves datoms/schema/counts. Successful compaction retains a newly added db/ident mapping. Existing official Logseq fixture data is copied into temporary test files; no private user database is accessed.

Final dune build @all app/native_embed.exe.o and forced full dune runtest pass with current dependency mains. All 34 mirror/durability cases pass, including the four new cases. The selected C child-gallery semantics remain passing. Changed-source ocamlformat and git diff --check pass. LUI's unchanged SHA passed 47 OCaml, six tooling and 152 Apple cases in this update phase. No dune or spec files changed, no global opam pins changed, and no installation/push/PR was performed by this task. Logs and the installation handoff live outside Git. Global decision-document checking still has the pre-existing bottom-lui-capsules document's missing required sections.
