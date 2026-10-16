# Cache the installed CI switch

## Problem

The custom CI cache restores only the opam root although installed dependencies live in the workspace local switch. Two observed exact hits still installed 170 packages.

## Proposal

Cache the actual absolute switch prefix with an exact dependency, compiler, host architecture, runner image and Apple toolchain identity. Disable overlapping setup-action caches. Prepare system dependencies on every fresh runner before restoring opam state and bind the selected system-library inputs. Keep GitHub cache policy in the workflow and CI dependency tool. Reuse the Apple builder input identity and explicitly bind its absolute opam prefix. Document reuse, mismatch recovery and cold/hot measurement in journal-build.

## Decision

Implement the proposed separation: shared compiler facts in the builder, strict CI compatibility identity in the dependency preparer, cache lifecycle in the workflow, and operational guidance in journal-build. Keep all dependency and final build/test checks unconditional.

## Alternatives considered

### Restore a broad OS-only key

Rejected because compiled switches contain platform, compiler and absolute-path-sensitive artifacts.

### Move CI caching into the Apple builder

Rejected because dependency provisioning and GitHub cache lifecycle are separate from Apple artifact construction.

## Acceptance criteria

- The workflow restores the actual switch with no partial-key fallback and retains unconditional pin, locked install, full build and regression steps.
- Lightweight tests distinguish unchanged inputs from dependency, compiler and absolute-prefix changes; invalid identity inputs fail closed.
- The skill explains strict identity, rebuild recovery and executable cold/hot measurements without an unmeasured speedup claim.
- No dependency, Dune/spec/lock edits, global opam/pin changes, remote CI, GUI or heavy builds occur in this task.

## Risks

- Strict image and toolchain matching reduces hit rate. A miss correctly installs locked dependencies.
- The remote cold/hot experiment remains pending until separately authorized; local boundary checks cannot prove CI cache performance.

## Authorization

The 2026-10-16 delegation authorizes these local workflow/skill/tool changes on an independent branch, light validation only, no push or PR. There are no unanswered design questions within this scope.

## Questions

- Scope and authorization? Answered by the delegation: local changes and light verification only; remote measurement is a later separately authorized action.

## Consequences

- The shared compiler identity adds absolute-prefix separation to Apple manifests; dependency acceptance and native platform checks remain in the builder.
- A real temporary offline opam fixture exercises identity stability and invalidation without changing existing roots/pins. These are tool/provisioning filesystem contracts with no application reducer ownership boundary.
- The CI cold/hot experiment is documented but deliberately not run in this local-only task. Disabling implicit setup caches can add bootstrap cost, which the experiment must include.
