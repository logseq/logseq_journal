# Sync Transport Recovery

## Problem

At baseline b2c32aa71c6d2cac8bee638c01827e42206943ae, a legal foreground WebSocket
Close leaves sync Offline without a reconnect task. A 101 response immediately
followed by 129 small legal frames can overflow the pending delivery queue before
activation. The TLS helper gives TCP plus TLS only one second per address.

The human explicitly authorized fixing these three defects in one formal PR and
subsequently required at most one physical sync WebSocket owner, including opening
and retirement. Generation filtering alone does not satisfy this requirement.

## Proposal

### Reducer owns recovery and one physical connection lifecycle

Keep one private connection owner with opening/open/retiring/retry states. Repeated
foreground, timer, selection and reconciliation events cannot launch a second
dial while a prior owner is opening, open or retiring. When the target scope
changes, cancel the old retry and request retirement; start the current scope only
after the runner acknowledges the old owner's I/O fibers and sockets have retired.
Late old opened/message/closed events do not alter the current scope, and late
retirement acknowledgements only discharge the exact captured owner.

Retry only recoverable peer Close/EOF/network failures while foregrounded, using
1, 2, 4, 8, 16, 30 second capped backoff. Stop/background/logout/scope changes cancel
retry and opening work. Authentication and protocol failures do not loop. Preserve
durable cursor, outbox and uncertain submissions; recovery goes through the normal
opening pull before submission. Explicit local retirement never creates retry.

The public `Websocket_closed : connection_scope * string option` cannot communicate
retry eligibility without fragile string classification. A requested nonblocking
close also has no explicit public retirement acknowledgement. Therefore request
permission for only `logseq_sync/spec/pure_reducer/core.mli`:

- Add `websocket_termination = Recoverable_close of string option | Local_close |
  Authentication_failure of string | Protocol_failure of string`.
- Change `Websocket_closed` to carry `websocket_termination`.
- Reuse `Close_websocket` with the stronger asynchronous retirement contract,
  and add `Websocket_retired of connection_scope` to public `event`. No second
  close effect is added.

Adapt corresponding implementation and existing call sites/tests. Private
`eio/websocket_eio.mli` may expose an owner retirement await primitive to the runner
and typed termination, but remains private; no public testing escape hatch is added.
No other spec or Dune change is currently proposed.

### Bounded early-frame backpressure

Keep frame/message and pending count/byte bounds. Suspend the read driver at the
queue boundary, including the normal connect-to-activation interval, until delivery
drains capacity. Do not yield inside synchronous parser payload callbacks and do
not permit the library frame queue to retain unbounded coalesced messages. No
queue-size-only fix or message dropping. Cancellation, activation failure and
callback exception must release both reader and owner.

### Independent dial and TLS deadlines

Use a shared absolute DNS+TCP dial deadline 30 seconds from connection setup start.
Both address families and every TCP address attempt use its remainder; no family
or address resets it. TCP attempts may use bounded shares of the remaining dial
window to retain address fallback. TLS handshake has its own 10-second timeout on
a connected socket. If TLS fails and another address is tried, the original dial
deadline still governs whether further TCP work may start; it never restarts. Thus
a setup that reaches its last connected socket before the dial deadline remains
bounded by 30 + 10 seconds. Cancellation propagates and joins resource owners.

Current outer wrappers conflict: HTTP perform wraps setup and response in 30 seconds,
WS setup also wraps DNS/TCP/TLS/Upgrade in 30 seconds, download wraps all in 120.
Move setup outside the business response budget: retain HTTP response/request I/O
budget 30 seconds and artifact response/write budget 120 seconds, each shared
across redirects rather than reset per hop; retain bounded WS Upgrade at 30 seconds
AFTER dial/TLS. Connection setup adds independent dial/TLS windows. Retain body size
budgets (especially 256KiB WS/general response), redirect policy and artifact bounds.
This is a deliberate phase contract, not importing Go's entire unbounded request
behavior. No net/http zero overall timeout or idle pool behavior is adopted.

## Decision

Implement the approved minimal public protocol: typed Websocket_closed,
Close_websocket with asynchronous join/retirement acknowledgement, and
Websocket_retired. No Retire_websocket effect is added. The reducer controls
retry and owns the unique physical connection slot independently of the current
graph, so old retirement acknowledgement remains meaningful across scope changes.
The runner also guards its single opening/active owner and does not hide retries.

