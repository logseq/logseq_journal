# Experimental native provenance

Input identity and retained code are separate checks. Journal's Markdown path
requires the OCaml runtime and mldoc. XMLm is a locked dependency used by mldoc's
OPML units; an unused XMLm unit may be removed by the OCaml linker. Any unresolved
XMLm reference is rejected. No application anchor or global `-linkall` is needed.

## Ordinary archive inputs (schema 2)

New producers use `schema_version: 2`, with hash-bound `source` and `link` records
and optional `validated_build`. They do not supply `xmlm_force_link`. Source,
compiler, pins, target C and complete-object identities retain the checks below.

The link record adds an absolute `working_directory` and records the actual,
expanded `-output-complete-obj` argv, including its output. Every explicit native
input and its `.a`/`.o` companion must occur by absolute path in `direct_native_input_sha256`.
Both original mldoc and XMLm archives must occur in that argv with the recorded
archive hash; response-file commands and output-as-input identities are refused.
Recorded argv is inspected as data, never executed by the importer.

Schema 2 supports the object-only Dune link form: the fixed code-generation
switches, `-w`/`-warn-error` values (including `@` warning sets), `-I`, `-o`, and
`-cclib` with one unquoted token naming an explicit bound archive/object or `-L`
directory; whitespace, quotes and backslashes in that value are refused because
OCaml can split it into additional linker arguments. Source files,
plugins, response files, `-l` providers, `-ccopt` and other unrecognized options
are refused rather than treated as proved inputs. Relative argv paths resolve
through the recorded working directory for every later archive/stub check.
Companion and dependency hash claims must agree; merging records cannot replace
a conflicting actual-input digest.

Recorded absolute input names use lexical normalization without resolving
symlinks and cannot contain `..`. First import hashes the current files through
those names. Receipt reuse retains the same recorded names even when historical
installation symlinks or their targets later disappear or change.

Each `new_dependency_provenance` entry for mldoc/XMLm retains `pinned_commit`,
`installed_archive`, archive/static archive hashes and installed source hashes.
It additionally supplies:

```json
{
  "source_checkout": "/absolute/clean/pinned/checkout",
  "original_unit": {"cmx_sha256": "SHA256", "object_sha256": "SHA256"},
  "installed_sources_matched_to_pinned_git": {
    "xmlm.ml": {"sha256": "SHA256", "git_path": "src/xmlm.ml"}
  }
}
```

First import checks the clean checkout's exact pinned commit, hashes its raw Git
source blobs against the installed source records, and verifies the original
cmx and archive object member. Installation paths and Git paths remain inside
their respective roots. The immutable complete object's defined and undefined
symbols are inspected separately. `ocaml_units` records actual booleans for
`runtime`, `mldoc` and `xmlm`; runtime/mldoc must be present, XMLm may be absent.

A schema-2 receipt records `ocaml_units` in its imported dependencies and final
`production_link`, without the legacy `runtime_mldoc_xmlm_retained` flag. Those
observations must agree with each other and the still-present fixed host object.
Original source/archive/compiler input hashes may become historical only after
that successful hash-bound receipt, while current native source, object, runtime
headers, original evidence and SDK/signing checks remain live. A schema-1 receipt
cannot authorize schema 2, or vice versa.

## Legacy single-unit force link (schema 1)

The envelope references original producer records by SHA-256; paths are relative to the envelope, while producer records retain their own explicit paths:

```json
{
  "schema_version": 1,
  "source": {"path": "preflight.json", "sha256": "SHA256"},
  "link": {"path": "native-command-manifest.json", "sha256": "SHA256"},
  "xmlm_force_link": {"path": "xmlm-force-link-proof.json", "sha256": "SHA256"},
  "validated_build": {"path": "successful-build/manifest.json", "sha256": "SHA256"}
}
```

`source` binds native source hashes, producer commit, LUI/Signal/DataScript pins and complete-object hash. `link` binds compiler/dependency/archive identity, including mldoc/XMLm pins. `xmlm_force_link` proves a single XMLm unit retained its original cmx/object bytes. Recorded commands are data, never command hooks.

`validated_build` is optional: use a trusted successful experimental manifest from this entry point binding the same records, native source, compiler and object. Without it, the original producer files and XMLm proof must still verify in full. With it, consumed archives/compiler/source paths become historical hash proof and may later change or disappear. This preserves object provenance; it does not prove those paths can still rebuild it. Keep original records/object/receipt read-only; never rewrite proofs or invent a receipt to bypass mismatch.

The producer commit must be an ancestor of the builder revision. The full native source set, Dune/opam/link configuration and pins must still match exactly; Build/tool/docs commits may advance HEAD, changed native bytes need new evidence. Current object/platform/symbols, runtime headers used by fresh target C, records/receipt, SDK and Swift/signing inputs remain live checks. Reports distinguish builder `source_sha` and `native_source_sha`.
