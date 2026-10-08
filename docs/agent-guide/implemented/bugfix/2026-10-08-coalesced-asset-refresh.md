# Coalesce asset refresh and defer hidden roots

## Problem

Every graph notification rereads all retained media roots, including hidden, empty and already pending roots, and restarts both offline scans. A small event or burst therefore multiplies asset queries, cancellation and staging work. The existing changefeed is a logical block/page/structure summary, not a complete reverse asset dependency index.

## Decision

Use the existing public runtime and policy owners to coalesce refresh demand. Retained hidden roots become dirty and discard global projection-bound cursors; root, asset and preview activation obtain a fresh first page. Each active root has at most one query in flight and one merged fresh demand. Superseded query completions cannot publish data or erase pending demand. Offline scans retain committed consumers while coalescing repeated changes through their current request and at most one required followup per reason.

Ordinary asset policy/runtime interfaces distinguish graph-change invalidation from the existing same-configuration lifecycle Refresh. Same graph/day/settings Refresh is idempotent; an actual graph-change invalidation restarts Finished scans and merges pending demand. Application routes raw graph push to that ordinary invalidation entry. This routine implementation choice is within the authorized F2 fix; it introduces no new UX payload or protected interface. Keeping the distinction avoids both repeated lifecycle scans and a permanent same-settings no-op after an actual graph change.

Existing block/structure changes and known referenced asset identities are positive relevance signals. Missing, empty, ancestor, schema and negative dependencies require a conservative fallback for active roots. Hidden history is never eagerly rescanned by that fallback. Resync is conservative. No protected spec, wire or Dune change is needed; existing APIs may remain conservative where they cannot prove exclusion.

The current media owner has no complete dependency proof for any active group. This implementation therefore treats every active root as potentially relevant on raw projection notifications. It does not manufacture a precise exclusion rule from unmatched block/structure UUIDs; hidden groups remain lazy. Positive changefeed signals explain known relationships, while safe exclusion is intentionally not promised.

## Alternatives considered

### Match only changed root block UUIDs

Public Database.listen/apply_authoritative probes show that child membership reports the child plus Children_interest(parent), while foreign referenced asset metadata reports only the asset UUID. The holder/root need not appear in block_uuids.

### Add protected read-dependency and scoped-cursor interfaces

The user questioned their necessity. Existing API conservative invalidation is sufficient to remove hidden and duplicate work without promising complete dependency knowledge. The proposal is withdrawn and no protected file is edited.

## Acceptance criteria

- Public production-owner tests first fail on hidden eager refresh and duplicate in-flight requests, then pass after the fix.
- Cross-page metadata, empty-to-populated roots, membership moves/deletes, preview ownership, resync, stale cursors and dirty in-flight completions preserve eventual freshness.
- Retained hidden roots issue no immediate graph-change query; activation obtains a fresh page. Burst demand does not issue duplicate in-flight work.
- Offline scan demand coalesces without retaining superseded staged results or dropping committed offline ownership.

## Consequences

- Change summaries do not expose every negative, schema or ancestor dependency. Active roots may refresh conservatively; this change does not claim perfect dependency-selective queries.
- Asset continuation cursors bind the entire projection version. All relevant graph changes invalidate saved cursors even if a root's current display appears unchanged.
- Only synthetic public API effect/query counters are evidence; no real graph/account/phone timings or physical bytes are claimed.
- Final public-owner validation passed 24 new cases: 19 demonstrated behavior RED before GREEN and 5 explicitly preserve compatible behavior. Media has 15 new passing cases plus its existing scenarios; Policy has 15 total cases (6 existing, 8 new pure-owner cases and one narrow adapter routing case). At 64 retained roots with 2 active roots, invalidation issues 2 reads, and 32 further notifications do not add in-flight requests.
- A clean Media continuation's typed stale cursor restarts once at cursor=None; a failed fresh first page stops visibly. Policy's clean stale failure remains Failed with committed demand retained, until graph invalidation or configuration replacement; no comprehensive automatic stale recovery is claimed.
- Application raw push and owned pull resync use the same invalidation. The pull binding checks the current Worker request map and protocol request UUID before removing ownership. This private Application side effect has source review, not an independent runtime test; public Runtime reset/late-response tests do not execute that binding.
- Final `dune build @all app/native_embed.exe.o` and `dune runtest --force` both exited 0. The latter used approved synthetic loopback permissions with module caches confined to the worktree. Protected spec/Dune diff is empty.

## Questions

- Authorization is resolved: the human authorized F1/F2/F3/F5 fixes and tests, and explicitly directed continuation of conservative F2 using existing APIs after withdrawing the protected interface proposal.
- Regression boundary is resolved: public media runtime and asset policy events/completions/state/effects own the amplification and receive regression tests. No duplicate runner/transport tests are added for behavior these owners reproduce.
