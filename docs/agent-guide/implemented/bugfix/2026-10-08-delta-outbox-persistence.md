# Persist outbox changes by stable identity

## Problem

Appending or updating a local transaction rewrote every retained outbox row. Mutable records and graph revision embedded in each payload caused unrelated operations to generate durable writes. Empty queues lost revision metadata on reopen.

## Decision

`logseq_db_storage/lib/sync_outbox_store.ml` stores queue records under stable mutation UUID primary keys and immutable sequence values. Independent versioned metadata owns the sync revision. `logseq_overlay_db/lib/database.ml` compares current encodings with a frozen committed map and passes only changed rows and removed identities to storage. Metadata, queue rows, receipts, and authoritative checkpoints commit in the same transaction. The frozen map changes only after COMMIT succeeds.

## Migration and recovery

Database opening reads payloads and metadata in one read snapshot. Migration obtains `BEGIN IMMEDIATE`, compares raw records against the validated snapshot, checks revision, and then upgrades the legacy position ledger atomically. Any mismatch or failure rolls back. The new schema retains stable sequence holes; old position readers and full-replacement writers fail closed. Empty queues retain their metadata revision.

## Regression boundary and validation

The user authorized F1 implementation, actual tests, and a formal PR. No protected spec or Dune file changes are needed. Public Database APIs plus SQLite audit triggers observe committed row changes; the pure reducer does not execute SQL. A narrow public Store test reproduces the interleaving between validated legacy reads and migration.

All 46 storage cases passed, including same-ID replay/conflict, No_change receipts, mutable submit/accept updates, middle deletion, empty reopen, legacy migration, writer lock, stale validated migration snapshots, COMMIT failure/retry, and an external revision conflict. Appending 32 intents changed 32 rows and wrote 35,109 logical payload bytes. Appending 1,000 changed 1,000 rows and wrote 1,100,679 logical payload bytes. The previous implementation changed 1,000,000 rows for the 1,000-intent scenario. These counters do not measure physical database or WAL bytes.

## Alternatives considered

### Retain full replacement

This retains quadratic cumulative durable writes and same-value rewrites.

### Renumber rows after each removal

This rewrites unaffected rows. Stable sequence holes preserve order without renumbering.

### Compare mutable record references

Live transport fields mutate in place. Frozen encoded values preserve the actual committed baseline across failures and retries.

## Consequences

Queue SQL writes and payload bytes are proportional to changed records. Necessary receipts/checkpoints still persist when queue rows do not change. Current encoding and comparison still traverse the retained queue, with O(N) serialization and O(N log N) map/sort work; this change does not make all CPU work proportional to the delta. Opening performs an additional locked comparison needed to prevent migration from losing a concurrent writer's rows. Downgrading to a legacy writer is intentionally rejected rather than discarding the new metadata.
