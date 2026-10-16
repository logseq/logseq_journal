# Keep Journal build resources in the skill

## Problem

Build entry points and their helpers are scattered across tool/, while journal-build contains long mode-specific instructions. Moving them must preserve real callers and repository-root discovery.

## Proposal

Move Apple build/probe assembly, CI provisioning/cache and packaging helpers plus their focused tests into journal-build/scripts. Move substantial provenance and cache/measurement guidance to references, retaining a short routing SKILL.md. Update CI, active docs, importers and script-relative paths. Keep unrelated product/acceptance/performance tools and generated artifacts in place. Integrate latest main (including PR80), preserve its fixes and never touch completed phone artifacts.

## Decision

Keep build resources in journal-build and use the exact approved three-file Dune path/data-only-directory patch. Maintain the existing native provenance and target restrictions; route substantial instructions through focused references.

## Alternatives considered

### Keep duplicate wrappers everywhere

Rejected because unused legacy entry points obscure the single maintained build implementation. Dune's direct callers require a minimal path-only change, whose diff must be presented before editing protected files.

## Acceptance criteria

- New script entry points work independently of shell cwd, all actual callers resolve, and old implementations are removed.
- Strict CI cache identity, locked install, final build/test and Apple provenance checks remain intact.
- The skill passes skill-creator validation; focused boundary tests pass, protected-file path changes follow the requested diff review.
- An independent journal-code-review session reviews the final changes. The authorized non-draft PR is created and final-head CI is followed without arbitrary reruns.

## Risks

- Hidden skill directories can be excluded by build-tool discovery. Verify exact Dune dependency behavior rather than assuming a move is sufficient.
- Path-sensitive provenance and historical producer records may correctly refuse rebuild after a configuration move. Do not rewrite original proofs or weaken native source checks.

## Questions

- Authorization? The delegated user explicitly asks for standard skill layout and a formal PR, commit/push/review and necessary CI observation. Protected Dune edits require the requested prior diff; no spec or lock change is planned.

## Authorization

On 2026-10-16 at 05:43:55 UTC the user explicitly approved the presented app/dune and test/dune path changes and root dune `(data_only_dirs .agents)` declaration. This authorizes only those protected edits; no source spec, lock or additional Dune behavior change is included.

## Consequences

- Nine maintained build/CI/probe-assembly/focused-test scripts live in scripts, substantial mode guidance in references, and unrelated product checks remain in tool/.
- Twenty-eight boundary tests, relocated caller help/import checks, static-link helper tests, syntax and skill validation pass. Independent journal-code-review found no actionable issue in the migration plus the exact proposed Dune patch; final-head verification follows the committed integration.
- A minimal external Dune reproduction fails to find hidden skill resources without data_only_dirs, succeeds with it, and confirms nested skill Dune rules do not execute. No new local production app build or GUI run is required by this move. Full source build/tests and actual cache behavior are checked through the authorized PR CI.
