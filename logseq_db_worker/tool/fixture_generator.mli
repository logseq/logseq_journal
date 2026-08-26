type mode =
  | Runtime_flow
  | Runtime_flow_with_pagination
  | Runtime_flow_with_persistence_failure

type generated =
  { support_root : string
  ; snapshot_token : Logseq_db_worker.Graph_types.Uuid.t
  ; graph_dir : string
  }

type managed_generated =
  { support_root : string
  ; graph_id : Logseq_db_worker.Graph_types.Uuid.t
  ; graph_dir : string
  ; user_id : string
  ; base_url : string
  ; expected_timeline_text : string
  }

val create : support_root:string -> mode:mode -> (generated, string) result
val to_yojson : generated -> Yojson.Safe.t
val create_encrypted_warm_start : support_root:string -> (managed_generated, string) result
val managed_to_yojson : managed_generated -> Yojson.Safe.t
