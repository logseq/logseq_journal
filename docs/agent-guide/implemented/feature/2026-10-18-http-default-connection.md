# Default connection semantics for ordinary HTTP

## Problem

Ordinary requests explicitly send Connection close. A controlled iPhone comparison reproduced truncated responses with this legal header and complete responses with explicit keep-alive, including reversed request order. This isolates a trigger, not a proven server, VPN or TLS root cause. The user requests omitting the header and a minimal PR.

## Decision

Remove only the unconditional Connection close entry from ordinary Http_eio request headers, relying on HTTP1.1 defaults. Keep per-attempt TCP/TLS setup and owner retirement after response completion. Do not introduce pooling or change DNS, TLS, proxy, buffers, deadlines, retries, dependencies or WebSocket Upgrade.

Header serialization and socket lifetime are transport-owned: Core events cannot execute either, and injecting a completion would not reproduce them. Extend existing public Runner/independent TLS-peer tests to inspect actual ordinary GET/PUT headers while retaining full-body, truncated-body and resource-retirement checks. Assert WebSocket Upgrade headers remain present and sequential requests through one Runner still retire separate connections. No test bypasses public interfaces or adds a duplicate lower-level suite.

This clean branch is based on current origin/main. It excludes all earlier diagnostic switches, Swift/C instrumentation, temporary fixtures and other fixes. Device build1.5877.47 contained the same ordinary header change in the prior diagnostic checkout; normal ready and actual WebSocket were observed. It is not the exact clean PR binary, full cross-ABI validation is not established, and manual initial graph-download acceptance remains pending. Do not publish private logs, graph contents, identifiers or credentials.

## Alternatives considered

### Explicit keep-alive or a connection pool

The user requests omission only. Pooling would change ownership beyond scope.

## Acceptance criteria

- Existing real-wire GET/PUT tests demonstrate the prior header-presence RED and pass after omission.
- Complete framing, truncation rejection, Upgrade headers and attempt-owned cleanup retain coverage.
- Final diff contains only the header deletion, necessary tests and this repository-required decision; independent review and exact-head CI are recorded.
- Publish a non-draft PR without merging or claiming an identified external root cause.

## Risks

- This mitigation does not identify the component responsible for the observed premature close.
- Each attempt still closes its connection; no cross-request reuse is introduced.
- Close-delimited bodies still need read EOF or the existing timeout.

## Questions

None. The user explicitly authorizes submission of this minimal PR.

## Consequences

The production change is one deleted header entry. The final clean-source build and sync suite pass with the original locked host providers: 313 reported cases, including all 139 transport cases. Before deletion, 16 ordinary GET/download checks, five PUT checks and the same-Runner sequence failed on the actual captured Connection header; existing WebSocket Upgrade checks passed. Independent read-only review against main 21dbe01 found no evidence-backed issue. Exact-head CI is required after publication; manual real-graph initialization remains pending.

This document validates. Full decision-document validation reports only the three unchanged historical documents already missing required sections; unrelated documents are outside this PR.
