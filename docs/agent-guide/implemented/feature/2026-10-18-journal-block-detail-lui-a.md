# Journal Block Detail LUI A

## Problem

Detail flattens every loaded descendant but caps both native row layout and typography at depth two.
The selected A design needs modest indentation from true depth, readable body text, and more space between primary branches without removing content or interactions.

## Decision

Use existing LUI columns in OCaml for Detail row layout, including bounded shallow indentation and depth-dependent paragraph spacing.
Keep the existing Journal attributed-text leaf because locked LUI 4fdb913 Apple text and heading render verbatim strings and do not consume attributed child runs.
Adjust the existing Swift DetailText typography to a prominent root, semibold primary children, and system-scaled body text at every deeper level.
This uses LUI layout with the existing attributed leaf; it is not an all-LUI rich-text migration.
Do not add Swift components or change public interfaces, spec files, Dune files, locks, navigation, composer, loading, task state, tags, properties, links, references, media, or owner traversal.
Use semantic primary text color and existing ScaledMetric behavior for theme, contrast, and Dynamic Type support.

## Alternatives considered

### Plain LUI text or per-run row children

Rejected because plain text drops inline styles and links, and row children break continuous wrapping and selection.

### Extend the LUI rich-text API

Deferred pending explicit authorization if a completely built-in LUI text leaf is required.
It would require an attributed-run contract and Apple implementation, corresponding protocol/schema parity, and a Journal dependency update.
The present row and typography change does not require those protected changes.

## Acceptance criteria

- Root typography is prominent; depth one is semibold; depth two through nine retain one readable body tier.
- Existing LUI columns own indentation and spacing; the native detail-row component is not mounted.
- True depth remains meaningful through ten levels, with at most 56 points of inset and no bullets, numbering, cards, guide lines, or parent labels.
- Synthetic mounted composition covers ten levels, long multilingual text, rich title runs, metadata, properties, and existing interaction tests.
- Runtime screenshots cover light/dark, contrast, Dynamic Type, loading, and back navigation when coordinated build/Simulator resources are available.
- No private graph is used, no Simulator is created, and the HTTP task retains device and build priority.

## Risks

- LUI integer padding does not scale with Dynamic Type; text uses the existing system scaling and the inset is bounded to preserve width.
- A fully built-in LUI rich-text leaf remains outside this change's approved interface scope.
- Runtime appearance cannot be claimed from wire tests; screenshot acceptance must be reported separately.

## Questions

- None for this scoped implementation: the selected A design and reuse of existing components are authorized by the delegated request.
- A future pure LUI attributed-text migration requires a separate approval of its precise public contract and lock changes.

## Consequences

LUI owns Detail row layout and true-depth spacing while the existing native attributed leaf remains explicit.
No public interface, spec, Dune file, dependency lock, or new production Swift component changed.
Normal-size root/primary/body typography is 28 bold, 19 semibold, and 17 regular, scaled with the existing system metrics.
All deeper body levels retain primary semantic text color and the same readable size.

## Implementation evidence

The task's isolated branch is codex/block-detail-lui-a-20261018, based on main 21dbe01.
Implementation commit ec5b992 passed the locked dependency preflight, 51 mounted semantics scenarios, 120 Application regressions, and the source boundary check.
The new mounted layout test failed for the old native row owner before the LUI column implementation passed.
An independent read-only reviewer found no evidence-backed code issues.
The production Swift sources compiled for iOS Simulator in an isolated native fixture and passed strict signature verification.
The existing Journal Scroll Top Synthetic 20261016 Simulator was reused; no Simulator was created and no private graph was read.
Raw screenshots cover light, dark, high contrast, accessibility3, rich text, resolved synthetic references, multiple metadata fields, long text, ten levels, and loading.
Native accessibility Scroll Down reached the complete tenth-level body at accessibility3; native Back was clicked successfully from loading and deep scrolled states.
All temporary evidence, generated fixture sources, native manifests, raw screenshots and review reports are outside the repository in the task evidence directory.

The native fixture applies public OCaml patches through the production extension registry and uses the existing production icon table.
Its resolved reference example uses the public Title.render lookup API; reference resolution and interactions also retain their mounted regression coverage.
The fixture links stubs and does not start the full Application runtime, worker, graph, or phone session; it is native view evidence, not iOS ABI or full runtime acceptance.
The full documentation check still reports three pre-existing invalid historical documents; this decision document passes independently.
No merge, PR publication, or phone installation was performed.


## Initial scoped runtime attempt

