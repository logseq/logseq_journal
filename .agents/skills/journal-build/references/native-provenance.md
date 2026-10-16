# Experimental native provenance


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
