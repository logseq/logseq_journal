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

module Pure_import_recovery : sig
  module Worker=Journal_worker_coordination.Worker_api
  type request=private {session:Worker.session;serial:int64;after:Worker.import_input_recovery_cursor option;page_number:int}
  type acknowledgement=private {session:Worker.session;serial:int64;proof:Worker.prepared_import_source}
  type command=Read of request|Acknowledge of acknowledgement
  type t
  type event=Open of Worker.session option|Close|Reload|Retry|Next|Mark_reviewed of Worker.prepared_import_source
    |Completed of request * (Worker.import_input_recovery,string)result|Acknowledged of acknowledgement * (unit,string)result
  val closed:t
  val loading:t -> bool
  val available:t -> bool
  val loaded:t -> bool
  val error:t -> string option
  val page_number:t -> int
  val items:t -> Worker.recovered_import_input Rrbvec.t
  val can_next:t -> bool
  val operation:request -> Worker.import_input_recovery Worker.request
  val step:t -> event -> t * command option
end

type recovery_controls =
  { state : Pure_recovery.t
  ; on_reload : Journal_view.Event.Handler.t
  ; on_retry : Journal_view.Event.Handler.t
  ; on_next : Journal_view.Event.Handler.t
  }

type import_recovery_controls={import_state:Pure_import_recovery.t;
  on_import_reload:Journal_view.Event.Handler.t;on_import_retry:Journal_view.Event.Handler.t;on_import_next:Journal_view.Event.Handler.t;
  on_import_review:Pure_import_recovery.Worker.prepared_import_source -> Journal_view.Event.Handler.t}

type props =
  { snapshot : Logseq_db_worker_lui.Logseq_db_worker_lui_service.snapshot option
  ; graph : Logseq_db_worker.graph_state
  ; admission : Journal_admission_refresh.observation
  ; diagnostics : Logseq_db_worker_lui.Logseq_db_worker_lui_service.diagnostics option
  ; application_errors : (string * string) list
  }

val view
  :  ?recovery:recovery_controls
  -> ?imports:import_recovery_controls
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
