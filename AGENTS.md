- Use spec-dev-tool to manage agent decision documents; run `spec-dev-tool --help` and follow its AGENT WORKFLOW.
- All changes must comply with `docs/ux-guidelines.md`.
- Keep temporary review and test evidence, experiments, reports, screenshots, and generated hosts outside this repository in the current task's external evidence directory. Do not create a repository `review/` directory or temporary test directories. Reusable formal test source belongs in the existing test directories.
- Before adding a bug regression test, identify the production state owner and attempt reproduction through its public pure reducer events, completions, state, and effects. If that boundary reproduces the defect, add only pure reducer regression tests for it; do not duplicate coverage in effect-runner, persistence, transport, integration, E2E, or UI tests. If it cannot, document the missing ownership boundary and test only the narrowest layer that executes the defect. Injecting an already incorrect external result is not a pure reproduction. Use deterministic public interfaces without bypassing `.mli` files or copying implementation logic. This rule does not authorize removing existing tests or moving production ownership for test classification.
- When asked to find simplifications, run `spec-dev-tool guide find-simplifications` from inside this Git worktree and follow the emitted workflow.
- When asked to find test simplifications, run `spec-dev-tool guide find-test-simplifications` from inside this Git worktree and follow the emitted workflow.
- Do not modify any ocaml files under `spec/` during development unless explicitly asked to modify the `.mli` files under `spec/`.
- Do not modify any dune file during development unless explicitly asked.
- If development is blocked because the `.mli` definitions under `spec/` are unclear or unreasonable, stop development immediately and report the specific spec issue, suggested changes, and rationale.
- Do not modify any ocaml files in bonsai_flutter repo
- Prefer native bonsai-ui/SwiftUI components and their built-in layout, scrolling, and animation behavior. Do not recreate these behaviors using per-row geometry tracking, shared observable geometry state, or repeated collection scans during scrolling. If native APIs cannot satisfy a requirement, explain the limitation and obtain explicit approval before implementing custom UI coordination.

## Build

Use `bash .agents/skills/journal-build/scripts/build_journal_apple.sh --help` as the Apple build entry point. Read [journal-build](.agents/skills/journal-build/SKILL.md) for target selection, prerequisites, cache/provenance, failure handling and acceptance limits.

## UI operations and acceptance evidence

Before operating a device or taking acceptance screenshots, verify the explicitly
expected device UDID/type and platform, stable graph UUID, and the installed App's
bundle/version/build, executable hash and source/build evidence. Re-resolve the
installed container each time. Names, graph-picker position, persisted selection,
old screenshots, manually filled actual fields and build labels alone are not
identity proof. Unknown or mismatched identity blocks acceptance and target-dependent
UI operations; do not switch graphs, reinstall, create devices or touch another
owner's device to work around a failed check.

Use [testing-ios-simulator](.agents/skills/testing-ios-simulator/SKILL.md) for the
checklist and `python3 tool/capture_acceptance.py --help` as the unified Simulator
acceptance entry point. Read [the evidence contract](docs/acceptance-capture.md).
The runtime observer is Simulator-only and must be explicitly enabled with
`JOURNAL_ACCEPTANCE=1` on the authorized matching App. An absent, unauthenticated
or unready observer blocks with `runtime-identity-unavailable`; fixtures/green CI
do not establish a verified real capture.
Do not replace that boundary with constants or database/secret reads. Coordinate
shared Simulator ownership; Simulator/experimental host-restamp evidence never
proves real-device or cross-ABI acceptance. Keep evidence private and external;
public fixtures must contain only synthetic identities and no credentials/content.
