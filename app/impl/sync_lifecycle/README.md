# App sync lifecycle ownership

`Journal_sync_lifecycle.Core` (`logseq_journal.sync_lifecycle`) is the App-owned
native assembly for a borrowed open graph or an App-owned mirror. Its virtual interface is
`app/spec/sync_lifecycle/core.mli`; the implementation is this directory's
`core.ml`, provided by `journal_sync_lifecycle_impl`.

## Implemented and relocated

The assembly originated in
`logseq_sync/lib/service_coordinator/core.{ml,mli}`. The old library/target
`logseq_sync.service_coordinator` is removed, not forwarded or wrapped.

- `start_native`: check the borrowed database identity, assemble native transport,
  crypto, assets and worker owner, start the generic Sync Service, bind ingress,
  and activate the database subscription.
- `projection_changed`: forward projection and postcommit notifications.
- `set_network`: update the per-graph service network gate.
- `close`: consume the Service close right, including checked retirement of
  owned resources and subscription release. The borrowed database and upload
  store remain caller-owned and must outlive close.
- `on_change` / `on_error`: deliver service observations and subscription errors
  to the supplied callbacks. These callbacks are not a UI dispatcher.

The existing native offline-import integration case now uses the App interface.
Its mixed asset/worker integration suite remains in
`logseq_sync/test/asset_owner_lane`; only tests depend upward on the App library.
No production Sync library depends on App or Worker/LUI.

## Account and production registration

`Account` owns the account upload store, bounded graph-service registry, catalog
requests, selection, network gates and checked local deletion. Account replacement
and eviction retain ownership when physical service retirement fails.

`Core.start_owned_native` opens an existing mirror or activates an absent mirror
from the transport-owned snapshot source. It closes its owned database only after
Service retirement and subscription release. `start_native` continues to borrow
its caller's database.

The native Worker/LUI service now selects `Journal_sync_registration`, which
assembles this controller and `direct_sync_runner`, publishes external lifecycle
observations to Worker, and attaches borrowed database owners for scoped reads.
The injected legacy Worker/LUI constructor remains for existing callers/tests;
legacy reducer and runner source has not yet been removed. Compilation alone is
not evidence that retirement, host handoff and local-first restoration are fully
migrated. Those paths require production-boundary regression coverage before the
old runtime can be safely deleted.

No production Sync library depends on App or Worker/LUI. This lifecycle library
also has no Worker/LUI dependency; registration composes the two above it.

## Sync package remains generic

- `logseq_sync/lib/{crypto,assets,transport,native_crypto,native_transport,worker_owner}`:
  production capabilities and native backends.
- `logseq_sync/{spec,lib}/{execute,sync_service,sync_dsl}` and
  `logseq_sync/lib/service_lifecycle`: generic execution, service and retirement.
- `logseq_sync/{spec,lib}/{pure_reducer,protocol}`: pure Sync policy and protocol.

App composes these capabilities; it does not duplicate Sync policy or move the
generic Service into the application.
