type status =
  { fts_generation : string option
  ; vector_generation : string option
  }

type t

type error =
  | Ownership_error of Ownership.error
  | Invalid_marker
  | Io_error

val create : graph_dir:string -> owner:Ownership.t -> (t, error) result
val invalidate : t -> (status, error) result
val status : t -> (status, error) result
