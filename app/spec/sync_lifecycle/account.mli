module Dsl = Sync_dsl.Core
module Graph = Logseq_db_types.Managed_graph

type account =
  { origin : string
  ; account : string
  ; root : string
  }

type service

(** Close returns only after physical retirement; failures retain ownership. *)
val service
  :  set_network:(Dsl.network_gate -> (unit, Dsl.error) result)
  -> close:(unit -> (unit, Dsl.error) result)
  -> service

val of_core : Core.t -> service

type catalog =
  account:account
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> gate:(unit -> Dsl.network_gate)
  -> (Graph.t list, Dsl.error) result

val http_catalog
  :  backend:Logseq_sync_transport.Http_client.backend
  -> token:(account:account -> epoch:int64 -> refresh:bool -> (string, Dsl.error) result)
  -> catalog

val native_catalog
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> network:_ Eio.Net.t
  -> authenticator:X509.Authenticator.t
  -> deadlines:Execute.Core.network_deadlines
  -> token:(account:account -> epoch:int64 -> refresh:bool -> (string, Dsl.error) result)
  -> catalog

type t

(** Calls are confined to one Eio domain. Mutations reject reentry; refresh may overlap.
    Start errors must leave no upload-store borrowers; success owns graph resources
    through checked close. *)
val create
  :  maximum_services:int
  -> catalog:catalog
  -> start:
       (account:account
        -> account_generation:int64
        -> graph_generation:int64
        -> graph:Graph.t
        -> upload_store:Logseq_sync_worker_owner.Core.store
        -> network:Dsl.network_gate
        -> on_change:(Core.Service.status -> unit)
        -> (service, Dsl.error) result)
  -> delete_local:(account:account -> graph:Graph.t -> (unit, Dsl.error) result)
  -> on_change:(Graph.t -> Core.Service.status -> unit)
  -> (t, Dsl.error) result

(** Replacement/logout revoke delivery first. Failed retirement blocks reuse and
    keeps the upload store open; retry logout before replacing the account. *)
val replace : t -> account -> (unit, Dsl.error) result

val logout : t -> (unit, Dsl.error) result
val refresh : t -> (Graph.t list, Dsl.error) result
val catalog : t -> Graph.t list
val restore_catalog : t -> Graph.t list -> (unit, Dsl.error) result
val release_graph : t -> Logseq_db_types.Graph_types.Uuid.t -> (unit, Dsl.error) result

(** At capacity, physically retires the oldest service before starting another. *)
val select : t -> Logseq_db_types.Graph_types.Uuid.t -> (unit, Dsl.error) result

val deselect : t -> (unit, Dsl.error) result
val selected : t -> Logseq_db_types.Graph_types.Uuid.t option
val service_count : t -> int
val set_network : t -> Dsl.network_gate -> (unit, Dsl.error) result
val delete_local : t -> Logseq_db_types.Graph_types.Uuid.t -> (unit, Dsl.error) result
