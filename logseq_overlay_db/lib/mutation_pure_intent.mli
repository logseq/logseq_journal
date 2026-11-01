module Graph = Logseq_db_types.Graph_types

type precondition =
  { blocks : (Graph.Uuid.t * Types.block_state_revision) list
  ; pages : (Graph.Uuid.t * Types.page_state_revision) list
  ; scopes : (Types.structure_revision_scope * Types.scope_revision) list
  }

type t = private
  { namespace : string
  ; graph_uuid : Graph.Uuid.t
  ; mutation_id : Graph.Uuid.t
  ; payload : string
  ; expected : precondition
  ; mutation : Types.local_mutation
  ; encoded : string
  ; targets : Graph.Uuid.t Rrbvec.t
  }

type commit = private
  { intent : t
  ; outcome : Types.local_commit
  ; encoded : string
  }

val create
  :  namespace:string
  -> graph_uuid:Graph.Uuid.t
  -> payload:string
  -> expected:precondition
  -> Types.local_mutation
  -> (t, string) result

val decode : namespace:string -> graph_uuid:Graph.Uuid.t -> string -> (t, string) result
val committed : t -> Types.local_commit -> (commit, string) result
val decode_commit : t -> string -> (commit, string) result

(** Only errors proven before any logical write can create rejection evidence. *)
val rejection : t -> Types.local_commit_error -> string option

val decode_rejection : t -> string -> (Types.local_commit_error option, string) result
