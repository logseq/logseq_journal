# Page-first UUID references and outline-block lookup names

## Problem

PR76 renders UUID references to journal and ordinary pages literally because generic hydration calls a block projection requiring parent/page/order. A valid page therefore returns Missing_block and is negatively cached. Naming the API get_block obscures its narrower shape.

## Proposal

The user selected get_outline_block: rename V2_get_block, V2_get_block_summary and Database.get_blocks consistently across contracts, implementations, callers, tests, fixtures and direct documentation. No compatibility aliases. Resolve uncached UUID references through get_page first, falling back to get_outline_block only on explicit Missing_page. Only both missing outcomes create a negative target cache. Preserve reference epochs, typed page metadata, deduplication and the four-read hydration scheduler. Stage the two lookups privately; no additional public type or protocol operation is needed. The user additionally requires expanded UUID references to be plain text: remove their navigation metadata and handlers while preserving explicit URL links and native whole-row Detail navigation.

## Decision

Implement page-first staged hydration with explicit outline lookup names and retryable epoch-fenced cache state. UUID expansions are plain text; remove their dedicated navigation route and preserve ordinary URL and whole-row behavior.

## Alternatives considered

### Block-first fallback or unified entity lookup

Not selected: the user explicitly requested page-first and no unified entity query.

### Keep misleading summary name

Not selected: its canonical target is also an outline block; its page result is the owning page.

## Acceptance criteria

- Page references resolve on cold and previously loaded sessions without a page-valued property.
- Ordinary outline blocks fall back only after explicit page absence, while both missing results retain literal tokens.
- Errors and cancellation never trigger fallback or a new negative cache; later discovery can retry.
- Duplicates, resets, invalidation during either stage, late completions and bounded bursts retain ownership and concurrency behavior.
- Actual DB worker and isolated Simulator validate synthetic targets, Timeline and Detail; screenshot evidence is separate from regression tests.
- Expanded and nested UUID references have no link/action metadata; tapping in Detail never navigates, while Timeline row navigation and explicit URL behavior remain intact.
- No Dune/lock/opam changes, real graph access, phone installation or publication.

## Risks

- An unknown outline block requires one additional indexed page lookup. The second stage must retain the original source epoch so a newer fragment cannot be overwritten. Expanded reference text retains its author formatting but gains no link style; explicit URL fragments keep native URL handling.

## Questions

No open questions. The user explicitly selected plain UUID text with no reference navigation; no page route is added.

## Test ownership

Journal_graph_runtime owns mutable reference caches, pending requests and hydration effects behind its public .mli. Application's pure reducer only consumes Reference_sources_changed, so injecting an incorrect None there does not reproduce query selection. The narrow regression boundary is the existing journal_graph_runtime_locality_test public submit/receive/fail/reset surface, without implementation copies or .mli bypass. Actual storage/worker and Simulator runs are diagnostic acceptance evidence, not duplicate committed regression suites.

## Consequences

Unknown outline targets cost an additional indexed page read; present pages stop after the first read. Internal text/missing/retryable cache states preserve source epochs through errors, abandonment, invalidation and later typed metadata. Only the dedicated page-missing then outline-missing chain produces a negative cache; unrelated projection misses remain retryable. Invalidated values remain visible until an accepted completion publishes their replacement or removal.

The protocol and database source names change without aliases. Expanded UUID runs retain author formatting and explicit URLs, with no reference URL or action metadata. The four-read scheduler, target bounds and source-depth limit remain unchanged.

Public runtime regressions were observed failing before implementation and pass after it, including independent review findings. Real worker acceptance uses databases created through normal storage transactions and covers cold/loaded/typed page metadata, both read stages, repeated discovery, terminal failure, abandonment and reset. External Simulator evidence is recorded in the task evidence directory; it is not injected into title caches or committed as generated data.
