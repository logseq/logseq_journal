---
name: journal-mli-spec
description: Write, change or review Journal OCaml .mli interfaces with minimal English comments. Prefer types and names; document only important semantics not inferable from signatures. Applies to all .mli files.
---

# Journal MLI Spec

Prefer types and clear names over comments in every `.mli` interface, including specifications under `spec/`. Follow existing authorization boundaries: this skill does not authorize contract, implementation, Dune or unrelated interface changes.

## Minimal comments

- Omit comments when declarations already communicate the meaning. Delete redundant explanations, repeated signatures, migration narratives and unnecessary examples.
- Keep only the shortest necessary English rule for important semantics that types cannot express: runtime identity/freshness, ownership transfer and ACKs, cancellation versus physical join, durable outcomes, ordering, matching and budget accounting. Never remove the sole statement of such a contract merely to reduce length.
- Place each rule beside its relevant declaration; state it once and refer to the owning contract rather than duplicating it. Use odoc comments when useful, without mandatory sections.
- No required TLDR, usage example, section order, line target or template. Do not repeat primary signatures in documentation. Add a small example only when it resolves an otherwise unclear usage constraint more briefly than prose.
- Preserve English declarations and comments, externally defined names and contract literals. Do not change declarations, abstraction, type equalities or protocols for documentation layout. Do not invent APIs or bypass sealed boundaries in examples.

## Verification

For comment-only edits, prove interface declarations unchanged with normalized OCaml AST comparison (ignoring documentation attributes and locations) or an equally reliable check. Parse and type-check with real dependencies where available; report unavailable checks honestly. Measure actual comment byte/line reduction when simplification is requested, not just formatting changes. Check that essential non-typeable contracts remain and guidance contains no contradictory formatting mandates.

Choose remaining checks using [final validation scope](../journal-code-review/references/validation.md#final-validation). Keep changes within the authorized interfaces; do not automatically migrate other files.
