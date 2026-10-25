# Recoverable Connection Error Indicator

## Problem

The top-right Error info icon is enabled by any worker error history or manager last_error, including resolved worker occurrences. Every new manager error also replaces the five-second sync notice. Ordinary connection interruptions therefore repeatedly attract attention and can displace a more serious notice, although their diagnostic details should remain available.

The current public sync snapshot contains only last_error:string option. The reducer knows typed websocket termination, but Recoverable_close also contains unknown transport and non-authentication TLS failures. Neither sync_phase=Offline nor the broad recoverable/network category is sufficient to safely hide an error.

## Decision

Use a finite presentation-only attention classification, with an explicit transient-connection value and a conservative requires-attention value. Carry it beside the existing unchanged message, account/graph scope and recovery state. The transport producer must classify actual typed EOF, timeout, reset/refused/unreachable conditions before their identity is lost. Certificate/handshake/security failures, authentication needing user action, integrity/corrupt-storage failures and unknown causes retain attention. Retry eligibility and outcomes remain unchanged even when a currently retried TLS/unknown failure needs visible attention.

The minimum protected interface change is limited to logseq_sync/spec/pure_reducer/core.mli:

- Add a two-case presentation classification type, tentatively Transient_connection | Requires_attention.
- Add optional last_error_attention beside snapshot.last_error; None corresponds to no current error, and unknown errors use Requires_attention.
- Carry the same presentation classification with Recoverable_close's existing optional message, using a record payload. Keep its existing retry eligibility; do not add or change a business outcome/retry category.

Ordinary lib transport interfaces can carry producer-owned finite metadata without further protected spec edits. The old string, diagnostic contents, state transitions, effects, retries, persistence and authoritative validation remain unchanged.

In the App, derive the icon and short sync notice from current attention-requiring errors, not history count. Keep Diagnostics reachable from Options and preserve bounded error details/history. A transient occurrence must not replace an outstanding serious notice or evict its retained evidence. Clear attention only on matching-scope recovery; unrelated read success must not resolve an integrity failure. Clear presentation identity on account/graph retirement.

## Alternatives considered

### Hide every network or Recoverable_close error

Rejected: that broad category currently includes TLS/unknown failures and is a retry-policy category, not a statement that the error requires no user attention.

### Match UI strings or infer from Offline

Rejected: transport identity is lost in the public snapshot; security, authentication and integrity failures can also be Offline or contain network wording. Encoding a second ad-hoc classifier into message text solely to avoid the protected interface would obscure the contract.

### Erase error history when hiding the icon

Rejected: the user wants quieter presentation while retaining diagnostic causes.

## Acceptance criteria

- Actual typed transient connection cases produce no top-right error action or transient short error notice, while exact diagnostic detail remains accessible through Options.
- Certificate/TLS policy, authentication requiring action, integrity/storage and unknown failures retain the icon.
- Repeated transient errors do not replace a serious notice or lose its evidence; matching recovery clears attention, and retired scopes do not leak stale indicators.
- Attempt reproduction at the existing public state owner first. Use the narrowest existing tests; do not add duplicate multi-layer CI regression tests or alter Dune.
- Verify actual native presentation using a graph-free isolated synthetic fixture on A135 only. Do not launch or change real Journal graph state or OS network settings.
- Keep this follow-up on its independent branch. The user authorized a formal PR on 2026-10-25; merge and release remain outside scope.

## Risks

- Recoverability for retry is not the same as safe-to-hide presentation. Unknown transport failures must remain visible rather than being guessed transient.
- Worker Graph_ready currently marks the whole worker ledger inactive; that is not proof an unrelated sync-integrity failure recovered.
- Source metadata must remain scope-fenced and not leak exception payloads, credentials, URLs or graph content.

## Questions

- The user explicitly approved only this new protected file and the proposed presentation classification/snapshot/Recoverable_close metadata on 2026-10-24. No permission extends to retry-policy changes or other protected interfaces. No unanswered question remains.

## Consequences

- The explicitly approved Core spec adds presentation-only error_attention metadata beside the unchanged message and Recoverable_close payload. Existing termination/retry categories, reconnect effects/backoff, transport results and persistence logic remain unchanged. The service copies the typed metadata into the App snapshot.
- Known EOF/liveness/timeout/reset/refused/unreachable failures are quiet. DNS failures are quiet only when both failed families are known timeouts; empty/unknown results remain conservative. An address attempt containing any security/permission/unknown failure stays attention-worthy even if a later address merely times out. Certificate/authentication/protocol and unknown failures retain attention. The old transport APIs keep their result variants and fixed safe messages.
- All header paths share the active/current-scope attention predicate; resolved history no longer lights the icon. Transient manager messages do not create the short sync notice or replace retained serious attention. Matching Current/no-error recovery and scope retirement clear it. Diagnostics retains the original current reason and additionally exposes retained serious attention.
- Ordinary Graph_ready keeps Corrupt_storage/Ambiguous_sync_state occurrences active. The existing 32-entry history prioritizes that active integrity evidence over repeated lower-priority occurrences without becoming unbounded.
- Existing App chrome and reconnect tests were extended, with actual RED→GREEN failures for transient header suppression and metadata propagation. The actual Runner refused-connection test also rejects missing presentation classification, then passes with the typed producer. One public App-owner integrity/history regression was added in the existing suite; no Dune or CI route changes were made.
- Final source passes application149, sync327, worker runner50, worker reducer20, plus existing startup and worker service checks; @all/native_embed builds. One initial source-guard test run from the wrong working directory failed to find source, then the unchanged test passed from its required repository root with external log output.
- A135 isolated bundle org.logseq.journal.attention-probe, candidate1.5877.6601, uses only synthetic immutable manager snapshots and the actual App state/header/error-info/Diagnostics. Exactly five external adapter overrides are documented; all other product files match. Native UI confirms quiet connection errors, Options→Diagnostics reason retention, visible integrity/TLS/unknown icons, severe reason retained across40 transient updates, and recovery/new-scope clearing. Fixture stopped and A135 released. No normal App, real graph/account, OS network setting or1446 operation occurred.
- The Simulator build uses the maintained experimental host-restamp route and retains cross_abi_validated=false. This is isolated UI/owner validation, not a full live-account/network acceptance run. No push, PR, merge or release was performed. Temporary probes, manifests, patch and screenshots remain in external evidence.

## PR preparation

The user authorized publishing completed changes as independent formal PRs on
2026-10-25. Reconcile this branch with current main and rerun affected existing
checks before publishing. Preserve the isolated UI validation boundary above;
no new Simulator/graph operations are required and the 6709 normal App is left
untouched. Timeline/integrity investigations and diagnostic-only observers remain
in a separate PR; no speculative sync or Feed repair is part of this change.

Final main-reconciled validation passes @all plus application149, sync333, Worker
runner50, Worker reducer20, startup and LUI service checks. PR115's newly added
manual-sync fixture now supplies the conservative attention field required by the
already approved Recoverable_close metadata; its retry assertions are unchanged.
The first sandboxed Sync test run could not bind its localhost fixture sockets;
the same complete suite passes with the required local-network execution access.
The five invalid historical agent documents are byte-identical to main; both
changed decision documents validate individually. No GUI revalidation or normal
App installation was performed during PR preparation.
