module Dsl = Sync_dsl.Core
module Intent = Logseq_db_types.Asset_upload_intent
module Assets = Logseq_sync_assets.Core

type store

(** Borrow the existing upload-store connection; this owner never opens a second store or closes it. *)
val store : Sqlite3.db -> store

type t

(** Namespace comes from the application's authoritative logical-owner mapper. *)
val create
  :  clock:'clock Eio.Time.Mono.t
  -> namespace:string
  -> assets:Assets.t
  -> store:store
  -> notify_outbox_changed:
       (owner:Execute.Core.database_owner
        -> identity:Dsl.identity
        -> (unit, Dsl.error) result)
  -> t

val database_changed
  :  t
  -> owner:Execute.Core.database_owner
  -> identity:Dsl.identity
  -> (unit, Dsl.error) result

val projection_changed : t -> identity:Dsl.identity -> (unit, Dsl.error) result

val worker_owner : t -> (module Execute.Core.WORKER_OWNER)

val run_assets
  :  t
  -> identity:Dsl.identity
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> 'a Dsl.assets
  -> ('a, Dsl.error) result

val asset_file_path : t -> Dsl.asset_file -> (string, Dsl.error) result

val assets_dispatch
  :  t
  -> scope:Execute.Core.effect_scope
  -> identity:Dsl.identity
  -> 'a Dsl.assets
  -> ('a, Dsl.error) result

val crypto_dispatch
  :  t
  -> scope:Execute.Core.effect_scope
  -> identity:Dsl.identity
  -> 'a Dsl.crypto
  -> ('a, Dsl.error) result

val original_import : t -> Dsl.asset -> (Intent.t option, Dsl.error) result
val fence : t -> identity:Dsl.identity -> (unit, Dsl.error) result

(** Join admitted scopes after fence; consumer leases remain owned. *)
val await_io : t -> identity:Dsl.identity -> (unit, Dsl.error) result
val await_quiescent : t -> identity:Dsl.identity -> (unit, Dsl.error) result
