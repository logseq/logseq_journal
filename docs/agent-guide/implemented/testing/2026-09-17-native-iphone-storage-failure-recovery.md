# Native iPhone Storage Failure Recovery

## Problem

Physical iPhone acceptance has verified successful local mutations but still
needs native failure feedback, retained content and recovery evidence. Production
notes must not be used for fault injection.

## Decision

Use the existing isolated encrypted warm-start host and disposable two-graph
fixtures. Install a named SQLite trigger in graph 1 that rejects INSERT into
sync_outbox with an explicit acceptance error. Existing graph restoration and
reads remain real; the next write runs through the production worker, storage
and UI and encounters an actual SQLite transaction error. Authentication stays
blocked and secret stores stay memory-only. Do not modify production ownership,
service completions, credentials, system preferences or production data.

Exercise a native delete after its cancellation window expires. Inspect restored
content, persistent failure feedback and contextual Details/Dismiss. Copy the
isolated database back after terminating the host; verify no partial outbox
write, remove only the named trigger from that copy and return it to the same
disposable container. Relaunch, retry deliberately and verify exact deletion and
restart persistence. This is physical acceptance of existing behavior, not an
additional regression layer. Any newly found bug requires separate analysis at
its public pure owner before a regression or implementation change.

## Alternatives considered

### Return a synthetic failed service completion

Rejected: a real transaction rejection exercises the production failure path.

### Fill storage or alter the real account

Rejected: the isolated trigger bounds the fault to the disposable test graph.

## Acceptance criteria

- A signed current full-runtime host on the physical iPhone reaches a genuine
  SQLite write error after the native delete action.
- The intended block is restored, feedback remains readable with useful recovery,
  and Details/Dismiss do not enqueue a write.
- Fault removal and explicit retry produce exactly the intended graph/block
  operation; restart agrees with the committed result and graph 2 is unaffected.
- Evidence retains fixture details, exact outbox results, screenshots, binary
  hashes and any failures. No production sources, Dune or protected spec changes
  are needed unless a separately documented defect is reproduced.

## Fixture preparation findings

The first physical attempt did not reach the mutation: adding the trigger with
Python and closing the last SQLite connection removed the WAL sidecars. The
current OCaml SQLite read-only checkpoint probe returned CANTOPEN on that image;
a read-write query created the sidecars and made the same public read-only probe
succeed. The trigger itself was not shown to cause this admission failure.
Retain the failed result. Transfer the committed, quiescent fixture while its
preparation connection is still open, including the complete WAL/SHM set. Close
that local connection after transfer. Use the same process after removing the
fault from a stopped-app readback. Do not infer production deletion failure from
this fixture admission problem or claim the native read-only limitation fixed.

The first corrected transfer also exposed devicectl's remove-existing-content
behavior: it cleared the isolated Documents domain, including the fixture JSON,
not only the requested support subdirectory. The host then terminated at fixture
initialization, before production UI execution. The missing descriptor is
restored explicitly. Prior fixture readbacks and test results remain on the Mac;
no production application container was targeted. Subsequent transfers use
explicit files without this option, after the host has stopped.

## Consequences

On the physical iPhone, the corrected fixture passes actual failed-delete,
restored-content, persistent feedback, contextual Details/Close and Dismiss
checks. Both graphs have zero outbox records afterward. Removing only the named
trigger from the stopped-app copy permits native explicit retry; exactly root
80000000-0000-4000-a000-000000000002 is queued for deletion and remains absent
after restart. Graph 2 stays unchanged. SQLite integrity checks pass before and
after recovery. Production code and binaries are unchanged from batch 39.

The initial admission failure and fixture-initialization crash are retained;
they do not count as production mutation results. See batch 40 in the
[implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md)
for exact outboxes, current hashes, three successful staged physical tests and
remaining full-scope limits.

## Risks

- SQLite rejection models local transaction failure, not disk exhaustion or a
  remote mutation conflict. Do not claim those untested failure modes.
- The fixture copy must occur only after terminating the host and include any
  SQLite sidecars when present; verify integrity before returning it.

## Questions

- None. This is authorized isolated failure acceptance for the existing UI scope.