On 2026-10-18 the user explicitly allowed the existing Swift amount and relaxed the all-LUI requirement.
The accepted scope remains LUI layout plus the existing Swift attributed leaf, including its necessary typography adjustment.
No LUI API, pin, schema, spec, Dune file, or additional production Swift component or responsibility was added.

Current-source native production at 88b263d succeeded with runtime and mldoc retained.
The maintained experimental Simulator importer built and strictly verified the existing offline acceptance host with that source-bound object.
App.swift was replaced by the existing warm-start acceptance entry; every other production Swift source was copied unchanged.
This is a complete Application/worker acceptance host, not an unchanged production App, and cross_abi_validated remains false.

The host started and its native graph picker displayed the synthetic graph, but did not reach Timeline or Detail.
The existing suspended-auth mode stayed at Loading journal; its existing immediate-auth-failure mode reported ID token is unavailable.
A separate synthetic plaintext graph had the same admission failure.
The copied SQLite database passed quick_check and its public mirror inspection returned Available when run outside the agent filesystem sandbox.
The startup root cause was not established, and production startup/authentication behavior was not changed for this UI task.
Full Application Detail URL/reference/media, composer, and route-return acceptance remains blocked at that earlier boundary.

A separate component-level interaction check clicked Open sample in the existing production attributed leaf and observed example.com in Safari's native address field.
The fixture retained its rich content and scroll position after returning.
Resolved UUID reference labels retain the existing plain-text, non-navigation behavior; no new reference action was introduced.
New build manifests, original runtime failure screenshots, observations, fixture data, and URL activation screenshots are in the external full-runtime evidence directory.
No sufficient existing semantics/Application tests were repeated, and the existing independent source/visual review remains applicable to unchanged implementation bytes.

## Completed synthetic Application interaction follow-up

The initial failed attempt above is retained as historical evidence, not the final acceptance status.
The repository warm-start fixture documentation requires a quiescent preparation connection and complete SQLite database/WAL/SHM transfer.
Following that procedure recovered local graph admission; quick_check and source/copy hashes passed.
This observation does not uniquely establish the cause of every earlier startup failure.

Public Application/worker traces also exposed an ordering race: Graph_open starts work, a later unauthenticated manager transition retires it, and a subsequent authenticated manager transition alone does not restart it without another Graph_open.
Production startup/authentication behavior was not changed in this UI branch.
An isolated fixture checkout instead uses the existing Application.For_testing.app_with_service entry and the normal public Reconcile_authenticated_user command for fixed synthetic user-1.
This test entry requires JOURNAL_DETAIL_SYNTHETIC_TEST=1, does not forge worker snapshots, and supplies no network token or real account data.
Two lightweight public host prerequisite cases failed without synthetic admission and passed with it, including delayed and indefinitely pending native identity responses.
Their presentation-request trace is separate from the native UI observations below.

The maintained native producer run-75pevfj5 and Simulator run-bz9azgk5 built and strictly verified this isolated host from ee581f1.
Only the copied OCaml native entry changes; Swift App.swift uses the existing warm-start acceptance entry, with every other production Swift source unchanged.
No protected interface, spec, Dune file, lock, production authentication, or new Swift component changed.
The manifest remains experimental-host-restamp with cross_abi_validated=false and runtime_acceptance=false; the following is manual interaction acceptance, not automatic ABI certification.

Native CUA observations in the complete Application/worker host verified:

- Timeline renders synthetic data and opens the root Detail with ten expanded levels, rich runs, and resolved reference labels.
- Clicking the Detail URL opens Safari with native Address example.com; OS return restores the same Detail content.
- Detail Capture composer saves a synthetic child at depth one; native Back shows that child on Timeline.
- The repository's public synthetic image generator populates cached red/blue/green assets through its disposable loopback transport; red and blue selections open the corresponding native preview, and Close restores the same Detail and media.
- Dark appearance and accessibility3 wrap the root naturally; native accessibility Scroll Down reaches the complete tenth-level body with the same deeper size and primary semantic color. Back from that position returns Timeline.

Nine new raw runtime screenshots and an independent read-only review found no evidence-backed visual or scope issues.
Gallery paging was attempted without an observable page change and remains unverified; ordinary drag/wheel scrolling was not confirmed, while native accessibility scrolling was.
Photo saving, sharing, and zoom were not exercised in this follow-up.
Full Application task/metadata mutations were not exercised; existing mounted regressions and component visual coverage remain applicable to unchanged implementation bytes.
Production authentication and full cross-target iOS ABI remain outside this synthetic-host acceptance.
All three owned fixture processes stopped and preparation connections closed; the HTTP task's resource window was released.
No iPhone, private graph, new Simulator, shared switch, push, PR, or merge was involved.
