# Task-owned plaintext sync fixtures

This standalone helper is restricted to fresh fixture data. It does not link App,
change production contracts, control simulators, call RSA/key endpoints, or use
CLI sync upload. The API origin and Cognito protocol come from the existing
`test_managed_sync_e2e.ml` and `managed_sync_e2e_support.ml` harness.

## Verification evidence

Each run records creation acknowledgements, assigned-UUID preflights, upload
receipts, catalog readiness, snapshot cursors and downloaded-frame re-admission
in the private 0600 registry. Graph identities and measured quantities are
run-specific evidence, not hard-coded acceptance targets. Keep the registry and
generated frames outside Git.

A builtin-only graph can have a computed zero checksum. The helper still derives
and checks it through the real public-library activation and fresh remote read;
it never substitutes a constant. Native fresh-read evidence is not Simulator UI
evidence.

## Safety boundary

- Local CLI subprocesses receive only a system/opam environment allowlist. CLI
  routing variables, secrets, and proxy variables are absent. Every graph command
  has explicit `--root-dir`, `--config`, and unique `--graph` arguments.
- Each CLI workspace is private 0700 under `_build/plain-fixture-*`; `cli.edn`
  points to an absolute absent auth file. Creation does not enable sync or login.
  Export is SQLite. Only the exact scoped CLI worker is stopped; auth remains absent.
- The native helper copies only the newly exported fixture into an exclusive fresh
  destination. It restores through the real SQLite adapter, changes the three
  graph identity/remote/encryption KVs using pure `Datascript.db_with`, and persists
  through existing storage callbacks. No user SQLite data is patched with SQL.
- Both local preflights finish before any remote POST. Each server acknowledgement
  is persisted and fsynced immediately. The assigned UUID is then embedded and
  the full preflight repeated before upload.
- HTTP credentials travel only in private stdin pipes, never argv/files/logs.
  Curl uses real CA validation, ignores curlrc/proxies, and has no automatic retry.
- A successful provisioning run creates exactly two new graphs and uploads a
  snapshot only to each acknowledged UUID. Other graph access is limited to
  catalog metadata; fixture downloads never read an existing graph.
- Cleanup requires the exact creation-acknowledged UUID, exact nonce/name/role,
  the same authenticated creator subject hash, and a fresh exact catalog match;
  manager membership alone never authorizes deletion. Run deletion only after
  the main owner has completed UI acceptance and fixture cleanup.
- Unknown creation outcomes are not blindly retried or adopted. Exact nonce-name
  catalog matches are recorded as indeterminate for manual resolution. On later
  failure, only acknowledged fixtures still catalog-unready may be auto-deleted;
  server-ready fixtures remain for Main.

## Commands

Run from the repository root with the prepared opam environment:

```sh
dune build tool/sync_acceptance_fixture/fixture.exe
python3 tool/sync_acceptance_fixture/provision.py --create-two-new-plaintext-graphs
```

Creation is one-shot: the nonce is durably recorded before setup or remote writes.
Any recorded nonce or indeterminate creation refuses further provisioning, even
when no creation acknowledgement reached the client. Reconcile that original
nonce manually; do not reset the registry or create a new nonce to retry an
unknown result. It requires
`LOGSEQ_ACCOUNT` and `LOGSEQ_ACCOUNT_PASSWORD` only for the private Cognito request,
not for local CLI operations. Without an explicit orchestrator action flag, the
Python tool performs no network operation; the native executable is local-only.

`--verify-recorded-owned-fixtures` downloads and validates only recorded fixtures.
It deliberately refuses overwriting prior `remote.transit` evidence. Keep each
run's existing results; do not rerun creation to repeat verification.

After Main completes UI case cleanup, the guarded deletion action is:

```sh
python3 tool/sync_acceptance_fixture/provision.py --delete-recorded-owned-fixtures
```

That action reauthenticates, checks the registry nonce and each creation ACK against
fresh catalog metadata, and verifies exact deletion receipts. It is provided for
Main's later cleanup, not executed during fixture setup. Retain the registry until
both remote deletions are confirmed. Main owns all simulator interaction, plain
sync and capacity/replace UI acceptance, final artifact cleanup, and independent
review before any commit. Native fresh-read evidence is not simulator UI evidence.
