# Journal Media Metadata Boundaries

## Problem

PR36's merged media presentation has four independently reproduced defects: point-read reconciliation drops resolved tag titles; Favorites never retires offscreen media roots and exhausts the 64-root capacity; tag enrichment can exceed the final encoded response budget; external attachments allow unsupported URL schemes.

## Decision

Fix these defects in an isolated checkout of current GitHub main. Deliver local commits and regression evidence only. Do not publish a PR, install an app, operate simulators, use mouse automation, or change the composer/UUID renderer work.

Ownership and regression boundaries:
- Journal_media owns external attachment presentation. Its public Show event reproduces unsupported links, so test only the pure reducer, including mixed-case schemes and malformed URLs.
- Journal_graph_runtime owns tag projection and cache replacement. Its public submit/receive/reconcile_push APIs reproduce the drop with valid tagged point responses. Cover unchanged/replaced titles and an authoritative empty list.
- Application owns conversion of native Favorites visible ranges into Int64_pair and media runtime lifetime. Root_navigation does not own media retention; Journal_media_runtime behaves correctly when supplied offscreen events. Exercise the real mounted application's native event callback rather than duplicating a pure-runtime reproduction.
- Effect_runner owns database reads and tag enrichment. Core has no database/tag resolver and cannot reproduce this defect without injecting an already oversized response. Execute actual reads against a synthetic local fixture and compare final protocol serialization bytes, including UTF-8 and JSON escaping.

Keep spec/ interfaces, dune files, native dependencies, and unrelated baseline failures unchanged.

## Alternatives considered

### Test protocol decoding alone

Typed in-process worker responses bypass JSON decoding, so decoder-only coverage cannot protect the real read/enrichment path.

### Preserve cached tags when the response is empty

An empty list is a legitimate tag removal and must replace prior metadata.

## Acceptance criteria

- Record behavioral failure before each fix and success afterward through the ownership boundary above.
- Favorites continue loading assets after more than 64 distinct roots through the actual Int64_pair path.
- Resolved tags survive point updates; valid empty metadata clears them.
- Final encoded successful responses respect both configured and protocol byte ceilings after enrichment.
- Only well-formed HTTP(S) external URLs produce links, preserving case-insensitive scheme handling.

## Consequences

- An over-budget read returns Response_too_large instead of silently dropping tag metadata or changing pagination semantics.
- Native-event regression uses an in-process host and synthetic service; it does not claim physical-device UI verification.
- Existing source_boundary_test and an older decision document fail on unchanged main; report rather than suppress them.

## Questions

- Scope and permission are already answered by the user's request: fix all four locally, require before/after regressions and specified edge cases, and do not publish or touch active QA devices.

## Implementation evidence

All four defects have behavioral RED then GREEN evidence at the documented public boundaries. The fixes and regressions are committed locally. The complete report is [local media verification](../../../test-reports/2026-10-01-journal-media-fixes/README.md). Build, formatting and affected regressions pass; existing source-boundary and historical-document failures remain explicit. No external publication or device installation occurred.
