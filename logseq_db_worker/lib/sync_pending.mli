type state =
  | Queued
  | Submitted
  | Accepted of int
  | Blocked of string

type entry =
  { mutation_id : Graph_types.Uuid.t
  ; request : Protocol.request
  ; tx : string
  ; outliner_op : string
  ; state : state
  }

type t

val open_ : graph_dir:string -> (t, string) result
val entries : t -> entry list
val replace : t -> entry list -> (unit, string) result
val append : t -> entry -> (unit, string) result
val path : t -> string
