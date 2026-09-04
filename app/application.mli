val sync_phase_name
  :  Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.sync_phase
  -> string

val startup_phase_name : Journal_startup.startup_phase -> string
val graph_phase_name : Logseq_db_worker.graph_phase -> string

val diagnostic_phase_rows
  :  snapshot:Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.snapshot option
  -> graph:Logseq_db_worker.graph_state
  -> (string * string) list

val diagnostic_rows
  :  Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.diagnostics
  -> (string * string) list

module For_testing : sig
  val app_with_service
    :  ( Logseq_db_worker.Config.t
         , Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.request
         , Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.response
         , Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.push )
         Bonsai_flutter.Worker.Service.t
    -> App.t
end

val app : App.t
