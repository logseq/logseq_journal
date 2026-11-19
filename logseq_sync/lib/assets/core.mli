module Dsl = Sync_dsl.Core
module Intent = Logseq_db_types.Asset_upload_intent
module Codec = Logseq_sync_native_crypto.Asset_codec

type network =
  { get : identity:Dsl.identity -> asset:Dsl.asset -> version:Logseq_db_types.Asset_descriptor.version -> maximum_wire_bytes:int -> (string option, Dsl.error) result
  ; put : identity:Dsl.identity -> asset:Logseq_db_types.Graph_types.Uuid.t -> version:Logseq_db_types.Asset_descriptor.version -> wire:string -> (unit, Dsl.error) result
  }

type key = check_current:(unit -> (unit, Dsl.error) result) -> (string option, Dsl.error) result
val native_key : identity:Dsl.identity -> crypto:Logseq_sync_crypto.Core.t -> key

type t
val create : root:string -> identity:Dsl.identity -> limits:Dsl.limits -> crypto:Logseq_sync_crypto.Core.t -> key:key -> network:network -> (t, Dsl.error) result
val identity : t -> Dsl.identity
val limits : t -> Dsl.limits
val cache : t -> Cache.t
val crypto : t -> Logseq_sync_crypto.Core.t

(** Callbacks return only after their physical work has joined. Upload returns verified publication, not a PUT acknowledgement. *)
val run : t -> check_current:(unit -> (unit, Dsl.error) result) -> admit_network:(unit -> (unit, Dsl.error) result) -> original:(Dsl.asset -> (Intent.t option, Dsl.error) result) -> upload:(Dsl.asset -> (unit, Dsl.error) result) -> identity:Dsl.identity -> 'a Dsl.assets -> ('a, Dsl.error) result
val dispatch : t -> original:(Dsl.asset -> (Intent.t option, Dsl.error) result) -> upload:(Dsl.asset -> (unit, Dsl.error) result) -> scope:Execute.Core.effect_scope -> identity:Dsl.identity -> 'a Dsl.assets -> ('a, Dsl.error) result
val validate_resource : t -> Dsl.resource_reference -> (unit, Dsl.error) result
val release_file : t -> identity:Dsl.identity -> Dsl.asset_file -> (unit, Dsl.error) result
val release_lease : t -> identity:Dsl.identity -> Dsl.asset_lease -> (unit, Dsl.error) result
val file_path : t -> Dsl.asset_file -> (string, Dsl.error) result
val stage : t -> check_current:(unit -> (unit, Dsl.error) result) -> Logseq_db_types.Asset_import.t -> (Cache.staged, Dsl.error) result
val publish_preview : t -> check_current:(unit -> (unit, Dsl.error) result) -> Intent.t -> (unit, Dsl.error) result
val put_staged : t -> check_current:(unit -> (unit, Dsl.error) result) -> network:Execute.Core.worker_network -> Intent.t -> (unit, Dsl.error) result
val cache_error : Cache.error -> Dsl.error
val fence : t -> unit
val close : t -> (unit, Dsl.error) result
