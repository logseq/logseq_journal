val graph_e2ee : Datascript.db -> bool
val recompute : ?check_current:(unit -> unit) -> e2ee:bool -> Datascript.db -> string
