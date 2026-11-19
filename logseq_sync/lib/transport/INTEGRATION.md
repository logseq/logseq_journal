# Native transport integration (not activated in App)

Keep the legacy effect-runner HTTP/snapshot entry points until App is switched. Do not install both transport dispatchers for one graph. This lane does not change App or the asset owner.

## Graph owner wiring

- Create `Logseq_sync_transport.Core.create_native` inside the graph's Eio switch. Pass the existing identity, bounded limits, deadlines, WebSocket liveness, absolute staging directory, encryption mode and epoch-aware token callback.
- Inject `~verify_snapshot:Logseq_overlay_db.Database.inspect_snapshot_storage`. Native transport owns downloading, compression layers, framed row import and scratch cleanup; Overlay owns restoring graph storage, encryption metadata and canonical checksum computation. The callback returns `Logseq_overlay_db.Types.Checksum.t`, never a raw database.
- Install `Logseq_sync_transport.Core.capabilities owner capabilities` once. Its dispatch uses the executor's `check_current`, `admit_network` and `handoff`. Use `Core.snapshot_source owner` for the exact original snapshot descriptor. Release with `Core.release_snapshot owner ~identity snapshot`; cancellation/fencing does not transfer the staging ledger.
- Transport must not depend on Worker, the legacy reducer, or Worker fixture directories. The local snapshot test data is an immutable transport fixture, not a runtime dependency.

## Asset HTTP callbacks: exact methods

Create a `Logseq_sync_transport.Http_client.t` with `Http_client.create ~backend ~token`; construct the native backend with `Http_client.native_backend ~sw ~clock ~network ~authenticator ~deadlines`.

The `Logseq_sync_assets.Core.network` record has these callbacks:

```ocaml
{ get = (fun ~identity ~asset ~version ~maximum_wire_bytes ->
    Http_client.get_asset http ~scope ~epoch ~identity
      ~asset:asset.Logseq_db_types.Asset_descriptor.uuid ~version ~maximum_wire_bytes)
; put = (fun ~identity ~asset ~version ~wire ->
    Http_client.put_asset http ~scope ~epoch ~identity ~asset ~version ~wire)
}
```

Here `Http_client` means `Logseq_sync_transport.Http_client`. Bind `scope : Http_client.scope` and `epoch` to the currently admitted graph effect, not a stale graph selection. `scope.check_current` and `scope.admit_network` must use the executor's current effect checks (or the asset owner's active admission context); do not replace them with unconditional success. Refresh the callback context with each authorized epoch rather than retaining an old one in a long-lived cache owner.

| Callback | HTTP method and path | Completion |
| --- | --- | --- |
| `Http_client.get_asset` | `GET /assets/{graph}/{uuid}.{file_type}` | `Ok None` on 404; otherwise bounded wire bytes, still to be decoded/verified by assets. |
| `Http_client.put_asset` | `PUT /assets/{graph}/{uuid}.{file_type}` with wire bytes | HTTP acknowledgement only; 404 is an error. Never treat it as verified publication. |

Both authenticate with Bearer credentials; an authenticated 401 refreshes once and rechecks admission. PUT includes `x-amz-meta-checksum`, `x-amz-meta-type` and `content-type: application/octet-stream`. Asset decode, cryptographic verification, cache publication and durable graph activation remain owned by assets/Worker. In particular, do not pass `put_asset` directly as the asset DSL's `upload` callback: that callback requires verified publication, not an HTTP ACK. All backend callbacks must return only after physical network work joins.

## Acceptance commands

```sh
dune runtest logseq_sync/test/production_transport --force
dune exec test/source_boundary_test.exe -- . _build/default/logseq_sync.install _build/default/logseq_overlay_db.install
dune exec test/logseq_overlay_db_boundary_test.exe -- . _build/default/logseq_overlay_db.install
```

Require a successful exit and inspect/count the source-boundary executable's actual diagnostics, not just its exit status. Native transport and transport must have zero raw database/storage, Worker, legacy-reducer or Worker-fixture violations. Preserve unrelated concurrent owner changes and report their diagnostics separately. Run `ocamlformat --check` on all transport/native `.ml` and `.mli` files; run the full build and regressions on final inputs before integration.

## Finishing-lane verification

Verified against HEAD `e9a37592ef513c66acc0c228de056f7fecb04ef7` plus uncommitted work. Tracked diff SHA-256: `5b1aeede85358c72fa58eb5ee7548a8f88a4011d6011f11dc14d1cf90d9d0f09`. Transport/native/native-crypto/production-transport file-manifest SHA-256 (sorted per-file SHA-256 lines, excluding this document): `0dbf053e3b5de3761763d242e217594e12c58937fa4dd34f02c52a5b1d2ee1ef`.

- `dune build @all app/native_embed.exe.o`: exit 0.
- `dune runtest --force`: exit 0 on the final combined worktree; earlier concurrent asset-owner failures are resolved in that tree, not suppressed by transport.
- Focused production transport suite: exit 0, 18 transport tests and 25 snapshot/HTTP tests, including encryption metadata rejection with staging cleanup.
- Named source-boundary executable: exit 0, `source boundary is clean`; actual diagnostic count drops from 18 at initial inspection to 0 in the final combined worktree.
- Named Overlay package-boundary executable: exit 0, `logseq_overlay_db package boundary: ok`.
- `ocamlformat --check`: exit 0 across all 38 transport/native/native-crypto/production-transport OCaml files; `xcrun clang-format --dry-run --Werror`: exit 0 across all three native C/header files.
- `git diff --check`: clean. No App/assets changes or commits made by this lane; legacy HTTP/snapshot entry points remain until the later App switch.

