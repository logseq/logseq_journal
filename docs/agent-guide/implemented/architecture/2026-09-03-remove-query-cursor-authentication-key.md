# Remove Query Cursor Authentication Key

## Problem

`logseq_overlay_db.Database.dependencies` requires callers to inject a
`cursor_authentication_key`. The production Bonsai service reads 32 random bytes
from `/dev/urandom`, the database copies and retains those bytes, and
`Query_cursor` uses them as the HMAC-SHA256 key for journal and structure
continuation cursors.

The MAC covers the cursor namespace, request shape, projection revision, and
offset. It proves that a cursor was issued by the current Worker process and
therefore prevents a protocol client from constructing another otherwise valid
offset. A new process key also invalidates every cursor issued before a Worker
restart.

This authentication does not protect an authorization boundary. The retained
App is the production protocol client, it can already enumerate every result by
following valid continuation cursors, and choosing another offset can only skip,
repeat, or exhaust results that the same query is allowed to return. The key is
not an account secret, graph-encryption key, storage credential, or authority to
open a graph. The App treats cursors as opaque values and only returns them to
the Worker that produced them.

The authentication requirement consequently adds an entropy source and a
security-named dependency to the overlay database without protecting additional
data or operations. Tests and benchmarks must supply fixed placeholder keys,
`Types.dependencies_error` carries an error dedicated to this one dependency,
and the public database specification promises authentication even though the
repository has no threat model that requires it.

Worker-generation and request-shape bindings are also redundant for the retained
App. On a Worker generation change the App clears its change cursor and
rehydrates current interests from `cursor = None`. The continuation value is not
persisted or shared independently of the App state that owns it. Using one
request's cursor with another request under the same projection can only select
the same numeric position in that other result; this decision treats that as a
caller mistake rather than a database validation concern.

Projection binding remains useful correctness policy. Journal-index and
structure changes refetch affected lists from their first window, but an older
continuation can still race with the changed projection before the App finishes
rehydration. Rejecting a cursor whose projection differs from the captured
snapshot prevents that race from turning an offset into a skipped, repeated, or
misplaced page.

The only cursor state required by the retained contract is therefore the
projection revision and a bounded non-negative offset. The offset bound is
10,000 so a constructed cursor cannot drive the children read path into an
unbounded `Hashtbl` or heap allocation.

This decision supersedes the authentication, Worker-generation, and
request-shape cursor portions of
`docs/agent-guide/implemented/architecture/2026-09-01-logseq-overlay-db-package.md`.
It retains projection-bound pagination, bounded reads, revision scopes, and the
App/Worker protocol boundary.

## Proposal

Remove query-cursor authentication and the injected key in one direct cutover:

1. Remove `cursor_authentication_key` from the private database dependency
   record, `Database.dependencies`, its public specification, and every
   production, test, tool, and benchmark constructor call.
2. Remove `Types.Empty_cursor_authentication_key` and the now-obsolete key
   validation and copy.
3. Remove the Bonsai service's `/dev/urandom` `random_key` helper. Overlay
   construction must no longer perform or require cursor-related entropy I/O.
4. Reduce `Query_cursor` to one deterministic versioned payload,
   `cursor:v2:<projection>:<offset>`. It must contain no key, MAC, digest, Worker
   generation, namespace, parent UUID, page UUID, or tree depth.
5. Accept an offset only when it is between zero and 10,000 inclusive, and accept
   a page limit only when it is between one and the existing Worker protocol
   maximum of 200 inclusive. Enforce both limits at the public database boundary,
   not only in the App. Keep parsing fail-closed for malformed versions, a
   projection different from the captured snapshot, out-of-range offsets or page
   limits, and arithmetic overflow. Validation must finish before any bound,
   capacity, allocation, or traversal uses either value.
6. Update the public `Database` documentation to describe the cursor only as an
   opaque projection-bound continuation offset. Remove authentication,
   Worker-generation-bound, and request-shape-bound promises.
7. Replace authentication and binding tests with contract tests for valid
   pagination, malformed cursors, cross-projection use, offsets below zero and
   above 10,000, the exact 10,000 boundary, page limits below one and above 200,
   and checked offset arithmetic. App/runtime tests must continue to prove that
   Worker-generation changes restart affected reads without a continuation.

