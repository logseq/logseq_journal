module Dsl = Sync_dsl.Core
module Native = Logseq_sync_native_crypto.Platform_crypto

type backend =
  { crypto : Native.crypto
  ; unlock :
      identity:Dsl.identity -> wrapped_graph_key:string -> (string, Dsl.error) result
  }

val apple_backend : backend

type t

val create
  :  identity:Dsl.identity
  -> limits:Dsl.limits
  -> encrypted:bool
  -> backend:backend
  -> t

val status : t -> Dsl.key_status
val retire : t -> unit

(** Ephemeral asset-codec key from this owner's installed generation; never reload native storage. *)
val asset_key
  :  t
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> identity:Dsl.identity
  -> (string option, Dsl.error) result

(** The caller's scope is checked before and after each native operation. Retirement erases the owned key. *)
val run
  :  t
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> identity:Dsl.identity
  -> 'a Dsl.crypto
  -> ('a, Dsl.error) result

val dispatch
  :  t
  -> scope:Execute.Core.effect_scope
  -> identity:Dsl.identity
  -> 'a Dsl.crypto
  -> ('a, Dsl.error) result
