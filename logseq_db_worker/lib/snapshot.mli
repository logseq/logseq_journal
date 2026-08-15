type catalog
type write_session

type resolved =
  { graph_dir : string
  ; graph_name : string
  }

type error =
  | Invalid_catalog_root
  | Invalid_inbox_entry
  | Source_missing
  | Manifest_mismatch
  | Token_unknown
  | Path_escape
  | Symlink_rejected
  | Hard_link_rejected
  | Publish_failed of string

val create_catalog : application_support_directory:string -> (catalog, error) result
val create : catalog -> source_graph_dir:string -> (Graph_types.Uuid.t, error) result
val import : catalog -> inbox_entry:string -> (Graph_types.Uuid.t, error) result

val import_native
  :  catalog
  -> inbox_entry:string
  -> destination_graph_dir:string
  -> (unit, error) result

val resolve : catalog -> Graph_types.Uuid.t -> (resolved, error) result

val create_recovery_copy
  :  catalog
  -> Graph_types.Uuid.t
  -> (Graph_types.Uuid.t, error) result

val create_native_recovery_copy
  :  catalog
  -> source_graph_dir:string
  -> owner_generation:string
  -> (Graph_types.Uuid.t, error) result

val manifest_owner_generation
  :  catalog
  -> Graph_types.Uuid.t
  -> (string option, error) result

val begin_write_session
  :  catalog
  -> Graph_types.Uuid.t
  -> recovery_token:Graph_types.Uuid.t
  -> mutation_id:Graph_types.Uuid.t
  -> (write_session, error) result

val record_committed_write : catalog -> write_session -> (unit, error) result
val finish_write_session : catalog -> write_session -> (unit, error) result
val recover : catalog -> Graph_types.Uuid.t -> (Graph_types.Uuid.t, error) result
