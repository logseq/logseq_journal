module Dsl = Sync_dsl.Core
module Execute = Execute.Core
module Service = Logseq_sync_sync_service.Core

type t

(** Borrows an open or activation database owner and upload store through checked close.
    Subscribes after activation. Ingress binds asynchronously; callbacks must not block. *)
val start_native
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> network:_ Eio.Net.t
  -> authenticator:X509.Authenticator.t
  -> config:Service.config
  -> deadlines:Execute.network_deadlines
  -> liveness:Execute.websocket_liveness
  -> cleanup_seconds:float
  -> root:string
  -> database_owner:Execute.database_owner
  -> upload_store:Logseq_sync_worker_owner.Core.store
  -> namespace:string
  -> encrypted:bool
  -> token:(epoch:int64 -> refresh:bool -> (string, Dsl.error) result)
  -> on_change:(Service.status -> unit)
  -> on_error:(Dsl.error -> unit)
  -> (t, Dsl.error) result

(** Owns an existing mirror or activates an absent one from the native snapshot ledger.
    Close retires Sync before closing the database; the upload store remains borrowed. *)
val start_owned_native
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> network:_ Eio.Net.t
  -> authenticator:X509.Authenticator.t
  -> config:Service.config
  -> deadlines:Execute.network_deadlines
  -> liveness:Execute.websocket_liveness
  -> cleanup_seconds:float
  -> root:string
  -> dependencies:Logseq_overlay_db.Database.dependencies
  -> graph_name:string
  -> upload_store:Logseq_sync_worker_owner.Core.store
  -> namespace:string
  -> encrypted:bool
  -> token:(epoch:int64 -> refresh:bool -> (string, Dsl.error) result)
  -> on_change:(Service.status -> unit)
  -> on_error:(Dsl.error -> unit)
  -> (t, Dsl.error) result

val identity : t -> Dsl.identity
val database_owner : t -> Execute.database_owner
val worker_owner : t -> Logseq_sync_worker_owner.Core.t
val ingress : t -> (Service.ingress, Dsl.error) result
val projection_changed : t -> (unit, Dsl.error) result
val set_network : t -> Dsl.network_gate -> (unit, Dsl.error) result
val close : t -> unit
