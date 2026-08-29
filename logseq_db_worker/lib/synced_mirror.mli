type metadata = Logseq_db_types.Sync_checkpoint.t

type resolved =
  { graph_dir : string
  ; database_path : string
  ; metadata : metadata
  }

type error =
  | Invalid_root
  | Mirror_missing
  | Mirror_exists
  | Invalid_snapshot of string
  | Invalid_metadata of string
  | Admission_failed of Logseq_db_storage.Admission.error
  | Activation_failed of string
  | Deletion_failed of string

val graph_directory
  :  application_support_directory:string
  -> graph_id:Graph_types.Uuid.t
  -> string

val resolve
  :  application_support_directory:string
  -> graph_id:Graph_types.Uuid.t
  -> (resolved, error) result

val bootstrap
  :  application_support_directory:string
  -> graph_id:Graph_types.Uuid.t
  -> applied_server_t:int
  -> ?checksum:string
  -> expected_rows:int
  -> snapshot_path:string
  -> ?decrypt_protected:(string -> (string, string) result)
  -> unit
  -> (resolved, error) result

val delete
  :  application_support_directory:string
  -> graph_id:Graph_types.Uuid.t
  -> (unit, error) result

val error_message : error -> string
