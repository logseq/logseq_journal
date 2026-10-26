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
