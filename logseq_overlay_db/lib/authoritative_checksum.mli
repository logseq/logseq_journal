type t

val initialize : ?check_current:(unit -> unit) -> e2ee:bool -> Datascript.db -> t
val to_string : t -> string

val advance
  :  maximum:int
  -> before:Datascript.db
  -> after:Datascript.db
  -> changes:Datascript.datom list list
  -> t
  -> (t, string) result

val graph_e2ee : Datascript.db -> bool
val recompute : ?check_current:(unit -> unit) -> e2ee:bool -> Datascript.db -> string
