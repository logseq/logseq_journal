# Own Sync Transport Lifecycles with Httpun and Eio

## Problem

This decision records the September 5 transport audit and the user's
revised implementation premise: retain `httpun` + `httpun-eio` for HTTP and use
`httpun` + `httpun-ws` with a project-owned Eio driver for WebSocket. Fix connection ownership and
project integration within those stacks. The Httpun-family protocol limitations
recorded in T12-T18 are accepted for this change; repairing them is not a completion
requirement.

This decision supersedes the earlier custom HTTP and WebSocket parser/serializer
proposal. Implementation now uses the selected libraries with owned connection
lifetimes. The custom protocol engines have been removed. The implementation record
below distinguishes verified project behavior from accepted dependency limitations
and unconfirmed deployment evidence.

### Scope classification

| Findings | Treatment in this decision |
| --- | --- |
| T1 | Investigate the reported EOF; do not claim its root cause is established. |
| T2-T11 | Repair project-owned lifecycle, streaming integration, setup, credential, and queue behavior using the selected libraries. |
| T12-T18 | Retain the evidence and accept the dependency limitations; no custom protocol engine, dependency correctness patch, or replacement is required to repair them. |

T4 is misuse of the parser's partial-input contract by the old project pump, T5 is
concurrent mutation of project-owned fragment state, and T6 includes an incorrect
`Wsd.close` invocation. They remain in scope even though their evidence mentions
Httpun. T11 remains a wrapper admission responsibility despite the dependency's
unbounded default serializer queue. The Eio resolver cancellation issue in T7 is
not a Httpun protocol limitation and remains in scope.

### Scope and evidence

The implementation boundary is `logseq_sync/lib/effect_runner/eio/`:

- `http.ml`: request construction, credentials, response media types, and limits.
- `http_eio.ml`: HTTP request execution, redirects, response reads, and file downloads.
- `websocket_eio.ml`: Upgrade, network pumps, frame assembly, sends, and closure.
- `tls_client_eio.ml`: DNS resolution, TCP connection, and TLS setup shared by both
  transports.

Caller integration covers ownership, notification ordering, close/cancellation
dispatch, and preservation of existing HTTP authentication-result classification.
At audit time, the transports received the Effect Runner's long-lived switch. Graph
identities, account state, outbox processing, authoritative replay, and UI state are
outside this decision.
In particular, automatic reconnect/backoff, ignored send results in the Runner,
pull/transaction acknowledgement deadlines, and cancellation policy on application
backgrounding are excluded. Protocol Ping/Pong liveness and honoring an actual
caller cancellation remain transport responsibilities.

Evidence labels below distinguish reproduced defects, source-confirmed gaps, and
reported symptoms or deployment-dependent risks. References to "current" or
"installed" in T1-T18 describe the audited baseline, not the subsequent uncommitted
custom-parser implementation. The scope classification above controls which
findings remain repair requirements. Local probes used the installed
Httpun/Eio dependencies and temporary files outside the repository. They were not
live-server fault-injection tests.

Earlier follow-up reviews added eight findings: DNS cancellation limits
(T7), message delivery during handoff and close/abort dispatch (T6), preservation
of download authentication outcomes (T3), and four additional transport gaps
(T11-T14). The T3 authentication and T6 close/abort findings identify risks in the
proposed redesign, not regressions already introduced into the implementation.
Follow-up probes used Eio/Eio_posix 1.2 and Httpun/Httpun_ws 0.2.0. Their essential
inputs and observed outputs are recorded below so the evidence does not depend on
temporary probe files remaining available.

A follow-up review extends T12 with reproduced length-encoding and integer-conversion
gaps, and adds HTTP/Upgrade header and input-buffer limits (T15). Its probes used
the same installed Httpun/Httpun_ws 0.2.0 dependencies. The T15 probe demonstrates
HTTP parser admission; it does not reproduce a live Upgrade memory incident.

The latest review adds premature completion on informational HTTP responses (T16)
and rejection of valid chunk extensions and trailers (T17). Direct HTTP client
probes used the same installed Httpun 0.2.0 dependency. These are parser-level
reproductions with source-confirmed wrapper implications, not end-to-end request
reproductions or evidence establishing the reported EOF's root cause.

The first round of the subsequent five-round review adds inconsistent HTTP
transfer-coding selection (T18). Its direct Httpun 0.2.0 client probe was independently
rerun; the finding combines parser reproduction with wrapper source inspection.

### T1. HTTP reports EOF despite a reportedly healthy server

**Evidence:** Reported symptom; root cause remains unconfirmed.

**Trigger:** The user reports receiving EOF after sending an HTTP request while the
server is operating normally. The exact response stage and connection identity
have not yet been correlated with the error.

**Impact:** A valid request or artifact download may be reported as failed. Server
health alone does not establish whether that individual response was complete.

**Relevant code:** `http_eio.ml` functions `request_headers`,
`protocol_error_message`, `request_once`, and `download_once`.

The client sends `Connection: close`. Connection EOF after a correctly completed
response must be distinguished from premature EOF during headers or a framed body,
TLS shutdown errors, and an error from an earlier cancelled or completed request.
For a close-delimited HTTP body, EOF can itself delimit completion; classification
must follow the response framing rather than treating every EOF identically.

T2, T3, and T6 provide plausible stale-driver and late-callback mechanisms. They do
not prove the origin of this reported EOF. The previous document's successful
server probes and six `CLOSE_WAIT` sockets are historical observations that were
not reproduced in this audit; neither establishes the current EOF root cause.

### T2. HTTP resources outlive the logical request

**Evidence:** Source-confirmed ownership gap.

**Trigger:** Any request reaches success, protocol failure, a body-size rejection,
a redirect, timeout, or cancellation while the caller switch remains alive.

**Impact:** Request sockets and protocol-driver fibers are not explicitly retired
by request completion. Repeated requests can retain descriptors or blocked readers;
old drivers can continue to invoke callbacks after the caller has moved on.

**Relevant code:** `http_eio.ml` functions `request_once`, `download_once`,
`perform`, and `download`.

Each attempt creates a TLS flow and `Httpun_eio.Client` under the supplied switch,
then waits for a result promise. No request-level finalizer shuts down and joins
the client driver and closes the flow. Resolving the promise, closing the response
body, or sending `Connection: close` does not establish local resource retirement.
The HTTP 30-second and download 120-second timeouts do not own those driver fibers.

### T3. Downloads lack safe file ownership and a checked success handoff

**Evidence:** Source-confirmed cleanup, callback-fencing, and output-error gaps.

**Trigger:** Cancel or time out after the destination channel opens; deliver a late
protocol error after completion; reuse the destination path for a later attempt
while an older attempt still owns callbacks; or fail to flush buffered output when
closing an otherwise complete response.

**Impact:** Cancellation can leave a partial file and open channel. Timeout removes
the path without explicitly closing the channel or retiring the driver. Late
callbacks can continue writes/progress or delete a path now used by another
attempt. A settled result promise prevents a second result, but does not prevent
these side effects. A complete HTTP response can also be reported as a successful
download even when closing the output channel fails to write its buffered bytes.

