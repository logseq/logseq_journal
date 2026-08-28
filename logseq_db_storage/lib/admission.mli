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

type target =
  | Local_target
  | Synced_target of Graph_types.Uuid.t

type admitted =
  { schema : Graph_types.schema_version
  ; local_graph_uuid : Graph_types.Uuid.t
  ; admission_facts : Graph_types.admission_fact list
  }

val admit : target:target -> observed -> (Graph_types.admission_fact list, error) result

val inspect
  :  target:target
  -> db:Datascript.db
  -> storage_schema:Datascript.schema
  -> (admitted, error) result
