type mode =
  | Runtime_flow
  | Runtime_flow_with_pagination
  | Runtime_flow_with_persistence_failure

type generated =
  { support_root : string
  ; snapshot_token : Logseq_db_worker.Graph_types.Uuid.t
  ; graph_dir : string
  }

val create : support_root:string -> mode:mode -> (generated, string) result
val to_yojson : generated -> Yojson.Safe.t