**Relevant code:** `http_eio.ml` functions `download_once` and `download`.

The cancellation branch rethrows immediately. The destination channel is local to
`download_once`, outside the cleanup available to `download`'s timeout handler.
The protocol error callback unconditionally closes/removes the destination before
trying to resolve the promise. Each follow attempt also removes the destination
without an explicit distinction between temporary and committed file ownership.

`close_destination` uses `close_out_noerr` on both failure and success paths.
`finish` then resolves the successful result without observing a flush/close error.
Best-effort cleanup is appropriate after failure, but cannot establish that a
successful response has been fully written to the destination file.

The success-handoff redesign also needs an explicit HTTP outcome contract.
`Effect_runner.execute_request`'s `Download_snapshot` branch currently recognizes
401 and 403 through `Ok response`; a 401 drives the existing token invalidation and
refresh attempt. Converting every non-2xx download response into a generic string
`Error` would instead classify it as `Request_failed` and bypass that behavior.
Preserving a classifiable HTTP rejection is separate from publishing a successful
artifact: a non-success response must not publish a file. This is a source-confirmed
caller dependency and a design gap, not a reproduced authentication regression.

### T4. Valid partial WebSocket input is treated as a parser failure

**Evidence:** Reproduced against the installed parser.

**Trigger:** A network read ends partway through an Upgrade response or WebSocket
frame header, including a partial next header following a complete frame.

**Impact:** Valid input can raise `WebSocket parser did not consume network input`
and terminate the connection. This is ordinary stream segmentation, not evidence
of a malformed server frame.

**Relevant code:** `websocket_eio.ml`, `start_connection`'s read loop.

The loop requires every parser call to consume a positive number of bytes and
immediately retries any remainder without retaining it for a later network read.
The local probe supplied the first byte `0x81` of a valid Text frame: `read` returned
zero and `next_read_operation` remained `Read`. Supplying the retained byte together
with `0x01` and `x` then consumed all three bytes successfully. The current pump
would fail at the first result. The same buffering design must also respect parser
`Yield` and `Close` operations during backpressure.

### T5. WebSocket fragment handlers can reorder message assembly

**Evidence:** Reproduced using the current payload reader and frame handler extracted
unchanged into a local Eio probe.

**Trigger:** Fragmented frames arrive together while payload completion wakes an
older handler and advancing the frame queue forks a later handler.

**Impact:** A message can lose a fragment or be delivered with incorrect content,
causing downstream decoding failures or incorrect application input.

**Relevant code:** `websocket_eio.ml` functions `read_payload` and `connect`'s
`websocket_handler`.

Every frame runs in a new fiber and shares one mutable `fragments` buffer. The probe
fed `Text("A", fin=false)` followed by `Continuation("B", fin=true)` in one read.
Expected delivery was `AB`; actual delivery was `B`. Payload availability and frame
queue ordering do not guarantee that the independently resumed handlers update the
shared buffer in wire order.

### T6. WebSocket termination does not retire the connection owner

**Evidence:** Source-confirmed ownership and connection-handoff gaps; the missing
outgoing Close frame was reproduced against the installed Httpun_ws implementation.

**Trigger:** Explicit close, peer close/EOF, parser or I/O failure, failed Upgrade,
handshake timeout, or caller cancellation during connection setup or use. Also,
Upgrade can succeed immediately before a Close/EOF or first data frame arrives
during handle handoff.

**Impact:** The TLS flow and blocked pumps can outlive the logical connection.
Explicit close does not send a Close frame, wait for a bounded close handshake, or
join the pumps. A terminal callback during handoff can precede registration of the
handle, allowing the Runner to register a closed connection and publish it as open.
Returning an error does not prove that a failed connection attempt has released
its resources.

**Relevant code:** `websocket_eio.ml` functions `start_connection`, `connect`, and
`close`, and type `t`; the Runner's `Start_websocket` handle registration.

The handle retains the protocol and descriptor, but no flow/lifetime owner. The
writer only shuts down the send side; `close` calls `Httpun_ws.Wsd.close` without a
code and then protocol shutdown without closing the flow. In the installed library,
that no-code call closes the writer without serializing a Close frame. A local
probe using the same close/shutdown sequence returned `Close` with no queued frame;
passing `Normal_closure` instead produced an eight-byte write. Peer-close handling
also uses the no-code call, so sending a Close response needs explicit coverage.
Cancellation is rethrown without an outer transport finalizer. Frame-local terminal
paths share the same missing cleanup. The `close_once` guard limits its own callback
invocation; it is not a resource ownership mechanism.

The Upgrade handler resolves the opened promise before the Runner registers the
returned handle. Pumps and frame handlers can deliver `on_close` during that gap;
the callback removes the current table entry, but the success continuation can
subsequently insert the already closed handle and publish `Websocket_opened`.
Guarding the number of terminal callbacks alone does not order this handoff.

The same gap permits `on_message` before registration and `Websocket_opened`.
`Core.websocket_message` discards input while `websocket_live` is false, so a first
message can be silently lost even if open/close ordering is corrected. The source
confirms the missing delivery gate; this session did not run an end-to-end Runner
handoff reproduction. Message delivery must participate in the same activation
boundary, including Upgrade and Text input received together.

The proposed graceful-close wait also needs a distinct caller contract. Runner
`Close_websocket`, `cancel_scope`, and `shutdown` synchronously invoke the same
`close_websocket` function, including during table traversal. Turning that function
into a handshake wait and join would suspend those dispatch paths. Established
connections have already left the operations table, so cancelling setup is not an
independent abort route for them. Define how ordinary close, completion waiting,
and immediate abort are requested, and wire cancellation/shutdown explicitly.
This is a source-confirmed integration constraint on the proposed redesign.

The old document's claim that Upgrade failure never resolves the handshake promise
is obsolete: the current error handler resolves `Error` promptly and distinguishes
401 and 403. Preserve that behavior and test cleanup on those paths. The reproduced
Close-frame defect is failure to enqueue the frame, not evidence that shutdown
discards an already queued frame. Both frame exchange and bounded cleanup require
an explicit contract.

### T7. Setup deadlines omit WebSocket setup and cannot promptly cancel current DNS

**Evidence:** Source-confirmed setup and resolver gaps; delayed timeout return
reproduced using the installed resolver's system-thread mechanism.

**Trigger:** Slow or failing DNS resolution, a stalled TCP connect, or a TLS peer
that does not complete negotiation.

**Impact:** WebSocket connection setup can exceed its apparent 30-second deadline.
DNS exceptions can escape the typed connection-error boundary and fail the calling
fiber instead of returning a connection result. HTTP requests and downloads also
cannot guarantee timely timeout/cancellation return while current DNS resolution
is blocked, despite already having an outer timeout.

