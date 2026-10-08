# Coalesce pull demand through durable completion

## Problem

Hello, Changed, submit completion, and recovery events independently issued pulls at the same cursor. Notification bursts amplified transport requests, while missing transport send failures did not reach the Core state owner.

## Decision

`logseq_sync/lib/pure_reducer/core.ml` owns graph-scoped maximum pull demand and one active connection-scoped pull. Its stages cover response waiting, authoritative application, and delayed retry. Demand never advances the applied checkpoint; only the existing authoritative COMMIT completion does. Opening, notifications, terminal outbox outcomes, retry timers, and catchup use the same owner. `logseq_sync/lib/effect_runner/effect_runner.ml` forwards unavailable sockets and send errors as the existing `Websocket_closed` fact.

## Recovery and public phase

A response has a 30-second timeout. Empty or otherwise non-progressing responses retain the maximum target and retry after 1, 2, 4, 8, 16, then at most 30 seconds per round while demand remains. These are bounded-rate retries, not a fixed maximum number of attempts. The owner consumes each timer once, ignores late response timers during application, and fences old connection callbacks. Reconnection retains demand only for the same graph; graph/account retirement clears it.

`settled_sync_phase` uses outstanding demand, pull ownership, and authoritative application. Already applied acceptance/rejection barriers remain Current without a redundant request. Catchup and delayed retry remain Pulling. Existing Submitting and Paused policy remains unchanged.

## Regression boundary and validation

The user authorized F5 implementation and actual tests. Existing opaque timer IDs permit private timer kinds without protected spec or Dune changes. Public Core events/effects reproduce pull amplification and receive reducer regressions. Missing registered socket identity belongs to the effect runner and receives one narrow public adapter regression.

The final focused run passed 86 cases: 42 pure Core, 21 recovery, and 23 runner cases. Opening plus Hello and 100 Changed notifications produced one Pull effect instead of 102. The tests also cover sparse catchup to cursor 101 through public durable completion facts, partial catchup, empty high-cursor responses without prior notification, retry phases, timeout/reconnect, old callbacks, in-progress application, terminal outcomes, shutdown, and picker retirement. These counters measure logical transport effects; they do not measure server traffic, physical SQLite writes, or phone timings.

## Alternatives considered

### Deduplicate only Changed events

Other pull entry paths still overlap and durable application completion remains unowned.

### Retry in a hidden runner loop

This separates recovery policy from Core and makes scope fencing and retries unobservable.

### Advance the checkpoint to the advertised head

An advertised target is not a durable apply fact and cannot replace the committed cursor.

## Consequences

Burst notifications merge into state without duplicate network effects or database writes. Partial progress retains the maximum pending target. Timers provide bounded waiting and retry rates. The wire protocol has no request ID, so connection fencing and one active request provide correlation; the existing unsolicited response compatibility path is retained when no owner/application is active. An existing lexical cursor-order validation issue for dense transaction fixtures crossing decimal digit widths remains outside this change; sparse public batches are valid and were used for the high-cursor recovery test.
