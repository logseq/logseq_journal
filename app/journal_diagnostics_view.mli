type props =
  { snapshot : Logseq_db_worker_lui.Logseq_db_worker_lui_service.snapshot option
  ; graph : Logseq_db_worker.graph_state
  ; admission : Journal_admission_refresh.observation
  ; diagnostics : Logseq_db_worker_lui.Logseq_db_worker_lui_service.diagnostics option
  ; application_errors : (string * string) list
  }

val view : props -> on_close:Journal_view.Event.Handler.t -> Journal_view.View.Body.t

val sync_phase_name
  :  Logseq_db_worker_lui.Logseq_db_worker_lui_service.sync_phase
  -> string

val graph_phase_name : Logseq_db_worker.graph_phase -> string

val diagnostic_phase_rows
  :  snapshot:Logseq_db_worker_lui.Logseq_db_worker_lui_service.snapshot option
  -> graph:Logseq_db_worker.graph_state
  -> (string * string) list

val diagnostic_rows
  :  Logseq_db_worker_lui.Logseq_db_worker_lui_service.diagnostics
  -> (string * string) list

val format_bytes : int -> string
val admission_rows : Journal_admission_refresh.observation -> (string * string) list
