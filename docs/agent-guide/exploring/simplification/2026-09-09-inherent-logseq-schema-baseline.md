# Inherent Logseq Schema Baseline

## Problem

Worker startup carries a `compatibility_profile` value even though the repository
supports exactly one profile and no production owner branches on it:

- `logseq_db_worker/contract/config.mli` exposes the singleton
  `Logseq_65_33_or_newer` type, stores it in `Config.t`, and requires it in
  `Config.create`.
- `logseq_db_worker/contract/config.ml` serializes that value as the constant
  `"logseq-65.33-or-newer"`, requires the same constant during strict decoding,
  and reconstructs the only constructor. The stored record field is never read
  after construction.
- `flutter/lib/application_host_adapter.dart` independently emits the same
  constant in every startup envelope. There is no Flutter setting or runtime
  choice that can produce another value.
- Production startup consumers read the application support directory, managed
  sync target, response budget, and page size. Schema inspection and admission
  remain owned by the worker's admission path and already enforce the 65.33-or-
  newer rule without consulting `Config.compatibility_profile`.
- OCaml application, worker, protocol, and integration tests repeat the only
  constructor or JSON field. Protocol fixtures also contain the constant because
  strict config decoding currently requires it.

The field therefore presents a configurable capability that does not exist. It
duplicates the worker's fixed schema policy across the Dart encoder, OCaml
contract, call sites, and tests without carrying a decision into production.
This is accidental configuration complexity rather than compatibility support:
repository policy explicitly does not retain obsolete wire paths, fallbacks, or
migrations.

The startup JSON is nevertheless a public worker contract, and an unknown
out-of-tree encoder may still send the required field. Removing it must be an
explicit atomic contract cutover rather than an unreviewed local cleanup.

## Proposal

Make support for Logseq schema 65.33 or newer an inherent invariant of the
worker admission owner instead of a startup parameter.

Remove `compatibility_profile`, `Logseq_65_33_or_newer`, the field in `Config.t`,
and the `~compatibility_profile` argument from `Config.create`. Remove
`compatibilityProfile` from the strict startup JSON field set, OCaml encoder and
decoder, and `LogseqDbWorkerStartupEnvelope.encode`. Update every in-repository
constructor, test envelope, fixture, and contract assertion in the same cutover.
Do not accept the removed field as an optional legacy input and do not add a
replacement version flag, alias, decoder fallback, or migration.

Keep the actual schema behavior unchanged. The worker must continue to inspect
the opened graph through its existing admission path, accept schema 65.33 or
newer, reject unsupported or malformed schemas with the same owned error
semantics, and expose the same graph lifecycle and application behavior. The
proposal changes only how that fixed policy is represented at startup; it does
not weaken schema validation or move it into Dart.

The managed-sync target remains a named `Config.target`. The implemented
`Retain Only App-Used Worker Targets` decision deliberately retained that
production boundary, and its `base_url` carries real startup data. Response
budget, default page size, application support directory, and target validation
also remain because each influences production behavior.

Expected dependent cleanup includes:

- `logseq_db_worker/contract/config.ml` and `.mli`;
- the Flutter startup encoder in
  `flutter/lib/application_host_adapter.dart`;
- OCaml startup constructors in `app/`, worker tests, overlay/application tests,
  and managed-sync E2E support;
- strict startup JSON expectations and fixtures that currently contain
  `compatibilityProfile`; and
- source-boundary or documentation assertions that describe the removed
  configuration surface.

This should be a net deletion with one schema-policy owner. It requires no Dune
change, no `spec/` OCaml change, and no change in `bonsai_flutter`.

## Alternatives considered

### Retain the singleton as an explicit capability declaration

This is the strongest reason to retain the current design. A required wire
field makes the schema assumption visible to external encoders and leaves room
for future profiles. Today it provides no negotiation or dispatch: both sides
hard-code one string, the worker stores but never reads the decoded value, and
admission already owns the real rule. A future incompatible schema policy should
be introduced with a decision and real behavior rather than represented by a
permanently singleton option.

### Keep the JSON field but remove the OCaml type and record field

Validating a constant and then discarding it would preserve the out-of-tree wire
shape but leave the duplicated Dart/OCaml contract and strict-field obligation.
That reduces less complexity and becomes a compatibility layer for a value that
never selected behavior.

### Replace the profile with a numeric schema version

A number would imply that callers select or negotiate the worker's admission
policy. No such product behavior exists, and adding it is a feature or
architecture decision rather than a behavior-preserving simplification.

### Collapse the singleton managed-sync target at the same time

`Managed_sync` carries the real base URL and records the application-to-worker
startup boundary retained by an implemented architecture decision. Combining
that separate contract question would broaden this proposal without being
needed to remove the schema-profile duplication.

## Acceptance criteria

- `Config.t`, `Config.create`, and the public config interface contain no
  compatibility-profile type, constructor, field, or argument.
- The canonical startup JSON contains exactly the retained application support
  directory, managed-sync target, response budget, and default page size; it
  neither emits nor accepts `compatibilityProfile`.
- The Dart host and OCaml decoder switch atomically. No optional legacy field,
  fallback decoder, compatibility alias, migration, or replacement profile flag
  remains.
- Schema admission still accepts supported Logseq 65.33-or-newer graphs and
  rejects unsupported schemas through the existing worker-owned inspection and
  error path.
- Managed-sync startup, warm graph restoration, graph selection, encrypted
  bootstrap, mutations, and sync lifecycle remain unchanged.
- All in-repository constructor calls, tests, fixtures, and current contract
  documentation stop carrying the removed value. Historical implemented
  decision documents remain historical evidence unless their current-state
  summaries require a focused correction.
- No Dune file, OCaml file under `spec/`, or `bonsai_flutter` source file changes.
- Focused config/protocol/admission and startup tests pass, followed by
  `dune build @all`, `dune runtest`, Flutter host-adapter tests,
  `flutter analyze`, `git diff --check`, and `spec-dev-tool check --all`.

## Risks

- The config package and startup JSON are public surfaces. Unknown out-of-tree
  callers must remove the field in the same release; the repository intentionally
  provides no compatibility decoder.
- Accidentally deleting the fixed admission rule together with its redundant
  configuration marker would weaken storage safety. Verification must exercise
  supported, older, malformed, and missing-schema observations at the actual
  admission boundary.
- Strict JSON field validation means a partial OCaml/Dart rollout will fail at
  startup. The change must be atomic across both owners and their fixtures.

## Questions

- Should the worker treat Logseq 65.33-or-newer support as an inherent admission
  invariant and delete the singleton `compatibilityProfile` startup contract in
  one atomic cutover?
