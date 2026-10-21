# Snapshot Download Cursor

## Problem

Journal downloads issue GET /pull?since=0 only to obtain the initial journal cursor. Current Logseq obtains it from /snapshot/download metadata.

## Decision

Start bootstrap with snapshot metadata, validate its non-negative integer t before downloading, and pass that cursor unchanged to snapshot activation. Keep normal incremental pulls and WebSocket catchup. Metadata is sampled before a live stream, not a point-in-time snapshot. Preserve existing metadata fields and optional canonical acknowledgement compatibility.

Production ownership is Core's public reducer: graph selection, metadata completion, download completion, activation and graph attachment determine request order and the cursor. Regression coverage belongs there. Existing transport fixtures will follow the new request sequence without duplicating regression tests.

Sources: logseq/logseq_journal main 2d64cce; logseq/logseq master 69da7e2215; upstream PR #13814; frontend/worker/sync/download.cljs; db_sync/worker/handler/sync.cljs. The current upstream schema requires t and its client fails when absent. Do not add a legacy pull fallback.

## Alternatives considered

### Retain an initial pull for old servers

Rejected: explicitly outside the requested protocol and not current upstream behavior.

### Advance the cursor to the stream's later journal position

Rejected: live rows may include later writes without representing every intervening transaction. Preserve the metadata cursor and let normal catchup replay the journal.

## Acceptance criteria

- Bootstrap emits metadata then download then activation, with no preliminary pull.
- Metadata t reaches activation and initial WebSocket catchup unchanged.
- Missing, negative, fractional or malformed t fails before download; zero is accepted.
- Stale completions, download/activation failure and retry cannot publish an uncommitted cursor.
- Existing incremental synchronization and acknowledgement compatibility tests remain green.
- No server writes, graph resets, signing, Simulator or release artifact mutations.

## Consequences

- Old servers without metadata t cannot bootstrap, matching current upstream's explicit contract. Existing public legacy request types stay available because changing spec interfaces is outside this task.

## Questions

None outstanding. The user authorized code alignment and verification, prohibited a preliminary pull, and scoped out publishing and unrelated repairs.