Connect uses an absolute shared 30-second DNS/TCP deadline and an independent
10-second TLS handshake window. Each address owns a child switch: a backend can
allocate a socket before connect raises, so failed candidates must retire before
fallback; a successful child lives until the operation owner retires. Application
response budgets remain bounded and shared across redirects as proposed.

The read driver gates pending count/byte capacity before advancing another frame,
including early activation. Payload callbacks remain synchronous. Delivery releases
budget only after its callback returns. Open and terminal publication are cancellable,
and retirement is awaited from a separate interpreter fiber, never the event consumer.

## Alternatives considered

### Reconnect in eio, or filter only generations

Hidden retry bypasses account/lifecycle/outbox policy. Filtering late events cannot
close an old physical socket or prevent parallel dials.

### Guess termination kind from strings

Conflates authenticated rejection, protocol failure and temporary transport errors,
and makes correctness depend on display text. Explicit typed termination is needed.

### Start new connection immediately after Close_websocket

The current close is nonblocking. New setup can overlap the old flow/owner. Explicit
retirement acknowledgement is needed to enforce the human's singleton requirement.

### Increase queue size or reset timeouts per address

Neither fixes the ownership/segmentation defect, and resetting deadlines violates
the requested shared dial budget.

## Acceptance criteria

- All three defects have RED behavior tests before implementation, followed by GREEN.
- Reducer regression tests use public events/state/effects for reducer-owned policy.
  Early-frame and TLS defects are transport-owned and use the narrowest public Runner
  boundary; missing pure ownership boundary is documented.
- Cancel/shutdown/foreground/scope switch/stale timer/auth/protocol/local-close cases
  preserve single ownership and do not start background retry.
- Actual loopback public Runner-to-Core evidence records peak concurrent active
  sockets/dials for duplicate foreground/timer and scope switch, and stale events.
- Existing frame/byte budgets, ordinary response controls, ping/pong, close, activation,
  callback failure and resource cleanup remain verified.
- DNS/TCP share 30 seconds, TLS gets 10 seconds, outer application budgets are phased
  as stated above; cancel and fallback release all sockets/resolver handles.
- Pins and codec owner's branch stay untouched. Heavy build starts only after
  coordination. No real graph servers, GUI or phones are used.
- Formal non-draft PR and exact-head CI terminal status; no merge.

## Risks

- Typed termination and retirement events require a protected public `.mli` change.
- All callers must be adapted together. Infinite business request timeouts would be
  a regression; deadline-phase separation must retain explicit response limits.
- Physical singleton must include in-flight setup, not only returned handles.
- Current internal TLS address fallback is retained under one absolute dial deadline;
  this is not a wholesale port of Go's Happy Eyeballs connection algorithm.

## Validation

RED was observed for the missing retry/retirement effects, legal 129-frame burst,
slow legal TLS handshake, shared dial/TLS durations, auth classification and real
multiple sockets. Additional RED cases exposed stopped-consumer shutdown joins,
nonempty durable-pull backoff reset (2s instead of 1s), and failed dial allocation
retention (combined opening/connected peak 2 instead of 1).

Final local validation passes dune build -j2 @all app/native_embed.exe.o and
full dune runtest --force -j2: 21 Alcotest suites, 724 cases, and a clean source
boundary. Actual loopback Close/EOF/TCP reset, duplicate timer/foreground and scope
switch run through public Runner-to-Core events with socket, dial and their combined
peak equal to one. Cancellation, callback failure, stopped/full sinks, fallback,
body framing, gzip, budgets and outbox/uncertain-submission controls pass.

All raw evidence remains outside Git in the current task. No real graph server,
GUI, phone, Simulator or personal graph data was used. Pins and the codec branch
are untouched. Exactly core.mli is changed under spec; no Dune file is changed.
The new decision validates. check --all retains the same three historical missing
section failures in timeline-soft-scroll-edge, favorites-native-soft-header and
bottom-lui-capsules; those unrelated documents are unchanged.

## Consequences

Clients of Core must use the approved typed termination and retirement event.
Intentional closure and terminal auth/protocol failures do not generate retry;
healthy durable catch-up resets backoff. An old owner must physically retire before
any replacement dial. Setup can use the independent dial/TLS windows in addition
to the existing finite application response budget. This does not adopt Go's
unbounded whole-request default or its entire connection-pool implementation.

## Questions

None. On 2026-10-12 the human explicitly approved the displayed minimal
`core.mli` diff (typed termination, enhanced Close_websocket and retired event).
The human also authorized Go dial/TLS durations and bounded response-phase
separation. No other spec or Dune permission is implied.
