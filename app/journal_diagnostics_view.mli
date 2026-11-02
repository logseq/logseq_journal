module Pure_recovery : sig
  module Worker = Journal_worker_coordination.Worker_api

  type request = private
    { session : Worker.session
    ; serial : int64
    ; after : Worker.mutation_recovery_cursor option
    ; page_number : int
    }

  type t

  type event =
    | Open of Worker.session option
    | Close
    | Reload
    | Retry
    | Next
    | Completed of request * (Worker.mutation_recovery, string) result

  val closed : t
  val step : t -> event -> t * request option
  val loading : t -> bool
  val error : t -> string option
  val available : t -> bool
  val loaded : t -> bool
  val can_next : t -> bool
  val page_number : t -> int
  val items : t -> Worker.recovered_mutation Rrbvec.t
  val operation : request -> Worker.mutation_recovery Worker.request
end

type recovery_controls =
  { state : Pure_recovery.t
  ; on_reload : Journal_view.Event.Handler.t
  ; on_retry : Journal_view.Event.Handler.t
  ; on_next : Journal_view.Event.Handler.t
  }

type props =
  { snapshot : Logseq_db_worker_lui.Logseq_db_worker_lui_service.snapshot option
  ; graph : Logseq_db_worker.graph_state
  ; admission : Journal_admission_refresh.observation
  ; diagnostics : Logseq_db_worker_lui.Logseq_db_worker_lui_service.diagnostics option
  ; application_errors : (string * string) list
  }

val view
  :  ?recovery:recovery_controls
  -> props
  -> on_close:Journal_view.Event.Handler.t
  -> Journal_view.View.Body.t

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
