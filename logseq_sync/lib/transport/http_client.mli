module Dsl = Sync_dsl.Core
module Http = Logseq_sync_native_transport.Http
module Native = Logseq_sync_native_transport.Http_eio

type scope =
  { check_current : unit -> (unit, Dsl.error) result
  ; admit_network : unit -> (unit, Dsl.error) result
  }

type backend =
  { perform : Http.request -> (Native.response, Native.error) result
  ; download :
      request:Http.request
      -> destination:string
      -> maximum_bytes:int
      -> (Native.response, Native.error) result
  }

val native_backend
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> network:_ Eio.Net.t
  -> authenticator:X509.Authenticator.t
  -> deadlines:Execute.Core.network_deadlines
  -> backend

type t

val create
  :  backend:backend
  -> token:(epoch:int64 -> refresh:bool -> (string, Dsl.error) result)
  -> t

(** Every attempt rechecks admission; only authenticated 401 refreshes, once. Backends return after physical join. *)
val perform
  :  t
  -> scope:scope
  -> epoch:int64
  -> authenticated:bool
  -> (string option -> Http.request)
  -> (Native.response, Dsl.error) result

val download
  :  t
  -> scope:scope
  -> epoch:int64
  -> authenticated:bool
  -> destination:string
  -> maximum_bytes:int
  -> (string option -> Http.request)
  -> (Native.response, Dsl.error) result

val get_asset
  :  t
  -> scope:scope
  -> epoch:int64
  -> identity:Dsl.identity
  -> asset:Logseq_db_types.Graph_types.Uuid.t
  -> version:Logseq_db_types.Asset_descriptor.version
  -> maximum_wire_bytes:int
  -> (string option, Dsl.error) result

(** PUT completion acknowledges HTTP only; the asset owner retains verification and publication. *)
val put_asset
  :  t
  -> scope:scope
  -> epoch:int64
  -> identity:Dsl.identity
  -> asset:Logseq_db_types.Graph_types.Uuid.t
  -> version:Logseq_db_types.Asset_descriptor.version
  -> wire:string
  -> (unit, Dsl.error) result
