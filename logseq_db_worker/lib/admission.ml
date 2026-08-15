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

let minimum_schema = Graph_types.{ major = 65; minor = 33 }

let schema_is_supported schema =
  schema.Graph_types.major > minimum_schema.major
  || (schema.major = minimum_schema.major && schema.minor >= minimum_schema.minor)
;;

let admit observed =
  if not (schema_is_supported observed.schema)
  then Error Unsupported_schema
  else if not observed.codec_lossless
  then Error Unsupported_value
  else if not observed.required_schema_present
  then Error Corrupt_storage
  else (
    match observed.remote_flag with
    | Malformed _ -> Error Ambiguous_sync_state
    | Boolean true -> Error Remote_graph
    | Absent | Boolean false ->
      if
        Option.is_some observed.rtc_graph_uuid
        || Option.is_some observed.client_ops_graph_uuid
      then Error Ambiguous_sync_state
      else (
        let remote_fact =
          match observed.remote_flag with
          | Absent -> Graph_types.Remote_flag_absent
          | Boolean false -> Remote_flag_false
          | Boolean true | Malformed _ -> assert false
        in
        let local_fact =
          Option.map (fun uuid -> Graph_types.Local_graph uuid) observed.local_graph_uuid
        in
        Ok
          (Graph_types.Compatible_schema
             { minimum = minimum_schema; actual = observed.schema }
           :: remote_fact
           :: Graph_types.No_rtc_identity
           :: Graph_types.Lossless_codec
           :: Option.to_list local_fact)))
;;
