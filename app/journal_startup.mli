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
  | Deleting_local
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
  | Local_deletion

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
  :  snapshot:Logseq_db_worker_lui.Logseq_db_worker_lui_service.snapshot
  -> graph:Logseq_db_worker.graph_state
  -> startup_state

type t = Logseq_db_worker.Config.t

(** Encode and decode the byte-exact LDB1 configuration envelope nested
    inside the framework-owned BFR1 runtime envelope. Decoding is bounded and
    performs no filesystem or database work. *)
val encode : t -> (bytes, Error.t) result

val decode : bytes -> (t, Error.t) result

(** Own the initial root presentation and its delayed progress lifetime. *)
module Presentation : sig
  type ticket = private int64
  type observation =
    { manager : Logseq_db_worker_lui.Logseq_db_worker_lui_service.snapshot option
    ; graph : Logseq_db_worker.graph_state
    ; graph_ready : bool
    ; feed_loaded : bool
    ; password_pending : bool
    ; graph_error : bool
    }
  type account_result = Local | No_local | User | No_user
  type screen = Waiting | Timeline | Interaction of startup_state | Account_failure
  type t
  type event =
    | Observe of observation
    | Account of ticket * account_result
    | Account_error of ticket
    | Retry
    | Signed_out
    | Foreground of bool
    | Elapsed of ticket * float
  val create : unit -> t
  val foreground : t -> bool
  val screen : t -> screen
  val loading_indicator : t -> bool
  val loading_request : t -> ticket option
  val account_ticket : t -> ticket
  val initial_attempt : t -> bool
  val equal_presentation : t -> t -> bool
  val step : t -> event -> t
end

module Acceptance : sig
  type identity = { graph_id : Logseq_db_types.Graph_types.Uuid.t; worker_generation : int; epoch : int }
  type t
  val create : unit -> t
  val observe : t -> Presentation.observation -> presentation:Presentation.t -> t
  val epoch : t -> int
  val sample : t -> fresh:Logseq_db_worker.graph_state -> identity option
end
