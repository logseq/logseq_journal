module Error : sig
  type t

  val to_string : t -> string
end

type startup_phase =
  | Signed_out
  | Loading_catalog
  | Awaiting_selection
  | Restoring_local
  | Bootstrapping
  | Awaiting_e2ee_password
  | Ready
  | Failed

type startup_error_owner =
  | Authentication
  | Catalog
  | Local_restore
  | Bootstrap
  | E2ee
  | Graph

type startup_recovery =
  | Sign_in
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password
  | Retry_graph_open

type startup_error =
  { owner : startup_error_owner
  ; message : string
  ; recovery : startup_recovery option
  }

type startup_state =
  { phase : startup_phase
  ; error : startup_error option
  }

val derive
  :  snapshot:Logseq_sync_pure_reducer.Core.snapshot
  -> graph:Logseq_db_worker.graph_state
  -> startup_state

type t = Logseq_db_worker.Config.t

(** Encode and decode the byte-exact LDB1 configuration envelope nested
    inside the framework-owned BFR1 runtime envelope. Decoding is bounded and
    performs no filesystem or database work. *)
val encode : t -> (bytes, Error.t) result

val decode : bytes -> (t, Error.t) result
