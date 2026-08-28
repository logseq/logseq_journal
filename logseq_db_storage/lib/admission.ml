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

let minimum_schema = Graph_types.{ major = 65; minor = 33 }

let schema_is_supported schema =
  schema.Graph_types.major > minimum_schema.major
  || (schema.major = minimum_schema.major && schema.minor >= minimum_schema.minor)
;;

let local_facts (observed : observed) =
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
        (remote_fact
         :: Graph_types.No_rtc_identity
         :: Graph_types.Lossless_codec
         :: Option.to_list local_fact))
;;

let synced_facts graph_id (observed : observed) =
  match
    ( observed.local_graph_uuid
    , observed.remote_flag
    , observed.rtc_graph_uuid
    , observed.client_ops_graph_uuid )
  with
  | Some local_graph_uuid, Boolean true, Some rtc_graph_uuid, None
    when Graph_types.Uuid.equal graph_id rtc_graph_uuid ->
    Ok
      [ Graph_types.Local_graph local_graph_uuid
      ; Remote_flag_true
      ; Synced_graph_identity graph_id
      ; Lossless_codec
      ]
  | _ -> Error Ambiguous_sync_state
;;

let admit ~target (observed : observed) =
  if not (schema_is_supported observed.schema)
  then Error Unsupported_schema
  else if not observed.codec_lossless
  then Error Unsupported_value
  else if not observed.required_schema_present
  then Error Corrupt_storage
  else (
    let facts =
      match target with
      | Local_target -> local_facts observed
      | Synced_target graph_id -> synced_facts graph_id observed
    in
    Result.map
      (fun facts ->
         Graph_types.Compatible_schema
           { minimum = minimum_schema; actual = observed.schema }
         :: facts)
      facts)
;;

let kv_values db ident =
  let query =
    Printf.sprintf
      "[:find ?value :where [?entity :db/ident :%s] [?entity :kv/value ?value]]"
      ident
  in
  match Datascript.q_return_string db query with
  | Datascript.Query_relation rows ->
    let rec values acc = function
      | [] -> Ok (List.rev acc)
      | [ Datascript.Result_value value ] :: rest -> values (value :: acc) rest
      | _ -> Error ()
    in
    values [] rows
  | _ -> Error ()
;;

let single_kv db ident =
  match kv_values db ident with
  | Ok [] -> Ok None
  | Ok [ value ] -> Ok (Some value)
  | Ok _ | Error () -> Error ()
;;

let map_int key entries =
  List.find_map
    (fun (entry_key, value) ->
       match entry_key, value with
       | Datascript.Keyword actual, Datascript.Int value when String.equal actual key ->
         Some value
       | _ -> None)
    entries
;;

let schema_version db =
  match single_kv db "logseq.kv/schema-version" with
  | Ok (Some (Datascript.Map entries)) ->
    (match map_int "major" entries, map_int "minor" entries with
     | Some major, Some minor when major >= 0 && minor >= 0 ->
       Ok Graph_types.{ major; minor }
     | _ -> Error ())
  | Ok None | Error () | Ok (Some _) -> Error ()
;;

let uuid_of_value = function
  | Datascript.Uuid value | Datascript.String value -> Graph_types.Uuid.of_string value
  | _ -> Error "not a UUID"
;;

let uuid_kv db ident =
  match single_kv db ident with
  | Ok (Some value) -> uuid_of_value value |> Result.map Option.some
  | Ok None -> Ok None
  | Error () -> Error "invalid UUID cardinality"
;;

let remote_flag db =
  match single_kv db "logseq.kv/graph-remote?" with
  | Ok None -> Absent
  | Ok (Some (Datascript.Bool value)) -> Boolean value
  | Ok (Some _) | Error () -> Malformed "invalid remote flag"
;;

let required_schema_present schema =
  List.for_all
    (fun attr -> List.mem_assoc attr schema)
    [ "db/ident"
    ; "block/uuid"
    ; "block/title"
    ; "block/parent"
    ; "block/page"
    ; "block/order"
    ; "kv/value"
    ]
;;

let inspect ~target ~db ~storage_schema =
  match
    ( schema_version db
    , uuid_kv db "logseq.kv/local-graph-uuid"
    , uuid_kv db "logseq.kv/graph-uuid"
    , single_kv db "logseq.kv/db-type" )
  with
  | ( Ok schema
    , Ok (Some local_graph_uuid)
    , Ok rtc_graph_uuid
    , Ok (Some (Datascript.String "db")) ) ->
    let observed =
      { schema
      ; local_graph_uuid = Some local_graph_uuid
      ; remote_flag = remote_flag db
      ; rtc_graph_uuid
      ; client_ops_graph_uuid = None
      ; codec_lossless = true
      ; required_schema_present = required_schema_present storage_schema
      }
    in
    Result.map
      (fun admission_facts -> { schema; local_graph_uuid; admission_facts })
      (admit ~target observed)
  | _ -> Error Corrupt_storage
;;
