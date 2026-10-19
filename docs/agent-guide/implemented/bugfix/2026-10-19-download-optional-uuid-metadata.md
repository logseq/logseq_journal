# Accept Downloaded Snapshots Without UUID Metadata

## Problem

Cloud graphs created through the upstream incremental sync path can omit both
`:logseq.kv/graph-uuid` and `:logseq.kv/local-graph-uuid` from the server snapshot.
Journal currently rejects those otherwise valid snapshots. The upstream source
was audited at logseq/logseq commit 22a29b30dee3b3930cf49bba50454650c31d2a07.

## Decision

For Synced_target only, allow either or both values to be absent. Preserve UUID
parsing and reject a present remote UUID that differs from the requested target.
Retain db-type, schema, remote flag, physical storage, row count and integrity checks.

Admission.admitted.local_graph_uuid becomes optional in its lib interface; Mirror
is its only consumer and reads only schema. Checkpoint identity already comes from
the inspected download target. Do not generate a UUID or rewrite snapshot metadata.
Keep Local_target's existing required local UUID behavior. No protected spec or
Dune interface changes are needed.

Admission is owned by storage inspection, not a pure reducer: a reducer can only
receive an injected failure and cannot execute this validation. Reproduce through
Database.prepare_snapshot_activation with real synthetic framed snapshots, then
commit/reopen successful cases and check the target checkpoint and queryable data.

## Alternatives considered

### Generate missing identities

Rejected: no downstream consumer needs a generated local UUID, and inventing or
overwriting a remote identity would obscure conflicts instead of validating them.

## Acceptance criteria

- Each UUID missing separately and both missing activate and reopen successfully.
- Existing valid identities continue to activate; present remote conflicts fail.
- Present malformed UUID values fail without being overwritten.
- Other required metadata and physical storage checks remain fail closed.
- Local_target continues to require a local UUID.
- Target graph UUID and baseline cursor persist unchanged in the local checkpoint.

## Risks

- When the remote UUID is absent, graph identity comes from the existing scoped
  request target rather than redundant snapshot metadata. This is intentional.
- The admitted local UUID type changes to option; all repository consumers must
  compile without introducing synthetic values or weakening local graph admission.

## Consequences

Nineteen regression cases exercise real synthetic snapshot preparation,
activation, checkpoint persistence and reopening. Before implementation, three
missing-UUID acceptance cases failed, plus the missing-local/conflicting-remote
case returned the earlier local-metadata corruption error. All nineteen now pass;
the complete storage suite passes 82 cases. Existing row, structural, schema and
checksum regressions remain in that suite.

Independent read-only review found no actionable issue. The change uses only the
lib Admission interface; protected spec interfaces and Dune files are unchanged.
No UUID KV is generated or rewritten, and no private graph or device is involved.
