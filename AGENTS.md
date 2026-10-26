# Journal repository guidance

- Follow [UX guidelines](docs/ux-guidelines.md). Prefer native bonsai-ui/SwiftUI layout, scrolling and animation. Custom coordination through per-row geometry, shared geometry state or repeated scrolling scans needs an explained native API limitation and explicit approval.
- Protect existing work. Keep temporary evidence, reports, screenshots and generated hosts in the task's external evidence directory; reusable formal tests belong in existing test directories.
- Do not edit OCaml under `spec/` without an explicit request to change its `.mli` contracts, or any Dune file without an explicit request. If a spec blocks development, report the contract issue, suggested change and rationale. Do not edit OCaml in bonsai_flutter.
- Before adding a bug regression, follow [regression scope](.agents/skills/journal-code-review/references/validation.md#regression-scope): identify the production owner and reproduce through its public pure reducer boundary first.
- Use `spec-dev-tool --help` for decision documents and its AGENT WORKFLOW. For simplification requests, run `spec-dev-tool guide find-simplifications` or `spec-dev-tool guide find-test-simplifications` inside this worktree as appropriate.
- Repository guidance does not grant execution or external-action permission. Carry forward the user's existing authorization; ask only for a missing scope or required approval. Handoffs record the target, actual progress, evidence, remaining blockers and authorization boundary.

## Task routing

| Task | Read |
| --- | --- |
| Apple build, dependency cache or native provenance | [journal-build](.agents/skills/journal-build/SKILL.md); entry: `bash .agents/skills/journal-build/scripts/build_journal_apple.sh --help` |
| Requested or independent review | [journal-code-review](.agents/skills/journal-code-review/SKILL.md) |
| Simulator interaction, screenshots or GUI acceptance | [testing-ios-simulator](.agents/skills/testing-ios-simulator/SKILL.md) |
| Choose final checks for any change | [validation scope](.agents/skills/journal-code-review/references/validation.md#final-validation) |
