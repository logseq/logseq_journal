module Dsl = Sync_dsl.Core

type t

val create
  :  verify:Logseq_sync_native_transport.Snapshot_checksum.verifier
  -> root:string
  -> identity:Dsl.identity
  -> limits:Dsl.limits
  -> encrypted:bool
  -> http:Http_client.t
  -> (t, Dsl.error) result

(** Metadata defines the baseline; no WebSocket or preliminary pull is required. *)
val acquire
  :  t
  -> scope:Http_client.scope
  -> epoch:int64
  -> handoff:(Dsl.resource_reference Rrbvec.t -> (unit, Dsl.error) result)
  -> unit
  -> (Dsl.snapshot, Dsl.error) result

(** Exact original descriptors only; files remain owned across network fencing until checked release. *)
val source : t -> Dsl.snapshot -> (Execute.Core.snapshot_source, Dsl.error) result

val validate_resource : t -> Dsl.resource_reference -> (unit, Dsl.error) result
val release : t -> identity:Dsl.identity -> Dsl.snapshot -> (unit, Dsl.error) result
val drain : t -> (unit, Dsl.error) result
val close : t -> (unit, Dsl.error) result