If a successful page would require a subsequent cursor whose offset exceeds
10,000 while more items remain, the pagination operation must return
`Types.Read_limit_exceeded`. It must not return `next_cursor = None`, which would
falsely claim the list ended, or emit a continuation that the next request must
reject. This intentionally caps traversal of one logical list through this API.

The new cursor format must use a new version and reject old authenticated cursor
strings. Do not add a legacy decoder, optional key, fallback MAC path, migration,
deprecated constructor overload, or secondary scoped-cursor representation.

The production corpus is `logseq_overlay_db/lib` and `spec`, the
`logseq_db_worker` contract, Effect Runner and Bonsai service, and the App runtime
that round-trips protocol cursors. Tests, fixtures, benchmarks, and tools are
non-production consumers and remain in cleanup scope when they construct overlay
dependencies or assert cursor behavior. `_build`, package-manager output, and
vendored dependencies are excluded as edit targets. The existing `digestif`
dependency is not removable as part of this decision because overlay and other
packages use it for unrelated checksums, fingerprints, and E2EE behavior.

The supported production consumer for this decision is the in-repository App
through the Worker protocol. The packages remain public build artifacts, but an
unknown out-of-tree caller is not a compatibility constraint for cursor
authentication, Worker-generation binding, request-shape binding, or the old
wire format.

## Decision

Adopt the bounded projection-plus-offset cursor in one direct cutover. Remove the
cursor authentication key, MAC, entropy I/O, Worker generation, namespace, and
request-shape fields. Use only `cursor:v2:<projection>:<offset>`, reject every
other format, and enforce offsets from zero through 10,000 plus page limits from
one through 200 at the public database boundary.

Keep projection validation because it prevents an in-flight continuation from
crossing a logical projection change. Permit request-shape reuse as the same
numeric offset within one projection. Return `Types.Read_limit_exceeded` when a
non-terminal page would require a continuation above 10,000.

## Alternatives considered

### Retain HMAC authentication

Rejected. It preserves a documented property, but the property protects no
authorization or confidentiality boundary in the supported App/Worker topology.
Keeping it forces every database constructor and fixture to participate in an
otherwise irrelevant secret lifecycle.

### Generate the authentication key inside `logseq_overlay_db`

Rejected. This hides the constructor argument but preserves the same unnecessary
concept and moves platform entropy I/O into a reusable data-plane package. It
also makes deterministic construction and failure injection less direct.

### Use the public generation token as an HMAC key

Rejected. The generation is exposed by graph information, so it cannot provide
authentication. Retaining it as an ordinary cursor field would duplicate the
App's Worker-generation rehydration lifecycle. Projection remains because it
addresses logical-list races within one open Worker.

### Retain Worker-generation and request-shape bindings

Rejected. These bindings can diagnose a caller mistake, but the retained App
already restarts after Worker-generation changes and owns each continuation with
its request state. They would preserve most of `Query_cursor`'s encoding and
validation concepts after the security rationale has been removed. Projection
binding is retained separately because it closes a same-Worker logical-change
race.

### Reduce cursors to an unbounded offset

Rejected. Once authentication is removed, a protocol client can construct any
representable offset. The children read path sizes intermediate structures from
`offset + limit + local_count`, so arithmetic checks alone do not prevent a very
large but representable allocation. The 10,000 bound makes that resource policy
explicit.

### Reduce cursors to a bounded offset without projection

Rejected. App rehydration normally restarts changed lists, but an in-flight
continuation can reach a newer captured snapshot before rehydration completes.
Keeping the projection revision rejects that race without retaining a secret,
Worker identity, or request-shape policy.

### Replace offset pagination with keyset pagination

Not selected. Keyset pagination could use journal days or block ordering keys
instead of a numeric offset, but it changes list continuation semantics and
requires query-specific cursor payloads. This decision removes unnecessary
cursor policy without redesigning the underlying pagination algorithm.

### Preserve the old cursor decoder during rollout

Rejected by repository policy. Cursor values are process-local continuations,
the App does not persist them across launches, and the repository explicitly
removes obsolete paths instead of adding compatibility layers.

## Acceptance criteria

- No active production, specification, test, benchmark, or tool source refers to
  `cursor_authentication_key`, `Empty_cursor_authentication_key`, cursor HMACs,
  or the cursor-only `/dev/urandom` helper.
