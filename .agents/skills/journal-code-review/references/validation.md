# Regression and final validation

## Regression scope

Before adding a bug regression, identify the production state owner and attempt reproduction through its public pure reducer events, completions, state and effects. If that boundary reproduces the defect, add only pure reducer regression coverage; do not duplicate it in effect-runner, persistence, transport, integration, E2E or UI tests.

If it cannot reproduce the defect, document the missing ownership boundary and test the narrowest layer that executes it. Injecting an already incorrect external result is not a pure reproduction. Use deterministic public interfaces without bypassing `.mli` files or copying implementation logic. This does not authorize deleting existing tests or moving production ownership to change test classification. Requested GUI acceptance can still supply visual evidence of behavior; it need not add a duplicate regression suite.

## Final validation

Choose checks from the actual diff and applicable repository rules. Bind evidence to the final full HEAD SHA and, for uncommitted work, the local diff or file hashes. Do not call an earlier green run validation of later source changes.

| Changed surface | Necessary evidence |
| --- | --- |
| AGENTS/skill guidance only | Frontmatter, references, command/path existence, invocation policy preservation, diff hygiene, and a few isolated routing scenarios. No Apple App rebuild solely for prose edits. |
| Build scripts, packaging or helpers | Relevant existing helper tests from journal-build, plus target builds for affected behavior. A path move also needs caller/import and Dune resource checks. |
| Production OCaml/Swift or dependency/build inputs | Full source build and regression on final inputs (`dune build @all app/native_embed.exe.o`, `dune runtest --force` in the prepared locked environment), plus affected native/GUI acceptance. Cache reuse never waives these checks. |

Check decision documents with `spec-dev-tool check --all`; distinguish pre-existing failures from new ones without changing unrelated documents. Record unavailable prerequisites and unexecuted checks explicitly. A pending CI run is pending evidence; publishing/rerunning CI requires its own authorization.

For substantial changes, arrange independent read-only review with journal-code-review. Provide the request, exact final revision/diff, scope and available raw evidence; report findings, fixes and any remaining gaps. Review of a local diff must identify both HEAD and diff digest. Simulator, probe and device evidence have different acceptance limits; use [GUI evidence](../../testing-ios-simulator/references/gui-evidence.md) when needed.
