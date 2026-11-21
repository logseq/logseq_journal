module Dsl = Sync_dsl.Core

type scope =
  { check_current : unit -> (unit, Dsl.error) result
  ; admit_network : unit -> (unit, Dsl.error) result
  ; handoff : Dsl.resource_reference Rrbvec.t -> (unit, Dsl.error) result
  }

type socket =
  { activate : unit -> (unit, Dsl.error) result
  ; send : string -> (unit, Dsl.error) result
  ; stop : unit -> unit
  ; await_stopped : unit -> unit
  }

type connect_error =
  | Unauthorized
  | Failed of Dsl.error

type backend =
  { connect :
      token:string
      -> on_message:(string -> unit)
      -> on_close:(Dsl.connection_end -> unit)
      -> (socket, connect_error) result
  }

val native_backend
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> network:_ Eio.Net.t
  -> authenticator:X509.Authenticator.t
  -> identity:Dsl.identity
  -> limits:Dsl.limits
  -> deadlines:Execute.Core.network_deadlines
  -> liveness:Execute.Core.websocket_liveness
  -> backend

type t

val create
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> identity:Dsl.identity
  -> limits:Dsl.limits
  -> deadlines:Execute.Core.network_deadlines
  -> cleanup_seconds:float
  -> backend:backend
  -> token:(epoch:int64 -> refresh:bool -> (string, Dsl.error) result)
  -> fetch_snapshot:(scope:scope -> unit -> (Dsl.snapshot, Dsl.error) result)
  -> (t, Dsl.error) result

val create_native
  :  verify_snapshot:Logseq_sync_native_transport.Snapshot_checksum.verifier
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> network:_ Eio.Net.t
  -> authenticator:X509.Authenticator.t
  -> identity:Dsl.identity
  -> limits:Dsl.limits
  -> deadlines:Execute.Core.network_deadlines
  -> cleanup_seconds:float
  -> liveness:Execute.Core.websocket_liveness
  -> staging_directory:string
  -> encrypted:bool
  -> token:(epoch:int64 -> refresh:bool -> (string, Dsl.error) result)
  -> (t, Dsl.error) result

val snapshot_source
  :  t
  -> Dsl.snapshot
  -> (Execute.Core.snapshot_source, Dsl.error) result

val release_snapshot
  :  t
  -> identity:Dsl.identity
  -> Dsl.snapshot
  -> (unit, Dsl.error) result

val authorize : t -> identity:Dsl.identity -> epoch:int64 -> (unit, Dsl.error) result
val fence : t -> identity:Dsl.identity -> (unit, Dsl.error) result
val close_network : t -> identity:Dsl.identity -> (unit, Dsl.error) result
val validate_resource : t -> Dsl.resource_reference -> (unit, Dsl.error) result

(** The snapshot producer retains its original cleanup ledger until handoff. *)
val run
  :  t
  -> scope:scope
  -> identity:Dsl.identity
  -> 'a Dsl.transport
  -> ('a, Dsl.error) result

val dispatch
  :  t
  -> scope:Execute.Core.effect_scope
  -> identity:Dsl.identity
  -> 'a Dsl.transport
  -> ('a, Dsl.error) result

(** Install only transport dispatch, network authority and connection validation. *)
val capabilities : t -> Execute.Core.capabilities -> Execute.Core.capabilities