**Relevant code:** `websocket_eio.ml`, `connect`; `tls_client_eio.ml`, `connect`;
`http_eio.ml`, `perform` and `download`; installed Eio_posix `Net.getaddrinfo`,
Eio_unix `run_in_systhread`, and Eio `Fiber.first`.

`open_flow` completes before the 30-second Upgrade timeout starts. DNS resolution
also executes outside the TLS connector's exception handler. HTTP already wraps
its setup in its outer request timeout and generic exception handler. Its missing
guarantee is prompt cancellation of the underlying operation, not an absent wrapper.

The installed Eio_posix resolver runs `Unix.getaddrinfo` through
`Eio_unix.run_in_systhread`. Once submitted, that blocking call cannot be interrupted
by fiber cancellation; `Eio.Time.with_timeout_exn` uses `Fiber.first`, which waits for
the losing branch to finish. A probe wrapped
`Eio_unix.run_in_systhread (fun () -> Unix.sleepf 0.25)` in a 0.010-second timeout.
It returned `Timeout` only after approximately 0.255 seconds. This reproduces the
cancellation limitation of the mechanism, not an actual stalled DNS lookup.

Moving the WebSocket timeout outward is necessary but insufficient. The shared
resolver needs a concrete bounded cancellation and reclamation strategy for both
transports. Merely abandoning a resolver fiber would conflict with the ownership
contract and could accumulate system-thread work. Other HTTP cleanup gaps remain
T2/T3.

### T8. Shared TLS setup only attempts the first resolved address

**Evidence:** Source-confirmed availability gap.

**Trigger:** DNS returns multiple addresses and the first is unreachable, such as
an unusable IPv6 route followed by working IPv4, or a failed first server address.

**Impact:** Both HTTP and WebSocket fail despite another resolved address being
reachable.

**Relevant code:** `tls_client_eio.ml`, `connect`, the `address :: _` branch.

There is no alternate-address attempt or bounded address-racing strategy. Any
replacement must share the overall connection deadline, close failed/losing
attempts, and retain authentication of the original hostname. A shared deadline
alone is insufficient: sequential attempts can let a blackholed first address
consume the entire budget before a reachable second address is attempted.

### T9. WebSocket provides no active protocol-level liveness detection

**Evidence:** Source-confirmed capability gap; manifestation depends on the network
and peer's own heartbeat behavior.

**Trigger:** A silently blackholed or half-open connection receives neither normal
traffic nor a close indication and the peer does not provide an effective heartbeat.

**Impact:** The transport can retain an apparently open connection indefinitely
without reporting failure to its caller.

**Relevant code:** `websocket_eio.ml`, Ping/Pong handling in `websocket_handler`.

The client replies to Ping and ignores Pong but does not originate tracked Ping
probes or enforce a Pong deadline. This finding concerns WebSocket control frames
only. Application-message Pong, pull response timing, transaction acknowledgement,
and reconnect policy are explicitly outside scope.

### T10. Artifact request credentials are not bound to a trusted origin

**Evidence:** Source-confirmed request-construction behavior; exposure depends on
the download URL returned by the deployment.

**Trigger:** Artifact metadata supplies an HTTPS URL on another host, including an
object store/CDN or a misconfigured destination.

**Impact:** That host receives the account's bearer ID token even when it only needs
the signed URL. This audit did not establish that production currently returns an
untrusted host or that a token has been exposed.

**Relevant code:** `http.ml`, `valid_artifact` and `artifact`; `http_eio.ml`, redirect
handling and `same_authority`.

Artifact validation checks URL shape but not the credential destination, and
`artifact` unconditionally adds authorization. The redirect authority check only
protects subsequent hops; it does not protect the initial request to the supplied
URL. Credential policy must be explicit at request construction and enforced at
every hop without inferring trust from HTTPS alone.

### T11. WebSocket sends have no aggregate queue bound

**Evidence:** Source-confirmed missing admission limit; undrained writer accumulation
reproduced against the installed Httpun_ws serializer.

**Trigger:** Call `send` repeatedly while network writes are stalled or slower than
message production, with each message below the per-frame limit.

**Impact:** Accepted output can accumulate without a transport-level total bound.
Control frames can also queue behind application output, affecting heartbeat and
graceful-close timing.

**Relevant code:** `websocket_eio.ml`, `send` and the writer pump; installed
Httpun_ws `Wsd.send_bytes` and its Faraday queue.

The wrapper checks only `Limits.maximum_request_bytes` for each payload. A probe
called `Wsd.send_bytes` 256 times with 65,536-byte Text payloads without draining or
reporting writer progress. Every call succeeded, and `next_write_operation` exposed
16,780,800 queued wire bytes while the connection remained open. This demonstrates
serializer accumulation under the wrapper's per-frame limit, not a measured
production memory incident. The proposed bounded receive queue does not bound sends.
Define aggregate admission, queue-full outcomes, and control-frame scheduling
without relying on changes to business retries or ignored send-result handling.

### T12. WebSocket input validation is incomplete below the application decoder

**Evidence:** Invalid-frame admission reproduced against the installed parser;
source-confirmed missing validation in the current frame handler.

**Trigger:** Receive an oversized or fragmented control frame, an orphan
Continuation, a frame with an unnegotiated reserved bit, a nonminimal length
encoding, or an extended length with a forbidden high bit or an unrepresentable
OCaml `int` value.

**Impact:** Invalid input reaches handlers instead of terminating the connection.
The current Ping response logic can emit an invalid Pong in response; malformed
fragment sequences can be treated as application messages or overwrite assembly.
Unchecked length conversion can turn a wire length into zero or a negative number
before the transport has an opportunity to enforce its frame limit.

**Relevant code:** `websocket_eio.ml`, `websocket_handler`; installed Httpun_ws
`Parse`, `Websocket_connection`, and `Wsd.send_pong`.

Using a direct client connection and a draining handler, the following inputs each
invoked a frame callback without a parser error or connection closure:

- `89 7e 00 7e` followed by 126 `x` bytes: Ping with a 126-byte payload.
- `09 01 78`: Ping with FIN unset.
- `80 01 78`: a Continuation without an initial data frame.
- `c1 01 78`: Text with RSV1 set, without extension negotiation.

Applying the current Ping reply logic to the first case queued a 134-byte masked
Pong carrying the same 126-byte payload. These are parser/handler probes, not live
peer tests. Serializing fragment handlers fixes ordering but does not provide the
missing validation state. The current handler also has no explicit validation of
Text UTF-8 or Close payload structure/status/reason; those additional cases were
identified from source and were not exercised by these probes.

Additional direct-client probes used `Client_connection.create` with a draining
payload handler on the current 64-bit runtime:

- `81 7e 00 01 78`: a one-byte Text payload encoded using the extended 16-bit form.
  The parser consumed all five bytes, reported length `1`, and completed the payload
  without an error or closure, despite the nonminimal length encoding.
- `81 7f 80 00 00 00 00 00 00 00`: an extended length with the forbidden highest bit
  set. The parser consumed all ten bytes, reported length `0`, and completed an
  empty payload without an error or closure.
