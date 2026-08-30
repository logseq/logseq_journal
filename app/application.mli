val sync_phase_name : Logseq_sync_pure_reducer.Core.sync_phase -> string
val startup_phase_name : Journal_startup.startup_phase -> string
val graph_phase_name : Logseq_db_worker.graph_phase -> string

val diagnostic_phase_rows
  :  snapshot:Logseq_sync_pure_reducer.Core.snapshot option
  -> graph:Logseq_db_worker.graph_state
  -> (string * string) list

val diagnostic_rows : Logseq_sync_pure_reducer.Core.diagnostics -> (string * string) list
val app : App.t
