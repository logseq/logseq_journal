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

module Admission_refresh : sig
  type observation =
    | Unavailable
    | Loading
    | Available of Logseq_db_worker.Protocol.v2_admission_inspection

  type result =
    | Inspected of Logseq_db_worker.Protocol.v2_admission_inspection
    | Inspection_unavailable

  type directive =
    | No_request
    | Request of Journal_graph_request.admission_request

  type t

  val closed : t
  val open_ : t -> graph_generation:int -> graph_open:bool -> t * directive
  val trigger : t -> graph_generation:int -> graph_open:bool -> t * directive

  val complete
    :  t
    -> request:Journal_graph_request.admission_request
    -> result:result
    -> t * directive

  val close : t -> t
  val observation : t -> observation
end

val format_bytes : int -> string
val admission_rows : Admission_refresh.observation -> (string * string) list

module For_testing : sig
  val read_block_entropy : unit -> bytes

  val with_block_identity
    :  ?entropy:(unit -> bytes)
    -> creation_time:Journal_time.t
    -> f:(Logseq_db_types.Graph_types.Uuid.t -> 'a)
    -> unit
    -> ('a, string) result

  val app_with_service
    :  ?calendar_sampler:Journal_calendar.Sampler.t
    -> ( Logseq_db_worker.Config.t
         , Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.request
         , Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.response
         , Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.push )
         Bonsai_flutter.Worker.Service.t
    -> App.t
end

val app : App.t
