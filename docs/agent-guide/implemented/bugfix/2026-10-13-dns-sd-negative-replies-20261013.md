# Complete negative DNS-SD answers before the shared dial deadline

## Problem

The Apple TLS transport starts IPv4 and IPv6 DNS-SD queries and waits for both. Zero query flags suppress absent-family negative replies. PR67 changed the previous two-second family waits into a shared 30-second DNS/TCP window, so an IPv4 result can wait for absent IPv6 until no dial budget remains. The zero flag and pair predate PR67 at fixed base b2c32aa71c6d2cac8bee638c01827e42206943ae.

The owner is the TLS transport and Apple DNS-SD query. Public Core events only receive completed results; they cannot execute resolver callbacks or reproduce a missing reply. Regression tests therefore use the existing public Runner.transport/submit execution boundary, without exposing private TLS functions or copying resolver logic.

## Decision

Pass kDNSServiceFlagsReturnIntermediates to DNSServiceGetAddrInfo. The existing NoSuchRecord callback completes an empty family; other errors, cancellation, query deallocation, the shared 30-second DNS/TCP budget and WebSocket ownership retain their existing owners. Apple SDK dns_sd.h documents negative intermediate results, and Apple's [dns-sd GetAddrInfo client](https://github.com/apple-oss-distributions/mDNSResponder/blob/main/Clients/dns-sd.c) uses this flag for -G.

Add one public Runner regression using RFC7050's ipv4only.arpa name, redirecting all TCP candidates to the independent loopback HTTPS peer. First require a nonempty IPv4-only answer from the independent public system resolver; DNS64 or missing IPv4 explicitly fails the fixture precondition instead of producing a false-green regression. Add an unanswered unique .local-name regression preserving the shared deadline and zero dials. Existing dual-stack localhost fallback, DNS/TLS cancellation, phased deadlines and actual single WebSocket owner tests remain in place.

The image fixture validates its just-generated certificate using full-precision Unix.gettimeofday instead of second-truncated Unix.time, avoiding rejection when the validation instant equals not-before. There is no added delay, authentication bypass or trust-store change.

No Dune, spec, mli, dependency, lock or pin changes. The user explicitly authorized repair, testing and a formal PR with “fix it”; this task has no merge or phone-installation permission.

## Alternatives considered

### Reset or shorten the shared deadline

A per-family budget or resetting TCP after DNS would conceal a missing reply and alter the accepted shared budget. Complete negative answers instead.

### Inject a failing reducer completion

That would not reproduce native DNS-SD behavior. Keep the regression at the existing public execution boundary.

### Change production trust or online policy for Simulator tests

Use a Git-external host through the existing Application.For_testing.app_with_service and worker dependency constructors. Inject only a strict temporary loopback certificate authority and synthetic account data. Use the real JournalHost lifecycle and actual WebSocket handshake/Pull exchange; do not fake online state or change production policy/UI.

## Consequences

The public IPv4-only HTTPS regression fails with the original flag, passes with the minimal change, and remains green after formatting. Unanswered DNS still consumes one shared 30-second budget and opens no socket. The complete build/native object and 21 suites / 732 cases pass, including 226 sync cases and existing dual-stack, cancellation, deadline and socket-owner checks.

Actual Mac public Runner HTTPS, cache lease/release/reopen and Storage commit publish three PNGs with strict certificate validation. The standard fixed object passes isolated Simulator local-image display, three preview colors, close/reopen, Detail and Back (34.130s). A separate public-service integration host passes actual Simulator three-image HTTPS download and preview (35.534s); server TLS1.3 logs show three asset GET 200 responses of 1716 bytes each and a real WebSocket/Pull exchange. This integration host is not the standard production package. Simulator reproduction of the original DNS defect is not claimed; the causal RED/GREEN reproduction is Mac public Runner.

The first external UI oracle used a nonexistent Done navigation button; it was corrected to the existing close identifier. The initial download fixture lacked production lifecycle wiring and stayed offline after a stale token challenge. Switching the external fixture to real JournalHost and serving the existing WebSocket protocol resolved that setup failure without product changes.

System-resolver regression cases require Apple DNS-SD and public DNS availability. DNS64 may synthesize AAAA for ipv4only.arpa; the regression now rejects that environment explicitly before executing the tested transport. The current proxy resolver synthesizes IPv4 even for .invalid, so the unanswered-name deadline test uses an unregistered .local name. No real graph, account credentials, Keychain or phone is used. Repository-wide decision validation retains the same three historical failures as main; this document validates independently.
