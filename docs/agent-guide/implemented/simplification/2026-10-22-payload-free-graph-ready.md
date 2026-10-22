# Payload Free Graph Ready

## Problem

At main b6c1c77c4cd7b94963e4729dfac55b825c838085, Journal_graph_runtime copies
six graph-info fields into Graph_ready. Its sole Application consumer ignores
the payload. The app library has no public_name; repository-wide searches found
no other Graph_ready consumer, registration or serialized representation.

## Proposal

Make the internal Graph_ready notification payload-free and remove its graph_info
record from app/journal_graph_runtime.ml and .mli. Preserve V2_graph_info requests,
correlation, failure handling, task-catalog launch, readiness publication and
independent admission inspection. Do not change worker protocol or its codecs.

## Decision

Adopt the proposal as explicitly authorized by the user on 2026-10-22.
Implementation and verification are local; no push or PR is authorized.

## Alternatives considered

### Remove the graph-info request

Not selected: the successful response gates readiness and starts task-catalog
loading. Other graph-info operations consume journal formatting and revisions.

## Acceptance criteria

- Existing runtime-locality, Application and worker integration tests pass.
- Temporary public Runtime traces normalize only the intentionally removed
  internal payload and compare requests/notifications across success, failure,
  abandonment/reset, duplicate and stale completion paths.
- Independent admission reads and their tests remain intact.

## Risks

- Removing the internal payload must not remove the actual request or its
  failure/correlation boundary. Supported external consumers discovered during
  implementation would require reconsidering the scope.

## Consequences

Graph_ready is now an internal payload-free notification; worker protocol and
independent admission inspection are unchanged. Baseline and final runtime-locality
(152 cases), Application (144 cases, including admission refresh and unlock), and
worker integration (15 cases) pass. Temporary runtime replay yields 5,906 identical
records after normalizing only the removed Graph_ready argument, including explicit
success, duplicate, failure, abandonment, reset and stale-completion scenarios.
Native Swift startup/failure boundary tests also pass; no GUI or real graph was used.

## Questions

None. The user authorized this exact internal simplification on 2026-10-22;
no worker wire change, push or PR is authorized.
