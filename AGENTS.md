- Use spec-dev-tool to manage agent decision documents; run `spec-dev-tool --help` and follow its AGENT WORKFLOW.
- When asked to find simplifications, run `spec-dev-tool guide find-simplifications` from inside this Git worktree and follow the emitted workflow.
- Do not modify any ocaml files under `spec/` during development unless explicitly asked to modify the `.mli` files under `spec/`.
- Do not modify any dune file during development unless explicitly asked.
- If development is blocked because the `.mli` definitions under `spec/` are unclear or unreasonable, stop development immediately and report the specific spec issue, suggested changes, and rationale.
- Do not modify any ocaml files in bonsai_flutter repo



## UI/UX design rules

- number of dividers must <= 3