- `Database.dependencies` fixes only the retained clocks and limits and has no
  cursor secret or cursor-specific validation error.
- Valid journal, children, and page-tree pagination returns the same ordered
  items and continuation behavior as before when the projection is unchanged
  and the next offset remains within 10,000.
- Malformed, negative, above-10,000, and arithmetically overflowing offsets, plus
  page limits outside 1 through 200, return `Types.Invalid_read_request` without
  allocating or traversing from an invalid bound.
- Cursor creation and parsing depend only on the format version, projection, and
  offset; no secret, Worker generation, or request identity is passed to
  `Query_cursor`.
- A cursor from another projection is rejected, including a continuation that
  races with a logical change in the same Worker.
- A page that has more items but would require a subsequent offset above 10,000
  returns `Types.Read_limit_exceeded`; it never reports a false end of list or
  emits an unusable continuation.
- The public specification no longer promises cursor authentication, Worker
  generation binding, or request-shape binding. It documents projection binding
  and the 10,000 traversal bound.
- App/runtime tests prove that Worker-generation changes restart affected reads
  from `cursor = None`.
- Reusing a cursor with another request shape under the same projection is not
  required to fail and is interpreted as the same bounded numeric offset.
- Old authenticated cursor strings are rejected; no compatibility decoder or
  alternate constructor remains.
- No UI behavior or visual structure changes, so `docs/ux-guidelines.md` requires
  no additional UI work.
- Focused overlay read and Worker protocol tests pass, followed by
  `dune runtest logseq_overlay_db/test`, `dune runtest logseq_db_worker/test`,
  `dune build @all`, `dune build @fmt`, `git diff --check`, and
  `spec-dev-tool check --all`.

## Risks

- Any client that knows the current public projection can construct an offset
  cursor up to 10,000. This capability is intentionally accepted because it
  grants no additional graph authority; offset, page-limit, outbox-capacity, and
  arithmetic bounds prevent it from requesting an unbounded pagination
  allocation.
- The public `logseq_overlay_db` package currently documents authentication.
  Out-of-tree consumers that treat unforgeability as a security property will no
  longer have that guarantee and must not use a continuation cursor as an
  authorization token.
- A cursor reused with another request shape under the same projection is no
  longer rejected and is interpreted as the same numeric offset in that list.
  Correctness depends on the App continuing to associate a continuation with its
  owning request.
- Projection revisions restart at zero when a database is reopened, so projection
  alone does not identify a Worker generation. The App must continue to clear
  continuations through its existing generation-change rehydration path.
- One logical list cannot be traversed beyond the 10,000 continuation bound. A
  graph shape that exceeds this product limit receives `Read_limit_exceeded`
  instead of a false terminal page.
- Changing the cursor wire version invalidates in-flight continuations during a
  Worker replacement. This is consistent with the required generation-change
  restart and has no compatibility decoder.
- An out-of-tree consumer that relied on authentication, Worker-generation or
  cross-query rejection, unbounded traversal, or the old wire format must update
  in the same cutover.

## Consequences

`Database.dependencies` now carries only the retained clocks and limits, and
overlay construction performs no cursor-related entropy I/O. Query cursors are
deterministic v2 payloads containing only projection and bounded offset, so old
authenticated values fail closed and same-projection offsets can be reused across
request shapes.

Journal, children, and page-tree reads reject invalid page limits before using
them and reject malformed, stale, negative, oversized, or overflowing cursor
inputs before allocation or traversal. Traversal may emit an exact 10,000
continuation, but a later non-terminal page that would exceed the bound fails with
`Read_limit_exceeded`. The App continues to restart change pulls without a cursor
when the Worker generation changes.

Implementation completed on 2026-09-03. The focused overlay read, full overlay,
Worker protocol, and App runtime locality suites passed, followed by
`dune build @all`, `dune build @fmt`, `git diff --check`, and
`spec-dev-tool check --all`.

## Questions

None. The user explicitly classified cursor authentication as over-defensive and
selected the bounded projection-plus-offset design. The cursor retains the
projection revision, an offset from zero through 10,000, and the input checks
required to parse and use both safely; authentication, Worker generation, and
request shape are removed. Implementation was a separate step requiring explicit
authorization to update the protected `.mli` specification files; the user's
implementation request supplied that authorization.
