type t

type error =
  | Snapshot_error of Snapshot.error
  | Ownership_error of Ownership.error

val create : catalog:Snapshot.catalog -> source_token:Graph_types.Uuid.t -> t

val create_native
  :  catalog:Snapshot.catalog
  -> source_graph_dir:string
  -> owner:Ownership.t
  -> t

val ensure : t -> (Graph_types.Uuid.t, error) result
val ensure_verified : t -> (Graph_types.Uuid.t, error) result
val recovery_token : t -> Graph_types.Uuid.t option
