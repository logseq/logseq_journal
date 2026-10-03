# Portable Journal PR CI

## Problem

The selected Journal changes require the unmerged companion LUI FileImage fit/fill API. Journal currently has no GitHub Actions workflow, and main-only LUI pins cannot compile this branch. Local checkout overlays are not a portable review or CI dependency plan.

## Proposal

Publish the companion LUI draft first and reference its exact published commit in both Journal opam manifests. Keep merged dependencies on their main branches. Add one Ubuntu OCaml workflow that resolves each declared locked Git pin once into isolated checkouts, records actual SHAs, pins these local CI sources without recursive metadata overrides, installs declared locked dependencies, and runs the full build/native object and test suite. Publish logs and the dependency manifest as CI artifacts, never source files. Refresh the LUI pin to main when the companion PR is merged before Journal merge.

## Decision

Publish LUI draft PR https://github.com/logseq/lui/pull/95 and declare its exact head 7fec999410f015d88d2279632fa805ebac89cf7d in Journal's opam and locked overlay. Add the hosted CI workflow and resolve all declared Git dependency sources once per run, then pin those exact checkouts after cache restoration. Keep main references for already-merged APIs, including ocaml-signal in LUI. The published PR dependency is temporary until LUI merges; replace it with main and rerun Journal CI before merging Journal.

## Alternatives considered

### Mac-specific OCAMLPATH overlays

These cannot be resolved by a fresh contributor or CI runner.

### Build against LUI main immediately

The fit/fill API is not present in main yet; a declared cross-PR dependency is required.

## Acceptance criteria

- Both draft PRs contain only intended source, regression and decision/config files.
- The Journal opam pin references a published LUI commit and CI records resolved dependency SHAs.
- Remote checks are followed to terminal status; failures are identified and fixed within scope where possible.
- No merge, device rebuild/install, private screenshot upload or generated report commits.

## Risks

- A fresh locked dependency installation is slower than an existing Mac switch; run it in hosted CI to preserve the benchmark window.
- Current main dependencies may change between runs. Each run resolves once and reports actual SHAs; the immutable companion LUI commit makes the unmerged dependency explicit.
- The existing global bottom-lui-capsules decision document lacks required sections; it is reported independently rather than represented as green.

## Consequences

Reviewers can build from ordinary Git/opam manifests or use hosted CI without a Mac-specific OCAMLPATH. Journal now has a build/full-test check and records actual Git source SHAs plus package versions as artifacts. No local compilation or performance sampling is needed during the benchmark window. PR checks are still pending at publication and will be followed to terminal state; existing decision-document failures remain disclosed.

## Questions

None. The user explicitly authorized both PRs and necessary portable CI dependency work; no local compilation is needed for publication.
