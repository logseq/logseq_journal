module Dsl = Sync_dsl.Core
module Overlay = Logseq_overlay_db

type t

type activation_input =
  { snapshot : Dsl.snapshot
  ; path : string
  ; expected_rows : int
  ; unprotect :
      Overlay.Database.unprotection_request
      -> ((Overlay.Types.crypto_item_id * string) list, Dsl.error) result
  }

val database_owner : Overlay.Database.t -> t

val activation_owner
  :  sw:Eio.Switch.t
  -> dependencies:Overlay.Database.dependencies
  -> inspection:Overlay.Database.mirror_inspection
  -> graph_name:string
  -> t

val database : t -> (Overlay.Database.t, Dsl.error) result

val with_database
  :  t
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> (Overlay.Database.t -> ('a, Dsl.error) result)
  -> ('a, Dsl.error) result

(** Input paths and metadata must come from the original snapshot owner's ledger.
    Preparation, commit, recovery and open retain the original inspection and queue.
    The caller owns database close; the switch must outlive retirement. *)
val activate_snapshot
  :  t
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> activation_input
  -> (Dsl.activation, Dsl.error) result
