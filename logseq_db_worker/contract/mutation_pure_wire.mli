(** Complete immutable mutation payload, independent of execution generations.
    This value grants no execution or presentation authority. *)
type t

val create
  :  origin:Uri.t
  -> user:string
  -> graph:Graph_types.Uuid.t
  -> Protocol.command
  -> (t, string) result

val restore
  :  origin:Uri.t
  -> user:string
  -> graph:Graph_types.Uuid.t
  -> string
  -> (t, string) result

val encode : t -> string
val namespace : t -> string
val mutation_id : t -> Graph_types.Uuid.t
val command : t -> Protocol.command
val targets : t -> Graph_types.Uuid.t Rrbvec.t

type outcome =
  | Committed of Protocol.response
  | Rejected of Protocol.response
  | Unknown

type recovery_item = { intent : string; outcome : outcome }
type recovery_page = { items : recovery_item Rrbvec.t; next : int64 option }

val recovery_page_bytes : recovery_page -> int
val maximum_recovery_bytes : int
val namespace_for_owner : origin:Uri.t -> user:string -> graph:Graph_types.Uuid.t -> string

type original_point = private
  { generation : string
  ; before : string
  ; after : string
  }

(** Validates protocol/correlation, exact mutation, supported token versions and
    Applied/No-change revision consistency. Already-applied/current-point replies
    cannot establish original evidence. *)
val committed_point
  :  t
  -> request_id:Graph_types.Uuid.t
  -> Protocol.response
  -> (original_point, string) result
