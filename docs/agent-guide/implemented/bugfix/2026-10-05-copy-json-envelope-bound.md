# Bound Copy by its serialized clipboard request

## Problem

PR47 review 4182772282 reports that Copy's 256 KiB raw text bound can emit Copied for text whose JSON wrapper/escaping makes Journal_platform.copy_text_request exceed its 256 KiB payload limit. Inspecting the two public boundaries confirms their limits differ. Reproduce with public Copy.Start/Completed events and valid graph responses, then check Copied/Failed effects against the actual public platform encoder. The production owner for admitting a successful Copy result is Journal_graph_runtime.Copy; platform encoding exposes the relevant serialized bound.

## Decision

Before emitting Copied after the final graph-version check, validate the assembled bounded text through Journal_platform.copy_text_request. Emit the existing too-large Copy failure if the packet cannot be encoded. Preserve early raw size/UTF-8 bounds, complete traversal, cancellation and immutable version checks. Reuse the real encoder to account exactly for wrapper, escaping and UTF-8 without duplicating JSON logic, new APIs, per-fragment serialization or quadratic accumulation.

Add only public pure Copy regression cases: maximum raw ASCII; escaped quotes/backslashes/newlines and control bytes that exceed the serialized bound; exact encodable ASCII/escaped boundaries; and descendant formatting overhead. Do not add integration, transport or UI duplicates for this reducer-owned defect. Existing actual clipboard UI acceptance remains the requested feature acceptance, not a duplicate regression for the size bug.

## Alternatives considered

### Conservatively shrink the raw bound

Rejected: wastes valid capacity for ordinary text and still requires reasoning about every escape.

### Increase the platform limit

Rejected: changes an unrelated shared wire contract and Swift decoder; the existing payload limit is intentional.

## Acceptance criteria

- The public owner regression is RED before the change and GREEN after it.
- Every Copied regression text is accepted unchanged by the existing public clipboard encoder; over-bound serialized payloads emit Failed without Copied.
- Full tests/build and changed-file formatting pass, no Dune/spec or shared LUI changes.

## Consequences

The public regression failed before the repair: a 256 KiB raw ASCII root emitted Copied despite its public clipboard encoder rejecting the JSON payload. After the change, all 11 root/descendant boundary examples pass. Exact-fit ASCII and escaped-text payloads remain copyable unchanged; wrapper, quote, backslash, newline, control-byte and descendant overhead can no longer produce an undeliverable Copied effect. The seven Copy subtree cases and full 21-suite, 561-case serial test run pass, as do build/install/native-object targets and changed-file formatting. No integration/UI duplicate was added for this reducer-owned regression.

The final guard reuses the real encoder once after the immutable graph-version check. Application delivery still independently validates its packet. Actual native Copy/Paste acceptance is a separate requested feature check and is not implied by these pure regressions.

## Risks

- Successful Copy performs one extra bounded serialization at completion; this is linear in at most 256 KiB, and application delivery already independently revalidates.
- Actual native clipboard UI and unrelated paging acceptance must not be inferred from these pure regressions.

## Questions

None: the user authorized bounded investigation and minimum confirmed fixes to this review before any merge.
