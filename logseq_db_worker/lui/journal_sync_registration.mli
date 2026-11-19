type network_control =
  | Sign_in of Logseq_sync_domain.Core.startup_scope
  | Cancel_startup of Logseq_sync_domain.Core.startup_scope
  | Refresh_catalog of Logseq_sync_domain.Core.startup_scope
  | Recover_online of Logseq_sync_domain.Core.timeline_scope

type t =
  { services : Logseq_db_worker_effect_runner.Effect_runner.services
  ; validate_control : network_control -> (unit, Sync_dsl.Core.error) result
  ; bind : Logseq_db_worker.t -> unit
  ; post : Logseq_db_worker_pure_reducer.Core.event -> unit
  ; lifecycle : Logseq_db_worker_pure_reducer.Core.lifecycle_intent -> unit
  ; unlock : Logseq_sync_domain.Core.graph_scope -> string -> (unit, string) result
  ; shutdown : unit -> unit
  }

val create
  : sw:Eio.Switch.t
  -> clock:_ Eio.Time.Mono.t
  -> network:_ Eio.Net.t
  -> authenticator:X509.Authenticator.t
  -> config:Logseq_db_worker.Config.t
  -> overlay:Logseq_overlay_db.Database.dependencies
  -> token:(user:string -> account_generation:int -> epoch:int64 -> refresh:bool -> (string, Sync_dsl.Core.error) result)
  -> unit -> (t, Sync_dsl.Core.error) result