- `81 7f 40 00 00 00 00 00 00 00`: a declared length of `2^62`. The parser consumed
  the ten-byte header and reported length `-4611686018427387904`; the payload did
  not complete, and no error or closure was reported during that read.

The installed `Parse.payload_length_of_headers` converts the raw 64-bit value with
`Int64.to_int` without checking representability. Checking the callback's `len:int`
alone cannot recover discarded bits or establish that the original encoding was
valid. Correcting this would require validation before narrowing or payload
consumption; that parser-level repair is outside this decision.
See [RFC 6455 base framing](https://www.rfc-editor.org/rfc/rfc6455.html#section-5.2).

These validation gaps are accepted limitations, not guarantees supplied by the
selected dependency stack.
See [RFC 6455 framing and fragmentation](https://www.rfc-editor.org/rfc/rfc6455.html#section-5),
[control frames](https://www.rfc-editor.org/rfc/rfc6455.html#section-5.5), and
[UTF-8 errors](https://www.rfc-editor.org/rfc/rfc6455.html#section-8.1).

### T13. Upgrade accepts extensions and subprotocols that were not requested

**Evidence:** Reproduced against the installed client handshake implementation.

**Trigger:** An otherwise valid 101 response includes an unsolicited
`Sec-WebSocket-Extensions` or `Sec-WebSocket-Protocol` value.

**Impact:** The client reports an open connection despite not implementing the
accepted extension or agreeing to the selected subprotocol. Subsequent input may
be interpreted incorrectly or fail in the application decoder.

**Relevant code:** `websocket_eio.ml`, protocol construction; installed Httpun_ws
`Client_connection.passes_scrutiny` and `connect`.

A probe used nonce `the sample nonce`, a valid 101 response with Upgrade/Connection
headers, and accept value `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`. Adding either
`Sec-WebSocket-Extensions: permessage-deflate` or
`Sec-WebSocket-Protocol: unrequested`, without requesting either, produced
`opened=true` and `failed=false`. The installed scrutiny function omits these
negotiation checks. This behavior conflicts with
[RFC 6455 client requirements](https://www.rfc-editor.org/rfc/rfc6455.html#section-4.1).
Failed-Upgrade cleanup coverage alone does not detect this admission defect.

### T14. Client frame masking does not use the initialized cryptographic RNG

**Evidence:** Source-confirmed RNG selection; repeated initial mask reproduced in
two independent probe processes using the installed client constructor.

**Trigger:** Serialize outgoing client frames through Httpun_ws's default client
connection path.

**Impact:** The mask generation path does not provide the required cryptographic
unpredictability. A secure Upgrade nonce and TLS RNG initialization do not fix the
separate frame-mask generator.

**Relevant code:** `websocket_eio.ml`, `connect` and `send`; installed Httpun_ws
`Client_connection`, `Websocket_connection.random_int32`, and `Serialize`.

The installed client constructor selects `Random.int32 Int32.max_int` for masking.
`Tls_client_eio.initialize_rng` initializes Mirage_crypto_rng, not that generator.
In each of two fresh probe processes, creating a client and serializing its first
Text payload `x` produced mask `149dc8cd`. This demonstrates the probe's repeatable
default sequence, not an observation of production masks or an exploited attack.
Seeding the same non-cryptographic generator would not establish the required
property. This decision accepts the default masking limitation; it does not claim
the serializer satisfies the cryptographic unpredictability requirement in
[RFC 6455 masking](https://www.rfc-editor.org/rfc/rfc6455.html#section-5.3).

### T15. HTTP and Upgrade headers have no explicit memory bounds

**Evidence:** Source-confirmed missing header limits; oversized-header admission
reproduced against the installed HTTP parser.

**Trigger:** Receive a very long response-header line, an unterminated header, or
many individually short fields, including during WebSocket Upgrade. A buffered
driver can retain incomplete input while the parser also accumulates parsed fields.

**Impact:** Body, frame, and message-queue limits do not bound header storage or
unconsumed network input. A peer can consume substantial memory before body or
message delivery, even while remaining within the operation's time budget.

**Relevant code:** `http_eio.ml`, `request_once` and `download_once`;
`websocket_eio.ml`, `start_connection` and protocol construction; installed Httpun
`Config` and `Parse.headers`, and Httpun_ws `Client_handshake.create`.

The HTTP wrappers enforce their response-size limits in body processing. Installed
Httpun configuration provides buffer sizes, but no header-byte or field-count
limits; the WebSocket handshake uses that HTTP parser. A direct HTTP client probe
fed `HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Large: `, followed by 1,048,576 `x`
bytes and `\r\n\r\n`. It consumed all 1,048,625 bytes and entered the response
handler with a 1,048,576-byte header value and no error. This demonstrates parser
admission, not measured production memory growth or a live Upgrade reproduction.

Incremental aggregate-header, line, field-count, and parser-input bounds are not
guaranteed by this decision. A completed-header check, body limit, queue bound, or
timeout does not establish those bounds. Project-owned assembly and queues still
need admission limits; using the selected libraries and drivers does not prove a total parser
memory bound.

### T16. Informational HTTP responses can complete the request prematurely

**Evidence:** Premature response delivery and a subsequent parser assertion
reproduced against the installed HTTP client; source-confirmed wrapper completion
on the first response body's EOF.

**Trigger:** A server sends an informational response such as `103 Early Hints`
before the final response to an HTTP request or artifact download.

**Impact:** The wrapper can settle the request with the informational status and an
empty body instead of waiting for the final response. Parsing the following final
response can also raise an assertion. Retiring resources on the first completion
would preserve the premature result and discard the actual response.

**Relevant code:** `http_eio.ml`, `request_once` and `download_once` response handlers;
installed Httpun `Parse.Reader.response` and `Respd.create`.

A direct `Client_connection` probe registered one GET request with `Connection:
close`, drained its request output, and supplied this response sequence in one read
(escape sequences below denote wire bytes):

```text
HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx
```

The response handler received only status `103` and body EOF with an empty body.
Continuing the same read raised `Assertion failed` in installed `lib/parse.ml`
at line 289, where no request remained in `Awaiting_response` state. The probe
caught that assertion for reporting; it did not demonstrate failure of a live
Runner switch. The current wrapper resolves its result on the first body EOF, and
the dependency transitions the request to `Received_response` for the 103.
Ignoring 103 only in the wrapper callback therefore does not fix the dependency's
request-state transition.

Correct final-response association would require a dependency state-machine repair,
which is outside this decision. Informational-response sequences may still fail or
produce a premature result. Ordinary HTTP success must not be claimed to cover
these sequences. WebSocket 101 remains the library-managed Upgrade boundary. See [RFC 9112 response association](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.2).

### T17. Valid chunk extensions and trailers are rejected

**Evidence:** Reproduced against the installed HTTP client parser; source-confirmed
missing chunk-extension and trailer parsing.

**Trigger:** A complete chunked HTTP response includes a legal chunk extension or
trailer field, including when sent by an otherwise healthy server or intermediary.

**Impact:** A valid response or artifact download can fail with a malformed-response
error. Correct request ownership and success/failure cleanup alone do not make
these responses parse successfully.

**Relevant code:** `http_eio.ml`, HTTP and download body handling; installed Httpun
`Parse.body`, its `Chunked` branch, and `Respd.report_error`.

Direct client probes used one GET request with `Connection: close` and a draining
body handler. Each response began with
`HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n`:

- `1\r\nx\r\n0\r\n\r\n`: all 58 response bytes were consumed, body `x` completed,
  and no error was reported.
- `1;foo=bar\r\nx\r\n0\r\n\r\n`: 48 of 66 response bytes were consumed, the body
  remained empty, and the error handler reported `eol: string`.
- `1\r\nx\r\n0\r\nX-Checksum: ok\r\n\r\n`: 56 of 74 response bytes were consumed,
  body `x` was delivered, and the error handler reported `eol: string`.

Both failing probes also received body EOF when error handling closed the reader;
that callback is not proof of successful framing completion. The installed parser
requires CRLF immediately after the chunk size and an empty line immediately after
the zero-size chunk, so it rejects extensions and nonempty trailers.

Rejection of valid extensions and trailers is accepted. Adding their parsing or
metadata limits is outside this decision. The wrapper must still preserve an
observed parser error when cleanup invokes body EOF; that callback must not
overwrite a known failure with success. See
[RFC 9112 chunked coding](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1).

### T18. Transfer-Encoding lists change framing and allow undecoded success

**Evidence:** Reproduced against the installed HTTP client; source-confirmed missing
transfer-coding validation in both HTTP wrappers.

**Trigger:** A response uses a comma-separated transfer-coding list, equivalent
multiple field lines, or a coding the transport does not support.

**Impact:** Equivalent header forms produce different body bytes and completion
timing. Chunk markers or still-encoded bytes can reach callers as a successful HTTP
body or download. This is not evidence of a production artifact corruption incident.

**Relevant code:** `http_eio.ml`, `request_once` and `download_once`; installed Httpun
`Response.body_length` and `Headers.get_multi`.

`Response.body_length` compares the last complete Transfer-Encoding field value
with `chunked`, without parsing its comma-separated codings. Other values select
close-delimited framing. Neither wrapper validates or decodes the remaining codings
before resolving success on reader EOF.

A direct client probe registered GET `/` with `Connection: close`, closed and
drained the request writer, and continuously drained the response reader. Let `G`
be the 21-byte gzip encoding of `x`, hex
`1f8b08000000000002ffab00008316dc8c01000000`. The wire body was
`15\r\n` + `G` + `\r\n0\r\n\r\n`. After one `read` and `next_read_operation`:

- `HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n` plus that body
  consumed 85 bytes, delivered all chunk markers and `G` unchanged, and did not
  complete until an empty `read_eof`; it then completed without error.
- `HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n`
  plus the same body consumed 104 bytes, delivered only `G`, and completed without
  error before network EOF.

These probes isolate framing selection; T17 concerns parsing after chunked framing
has already been selected. Inconsistent transfer-coding interpretation and
undecoded delivery are accepted limitations. This change does not add an independent
framing selector, transfer decoder, or mandatory rejection of these chains. Artifact
gzip processing and Content-Encoding do not repair this transport limitation. See
[RFC 9112 transfer coding](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.1),
[framing precedence](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3), and
[coding negotiation](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.4).

## Proposal

### Keep the selected protocol stacks

HTTP requests and downloads use `httpun` for protocol state and `httpun-eio` for
Eio driver execution. WebSocket uses `httpun` for HTTP Upgrade and `httpun-ws` for
handshake/frame parsing and serialization. Implement its Eio read/write driver in
`websocket_eio.ml`; do not use `httpun-ws-eio`. Keep the existing TLS authentication
boundary over Eio/Tls_eio and the original hostname.

The custom WebSocket component is the I/O and lifecycle driver, not a replacement
HTTP parser, WebSocket frame parser, or serializer. It feeds bytes into the library,
retains unconsumed input, handles Read/Yield/Close, writes the library's serialized
output, reports actual write progress, and owns shutdown. Build Upgrade requests
through `Httpun_ws.Client_connection` with the required headers and nonce. Remove
the superseded custom protocol engines and the old incorrect pump during
implementation; retain one production path per transport.

The user explicitly rejected using `httpun-ws-eio` after reviewing its integration
constraints. For context, its 0.2.0 client interface requires a Unix stream socket
and does not expose custom request headers; see the
[versioned interface](https://raw.githubusercontent.com/anmonteiro/httpun-ws/0.2.0/eio/httpun_ws_eio.mli).
These are no longer package-adoption prerequisites. Verify the project driver with
the actual authenticated TLS flow and required Upgrade headers instead. This
choice does not reopen T12-T18 as protocol-correctness requirements.

### Give each operation one owner

Each HTTP attempt and WebSocket connection owns its DNS/TCP/TLS setup, flow,
HTTP adapter or WebSocket pump fibers, payload consumers, queues, timers, and
callbacks. Create the owner before setup begins. Pass its switch to `httpun-eio`
and use the WebSocket owner switch for both project pumps. The Runner's
long-lived switch owns the operation owner, rather than every connection resource
directly. Fence further work at termination, close owned resources, join fibers,
and settle the result or terminal notification once. Failed setup must retire even
when no WebSocket handle was returned.

Keep driver/parser exceptions inside this owner and map them to a transport outcome.
Accepted protocol defects may cause failure or imperfect library interpretation;
they do not authorize an exception to escape into the Runner's long-lived switch,
a known error to be overwritten by cleanup EOF, or a resource leak. Preserve the
first observed failure. Publish success only after the library-reported completion
and the wrapper's own validation/cleanup requirements are satisfied. This is not
an independent proof of HTTP framing correctness for T16-T18 inputs.

For HTTP, preserve the 30-second request and 120-second download budgets across
redirects. Retire the previous attempt before the next redirect or retry. Diagnose
EOF using the library's reported response/framing state, bytes received, and owner
stage; distinguish supported completed responses from observed truncation, setup
failure, and stale callbacks without claiming to fix accepted parser behavior.

### Make file delivery an explicit success boundary

Download into an exclusive mode-0600 temporary file beside the destination. Validate
HTTP status, media type, and existing body-size limits; require library completion
without an observed error, successful writes, and checked flush/close. Retire the
network attempt before atomically publishing the completed file. Do not use a
best-effort close as evidence of success.

Failure, cancellation, or publication error removes only that attempt's temporary
after closing it. Preserve any committed destination. Older callbacks must not
write to or remove another attempt's file. Stop progress callbacks at termination.
Keep HTTP response status distinct from artifact publication: 401/403 remain typed
outcomes after cleanup, and non-success status publishes no artifact. This retains
the authorized-request 401 refresh behavior without extending it to signed URLs.
The accepted T18 limitation means these steps alone do not guarantee correct
transfer decoding for every possible response.

### Order WebSocket activation and message delivery

Implement a buffered read pump that retains the unconsumed suffix and appends new
network bytes when the library requests more input. A zero-byte consumption result
with Read means more input may be needed; it is not by itself an error. On Yield,
wait for the library's wakeup without spinning or losing a wakeup. On Close, stop
reading and signal the owner. Report network EOF through the library's EOF API and
preserve any resulting error. Do not retry an unchanged partial buffer in a busy
loop. Use the same driver across Upgrade and WebSocket, preserving bytes already
read beyond the handshake boundary.

Bound the project-owned retained input buffer, initially to 16 KiB, and fail the
connection cleanly if it cannot make progress within that capacity. This may reject
large inputs; it does not bound fields already accumulated inside the HTTP parser
or repair T15. Exercise segmented valid input within this limit.

The write pump follows the library's write operations, handles partial writes, and
reports only bytes actually accepted by the flow. Wait on the library's writer
wakeup for Yield, propagate write errors to the owner, and coordinate read-side,
write-side, and final flow closure. Do not equate serializer shutdown or an empty
write queue with completion of a peer Close exchange.

Serialize payload consumption and fragment-state mutation in wire order using the
library's payload API. Avoid independent frame fibers racing on one fragments
buffer. Do not block the sole driver while waiting for payload bytes that only it
can provide. Bound project-owned in-progress message assembly and completed-message
storage under existing payload limits and a completed queue of at most 8 MiB and
128 messages. These bounds do not establish a bound on dependency parser storage
or validate raw wire lengths affected by T12/T15.

An explicit activation boundary coordinates Runner registration, open notification,
and application delivery. Buffer pre-activation messages in the bounded ordered
queue; publish them only after registration and open. Termination before handoff
fails setup and discards queued messages without publishing an open handle.
Termination after activation produces one terminal notification and no later
message callbacks. Test Upgrade coalesced with Text and with Close/EOF.

### Separate graceful close, abort, and completion

Graceful close rejects new sends, asks `Httpun_ws.Wsd` to serialize an actual Close
with an explicit normal-close code, and allows at most one second for exchange.
For a normal peer Close, respond through the same library API if no Close was sent.
Keep the project writer pump alive long enough to transmit admitted closure output;
`shutdown` alone is not evidence of a Close exchange. On grace expiry, force cleanup
and await owner retirement.

Requesting graceful close is nonblocking for Runner dispatch. Provide a distinct
abort route for actual cancellation, `cancel_scope`, and shutdown, including during
setup and an ongoing grace period. Await completion from a safe owning fiber, never
from the driver callback that must itself finish. Snapshot handle collections before
close/cancel dispatch so callbacks cannot mutate a collection being traversed.

### Bound wrapper output and implement explicit liveness

Define send success as local acceptance, not peer delivery. Bound pending application
output to 8 MiB and 128 frames, including output admitted to the library serializer
and still in flight. Reject overflow before reporting acceptance; never silently
drop accepted data to make room. Release budget on verified writer progress, not
merely when moving an item into Faraday. Couple admission accounting to the project
write pump and the library's actual write-progress reporting. Include in-flight
frame storage until the corresponding output drains; verify accounting for partial
writes and protocol-generated control output.

Bound the control queue to 16 entries plus at most one frame in flight, with
incoming payloads subject to the configured frame bound. Give Ping, Pong, and Close
an opportunity between
application frames while preserving accepted application order and frame integrity.
Terminate through the owner if control admission exceeds that capacity.
A blocked writer must not postpone heartbeat or close deadlines indefinitely.

Keep an explicit public liveness configuration: Disabled or Ping_pong with finite,
strictly positive interval and timeout. The interval starts at activation or the
preceding matching Pong. Only a Pong matching the outstanding probe satisfies its
deadline; start that deadline at probe admission so congestion remains bounded.
Stop timers at termination. Production timing can use the proposed 30-second
interval and 10-second deadline, with short deterministic test settings. This adds
no reconnect, application acknowledgement, or backgrounding policy.

Use the library's masking path as selected. T14 does not require a custom serializer
or a public secure-random capability solely for overriding frame masks. Preserve
appropriate TLS RNG initialization and Upgrade nonce generation; those separate
responsibilities do not establish cryptographic mask unpredictability.

### Keep setup and credential fixes in scope

Apply one overall deadline from DNS through TCP, TLS, and HTTP/Upgrade. T7 uses Apple DNS-SD queries with Eio descriptor-readiness waits and explicit
`DNSServiceRefDeallocate` cleanup, without detached system-thread resolver work.
IPv4 and IPv6 queries run concurrently with a two-second budget per family and
retain at most eight addresses each. Each TCP/TLS candidate gets at most one second
under the enclosing operation deadline. Cancellation tests exercise unresolved
`.local` names and verify prompt owner return and descriptor reclamation. The native
resolver targets macOS/iOS; other platforms fail explicitly and have no blocking
resolver fallback. Short per-family/candidate budgets trade some slow-network
availability for bounded setup; the outer 30/120-second deadlines are unchanged.

Try alternate resolved addresses under that same deadline. Bound candidate delay
and concurrency so a blackholed first address cannot consume the entire budget;
close failed/losing candidates and authenticate the original hostname on each TLS
attempt. DNS exceptions belong to the typed setup error boundary.

Bind bearer credentials to the managed origin using scheme, normalized hostname,
and effective port. Omit bearer credentials and token-refresh behavior for initial
cross-origin signed artifact URLs. Preserve same-origin redirect restrictions and
enforce credential policy at every hop. Confirm deployment authorization separately;
HTTPS alone does not establish trust.

Add opaque attempt IDs and sanitized stage/byte/completion diagnostics. Do not log
tokens, signed queries, response bodies, or arbitrary exception strings. Correlate
the original EOF before claiming a root cause.

## Decision

The user selected `httpun` + `httpun-eio` for HTTP and `httpun` + `httpun-ws`
with a project-owned Eio driver for WebSocket, explicitly excluding `httpun-ws-eio`
and accepting the Httpun-family issues recorded in this document. Implement the T2-T11 project fixes within those stacks and investigate T1.
T12-T18 remain documented accepted limitations. Do not add a custom protocol engine,
compatibility path, or fallback to satisfy the previous stricter acceptance suite.

### Implementation record

- HTTP now uses `Httpun_eio.Client` under a private attempt switch. The owner fences
  callbacks before cancelling and joining the driver, then returns its result.
  First observed errors take precedence over cleanup body EOF. Callback exceptions
  and driver exceptions are contained, while caller cancellation propagates.
- The HTTP socket adapter defers send-side TLS shutdown to the attempt owner.
  During regression testing, completing request output otherwise caused TLS
  `close_notify` while a response was still streaming; the peer then closed and
  the request completed before cancellation. Stalled-body cancellation tests now
  pass. This fixture establishes one mechanism, not the reported deployment EOF's
  root cause. Diagnostics record opaque attempt IDs, status/framing stage, received
  bytes, and retirement outcome without secrets.
- Downloads use attempt-specific temporary files, checked flush/close after driver
  retirement, and atomic rename. Cancellation and failed publication preserve an
  existing destination. Artifact requests enforce initial-origin bearer policy and
  retain authorized 401 retry and typed 403 handling. Gzip signature inspection
  now reads bytes in explicit sequence inside the EOF handler, correcting both
  short-file handling and the follow-up review regression described below.
- The WebSocket Eio driver retains partial input within 16 KiB, handles library
  Read/Yield/Close operations, and drains already-buffered frame payloads without
  waiting for another network read. Payload callbacks mutate fragment state in
  order without spawning independent handlers. Serialized writes report actual
  progress; application admission includes in-flight output and is released only
  after it drains.
- WebSocket activation gates registration/open before message delivery. Graceful
  close emits a library-serialized normal Close with a one-second grace period;
  abort interrupts setup or grace and joins through the owner. A handshake-error
  race was reproduced and fixed by retaining typed 401/403 outcomes before the
  stop signal can overtake the establishment waiter. Liveness uses correlated
  protocol Ping/Pong, with production timing of 30/10 seconds. The obsolete public
  mask-source capability was removed; TLS/nonce RNG initialization remains.
- Shared setup uses the bounded DNS-SD and alternate-address policy described
  above. Native support is included through the existing C translation unit, so no
  production dune changes or new package dependencies were required.
- HTTP/WebSocket regression tests live in `logseq_sync/test/transport_contract.ml`.
  Tests use a separate Python TLS peer and public Runner operations. Native DNS
  cancellation uses real unresolved queries; TCP-stall tests inject delay through
  the public Eio network capability and then connect to the real peer. TLS-stall
  peers observe actual local closure rather than reporting assumed cleanup.
- Source-boundary tests retain centralized TLS setup checks. Obsolete assertions
  requiring the blocking resolver, exact error prose, and absence of all HTTP atomics
  were removed; the HTTP atomic is solely a diagnostic attempt counter.

### Review follow-up: gzip detection and closing during a pending Pong

The follow-up review found two project defects outside the accepted T12-T18
limitations. The user authorized fixing both without changing the selected libraries.

- P1 (fixed): `gzip_signature` read both bytes in a tuple expression, whose
  evaluation order is unspecified. The reviewed build reversed valid `1f 8b`
  signatures and published compressed snapshot bytes without decompression.
  Sequential `let` bindings now read the bytes inside an explicit EOF handler,
  preserving empty and one-byte input behavior.
- P2 (fixed): requesting graceful close left an existing Pong deadline active,
  allowing it to terminate the owner before the one-second Close grace expired.
  The heartbeat fiber now races the close-request signal, which cancels and joins
  its interval/Pong wait and clears pending Pong state. A timeout that resumes
  after closing has started cannot terminate the owner. The Close handshake and
  its own deadline determine termination.
- Nine public Runner regressions were added before the fixes. Seven failed on
  the original behavior: one/two gzip layers, excessive layers, truncated gzip,
  reversed signature bytes, and both pending-Pong close scenarios. Empty and
  one-byte inputs already passed and remain covered. All nine now pass.
- The independent TLS peer leaves Ping unanswered, then either replies to Close
  after 400 ms (beyond the 200 ms Pong timeout) or remains silent for the one-second
  close grace. Tests verify the terminal reason, elapsed grace, exactly one close
  callback, peer-observed retirement, and no heartbeat after Close. Invalid gzip
  cases verify rejection without publishing a decompressed artifact.

### Verification

- The revised suite contains 65 transport cases; the complete sync suite passes
  all 117 tests. Coverage includes streaming segmentation, fragment/control ordering,
  activation/close/cancel, queue admission and budget release, auth retry, origin
  restrictions, failed publication, and DNS/TCP/TLS setup retirement.
- DNS cancellation and alternate-address tests first produced four behavioral
  failures, then passed with the shared setup fix. Upgrade 401 retry separately
  failed before its terminal-result race was fixed. HTTP cancellation and coalesced
  WebSocket control/data tests also exposed and verified driver integration fixes.
- `dune build @all` and `dune runtest` pass. Changed OCaml sources pass
  `ocamlformat --check`; `git diff --check` passes.
- The native bridge passes an arm64 iOS 15-targeted `clang -fsyntax-only -Wall -Wextra`
  check using the installed iPhoneOS SDK. This is a native-source compile check,
  not a full iOS application build or on-device DNS/lifecycle test.
- Checked file writes/flush/close are enforced in code; publication failure and
  interrupted download cleanup are exercised. Disk-full and failing-close OS faults
  were not separately injected. TLS fixture authentication is test-controlled;
  deployed certificate and artifact authorization behavior were not exercised.
- Document validation uses `spec-dev-tool check --all`. The original deployment EOF
  remains unconfirmed, and T12-T18 remain accepted limitations.

### Execution checklist

- [x] Record the selected HTTP and WebSocket stacks and accepted T12-T18 limitations.
- [x] Record the decision to implement the WebSocket Eio driver without `httpun-ws-eio`.
- [x] Verify TLS, headers, Read/Yield/Close, and writer-progress integration with the libraries.
- [x] Reclassify existing tests and reproduce project defects using the selected stacks.
- [x] Replace superseded custom protocol paths with the selected HTTP adapter and owned WebSocket pumps.
- [x] Complete HTTP/file, WebSocket, shared setup, and necessary caller wiring fixes.
- [x] Run affected builds/tests, formatting checks, and document validation.
- [x] Record verified results and remaining deployment evidence before transition.

## Alternatives considered

### Other protocol and driver approaches

- A custom Eio HTTP parser and WebSocket parser/serializer was the previous decision.
  It is superseded by the user's selected stacks and must not remain as a fallback.
- Forking or replacing Httpun to repair T12-T18 is outside this change. Their known
  protocol and memory limitations are accepted, without claiming they are fixed.
- Using `httpun-ws-eio` was considered and explicitly declined by the user. Implement
  one project-owned Eio driver around `httpun-ws` instead. Keeping the old incorrect
  pump as a fallback would preserve the partial-input and lifecycle defects.
- Adding only close calls to the old wrappers would leave setup cancellation,
  activation ordering, file handoff, and admission requirements unresolved.

## Acceptance criteria

### Required project behavior

- T1: Add sanitized attempt/stage evidence and reproduce supported complete-response
  and premature-EOF cases. A supported complete response succeeds after retirement;
  observed truncation or protocol error fails once. The original symptom remains
  unconfirmed unless correlated evidence establishes its cause.
- T2/T3: Exercise success, parser/I/O failure, timeout, cancellation, redirect, and
  retry through actual HTTP drivers. Resources retire before results escape. File
  tests cover partial input, write/flush/close/publication failure, stale callbacks,
  and an existing committed destination. Known error-induced body EOF never commits
  a partial artifact or replaces the error with success. Preserve typed 401/403.
- T4/T5: Split valid Upgrade/frame headers and payloads across reads, including a
  complete frame followed by a partial header. Verify ordered fragmented-message
  assembly, bounded project-owned storage, slow consumers, and no unchanged-buffer
  spin or pump/payload deadlock through the project Eio driver. Cover Read/Yield/Close
  wakeups, partial writes, EOF reporting, and retained-input overflow cleanup.
- T6: Exercise failed Upgrade, typed 401/403, setup cancellation, explicit and peer
  close, peer EOF, driver exception, and blocked writes. Verify actual Close output
  for normal closure, bounded grace, prompt abort during grace, retirement, and one
  terminal notification. Registration/open precede application delivery; immediate
  Text/Close/EOF cannot lose the first message or resurrect a terminal handle.
- T7/T8: Stall DNS, TCP, and TLS separately. Check caller latency and actual resource
  reclamation, typed errors, alternate-address progress within the shared deadline,
  original-host TLS verification, and closure of failed/losing attempts.
- T9: Matching Pongs keep an enabled connection alive; silence and nonmatching Pongs
  produce one bounded terminal outcome. Disabled mode starts no heartbeat. Timers
  stop on closure and invalid configuration returns a dependency error.
- T10: Verify initial artifact destinations and redirects: managed-origin requests
  keep bearer behavior; cross-origin signed URLs receive no bearer or token refresh.
- T11: Stall writer progress and repeatedly send individually valid messages. Assert
  byte/count bounds across wrapper and serializer, reject-before-acceptance behavior,
  budget release on progress, preserved order, and bounded closure under saturation.
- Integration uses `httpun-eio` for HTTP and the project Eio driver around
  `httpun-ws` for WebSocket over authenticated TLS on supported targets. Verify
  required headers, actual write-progress reporting, and shutdown/error semantics.
- Put HTTP/WebSocket tests in the independent `logseq_sync/test/transport_contract.ml`
  module, with public Runner scenarios where applicable. Exercise the actual HTTP adapter and WebSocket pumps
  with owned cleanup, not just mocked completion. Preserve a behavioral failing
  baseline for project defects; run the affected build and test suites after edits.

### Accepted dependency behavior

| Finding | Accepted residual behavior; excluded repair requirement |
| --- | --- |
| T12 | Incomplete frame validity checks, including RSV/masking/control/fragment/UTF-8/Close checks and raw-length narrowing; no complete RFC 6455 validation guarantee. |
| T13 | Unsolicited extensions or subprotocols may be accepted; no newly promised negotiation validation. |
| T14 | Default client masks are not established to be cryptographically unpredictable; no mandatory mask-source override. |
| T15 | No explicit incremental header-line/count/aggregate bound in the parser; bounded wrapper queues do not imply bounded total connection memory. |
| T16 | Informational responses may yield premature results or parser failure; successful final-response association is not guaranteed for these sequences. |
| T17 | Legal chunk extensions/trailers may be rejected; accepting them is not a release gate. |
| T18 | Transfer-coding field forms may select inconsistent framing or deliver undecoded bytes; uniform validation/decoding is not a release gate. |

Keep the recorded probes as evidence or clearly labeled characterization cases.
Tests that require these defects to be repaired are outside the revised acceptance
suite. Do not retain mandatory green assertions for strict frame validation,
cryptographic masks, incremental header bounds, correct 1xx sequencing, legal
extension/trailer acceptance, or transfer-coding normalization. If retaining
characterization tests, record behavior for the chosen dependency version rather
than require it never to improve. Cleanup and exception containment remain required
when a dependency reports or raises an error, including during a known-limit input.
No test result should be described as full HTTP/WebSocket standards conformance.

## Risks

- Accepted T12-T18 limitations remain correctness, interoperability, security, and
  memory risks. Keeping these stacks does not make the reported protocol defects
  harmless or prove they cannot cause EOF-like symptoms in deployment.
- The project WebSocket driver must implement buffering, Read/Yield/Close wakeups,
  partial-write reporting, and cancellation correctly. A custom driver still needs
  regression coverage even though protocol parsing and serialization stay in the
  dependency. Its TLS and Upgrade handoff must preserve already-read bytes.
- Cleanup EOF can race with an error callback. Preserve error precedence and wait
  for owned driver retirement before committing wrapper success. The owner cannot
  independently detect framing defects that the library reports as successful.
- Shutdown promises, writer flush, and WebSocket Close exchange have different
  meanings. Incorrect ordering can drop Close output or deadlock by joining a driver
  from its own callback; queue congestion must fit within close/liveness deadlines.
- Payload ordering, bounded queue admission, and activation can deadlock or lose data
  if a consumer blocks the only driver or publishes messages before registration.
- Resolver cancellation can still return late or retain work unless tested at the
  underlying operation boundary. Address fallback must not multiply the deadline.
- File cleanup must preserve HTTP authentication outcomes and committed destinations.
  The accepted transfer-coding behavior still limits the artifact correctness claim.
- Tests from the superseded custom-parser design cannot establish behavior of the
  selected libraries. The revised suite executes the actual HTTP adapter and
  WebSocket driver; T12-T18 conformance assertions have been removed.

## Consequences

Transport results now have an explicit resource-retirement boundary, and WebSocket
activation, graceful close, and abort have distinct contracts. Callers provide
liveness configuration; frame masking remains library-owned. The project maintains
one WebSocket Eio driver while relying on Httpun-family protocol behavior, including
the accepted T12-T18 limitations. DNS resolution now uses the Apple platform bridge
and bounded setup budgets; supporting another platform requires an explicit resolver
implementation rather than a blocking fallback.

## Questions

### Resolved user decisions and authorization

- The selected HTTP and WebSocket stacks and acceptance of Httpun-family limitations
  are explicit user decisions; no further stack-selection question is pending.
- The user authorized `spec/` changes when resuming implementation. Explicit public
  liveness configuration is implemented. The constructor capability used solely
  for overriding frame masks has been removed without compatibility overloads;
  TLS and Upgrade nonce generation retain their existing RNG initialization.
- The user requested independent HTTP/WebSocket tests and explicitly authorized
  modifying `logseq_sync/test/dune` to register the test module. This is not blanket
  authorization to edit other dune files. No `httpun-ws-eio` dependency
  registration is needed under this decision. Any other production dune edit must
  still follow the repository's explicit-authorization rule.
- The bonsai_flutter OCaml editing restriction remains in effect.

### Remaining deployment evidence

The original reported EOF and deployed artifact authorization requirements remain
unconfirmed. iOS device behavior and OS disk-full/close-failure injection were not
validated in this implementation run; the local verification scope is stated above.
These limits do not reopen the accepted T12-T18 issues or imply an outstanding
stack-selection question. Any future change blocked by a public-spec issue must
follow AGENTS.md and report the concrete issue.
