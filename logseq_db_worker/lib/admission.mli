type remote_flag =
  | Absent
  | Boolean of bool
  | Malformed of string

type observed =
  { schema : Graph_types.schema_version
  ; local_graph_uuid : Graph_types.Uuid.t option
  ; remote_flag : remote_flag
  ; rtc_graph_uuid : Graph_types.Uuid.t option
  ; client_ops_graph_uuid : Graph_types.Uuid.t option
  ; codec_lossless : bool
  ; required_schema_present : bool
  }

type error =
  | Unsupported_schema
  | Remote_graph
  | Ambiguous_sync_state
  | Unsupported_value
  | Corrupt_storage

val admit : observed -> (Graph_types.admission_fact list, error) result
