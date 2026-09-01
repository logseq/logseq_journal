type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t
type account_generation = int
type graph_generation = int
type connection_generation = int
type presentation_generation = int
type lifecycle_generation = int64

type sync_phase =
  | Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed

type startup_failure_stage =
  | During_authentication
  | During_catalog
  | During_local_restore
  | During_bootstrap
  | During_e2ee

type startup_facts =
  { authenticated : bool
  ; catalog_loading : bool
  ; awaiting_selection : bool
  ; restoring_local : bool
  ; bootstrapping : bool
  ; awaiting_e2ee_password : bool
  ; failure : startup_failure_stage option
  ; account_generation : account_generation
  ; graph_generation : graph_generation
  ; presentation_generation : presentation_generation
  }

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; applied_server_t : int option
  ; timeline_presentation_pending : bool
  ; startup : startup_facts
  ; last_error : string option
  }

type diagnostic_group =
  { title : string
  ; entries : (string * string) list
  }

type diagnostics =
  { groups : diagnostic_group list
  ; history : string list
  }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type limits =
  { maximum_response_bytes : int
  ; maximum_artifact_bytes : int
  ; submission_batch_size : int
  }
[@@warning "-69"]

type config =
  { managed_sync_origin : Uri.t
  ; limits : limits
  }

type config_error = Invalid_config of string

let limits ~maximum_response_bytes ~maximum_artifact_bytes ~submission_batch_size =
  if
    maximum_response_bytes <= 0
    || maximum_response_bytes > Logseq_db_types.Limits.maximum_response_bytes
  then Error (Invalid_config "maximum response bytes are outside the supported bound")
  else if maximum_artifact_bytes <= 0
  then Error (Invalid_config "maximum artifact bytes must be positive")
  else if submission_batch_size <= 0 || submission_batch_size > 4096
  then Error (Invalid_config "submission batch size is outside the supported bound")
  else Ok { maximum_response_bytes; maximum_artifact_bytes; submission_batch_size }
;;

let config ~managed_sync_origin ~limits =
  match Uri.scheme managed_sync_origin, Uri.host managed_sync_origin with
  | Some "https", Some host when String.length host > 0 ->
    Ok { managed_sync_origin; limits }
  | _ -> Error (Invalid_config "managed sync origin must be an absolute HTTPS URI")
;;

type token_purpose =
  | Catalog_discovery
  | Snapshot_bootstrap
  | E2ee_key_access
  | Websocket_connect

type token_request =
  { request_id : string
  ; purpose : token_purpose
  ; account_generation : account_generation
  ; graph_generation : graph_generation option
  ; connection_generation : connection_generation option
  }
[@@warning "-69"]

let token_request_id request = request.request_id
let token_request_purpose request = request.purpose

type bootstrap_progress =
  { graph_id : graph_id
  ; received_bytes : int64
  ; total_bytes : int64 option
  }

type invalidation =
  { basis : int64
  ; changed_uuids : graph_id list
  ; changed_uuids_truncated : bool
  }

type account_scope =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : account_generation
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  }

type authenticated_account_scope =
  { account : account_scope
  ; token : string
  }

type graph_scope =
  { account : account_scope
  ; graph_id : graph_id
  ; graph_generation : graph_generation
  }

type authorized_graph_scope =
  { graph : graph_scope
  ; token : string
  }

type connection_scope =
  { graph : graph_scope
  ; connection_generation : connection_generation
  }

type effect_scope =
  { account_generation : account_generation option
  ; graph_generation : graph_generation option
  ; connection_generation : connection_generation option
  ; presentation_generation : presentation_generation option
  ; lifecycle_generation : lifecycle_generation option
  }

type effect_id = int

type crypto_failure_kind =
  | Invalid_key_material
  | Crypto_provider_unavailable

type effect_error =
  | Effect_failed of string
  | Crypto_failed of crypto_failure_kind * string

type graph_key_handle =
  { handle_id : string
  ; handle_scope : graph_scope
  }

type staged_artifact =
  { artifact_id : string
  ; artifact_scope : graph_scope
  ; artifact_path : string
  ; artifact_expected_rows : int
  }
[@@warning "-69"]

type catalog_cache =
  { cache_user_id : string
  ; cache_graphs : graph list
  ; cache_selected_graph : graph_id option
  }

let catalog_cache ~user_id ~graphs ~selected_graph =
  { cache_user_id = user_id
  ; cache_graphs = graphs
  ; cache_selected_graph = selected_graph
  }
;;

let catalog_cache_user_id cache = cache.cache_user_id
let catalog_cache_graphs cache = cache.cache_graphs
let catalog_cache_selected_graph cache = cache.cache_selected_graph

let graph_to_json (graph : graph) =
  `Assoc
    [ "graphId", `String (Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id)
    ; "name", `String graph.name
    ; ( "schema"
      , `Assoc
          [ "major", `Int graph.schema.major
          ; "minor", `Int graph.schema.minor
          ; "exact", `Bool graph.schema.exact
          ] )
    ; "encrypted", `Bool graph.encrypted
    ]
;;

let encode_catalog_cache cache =
  `Assoc
    [ "userId", `String cache.cache_user_id
    ; "graphs", `List (List.map graph_to_json cache.cache_graphs)
    ; ( "selectedGraph"
      , match cache.cache_selected_graph with
        | None -> `Null
        | Some graph_id -> `String (Logseq_db_types.Graph_types.Uuid.to_string graph_id)
      )
    ]
  |> Yojson.Safe.to_string
;;

let decode_catalog_cache source =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string source in
    let user_id = json |> member "userId" |> to_string in
    let graph_of_json value =
      let graph_id =
        value
        |> member "graphId"
        |> to_string
        |> Logseq_db_types.Graph_types.Uuid.of_string
        |> Result.get_ok
      in
      let schema = value |> member "schema" in
      Logseq_db_types.Managed_graph.
        { graph_id
        ; name = value |> member "name" |> to_string
        ; schema =
            { major = schema |> member "major" |> to_int
            ; minor = schema |> member "minor" |> to_int
            ; exact = schema |> member "exact" |> to_bool
            }
        ; encrypted = value |> member "encrypted" |> to_bool
        }
    in
    let graphs = json |> member "graphs" |> to_list |> List.map graph_of_json in
    let selected_graph =
      match json |> member "selectedGraph" with
      | `Null -> None
      | `String value ->
        Logseq_db_types.Graph_types.Uuid.of_string value |> Result.to_option
      | _ -> None
    in
    Ok (catalog_cache ~user_id ~graphs ~selected_graph)
  with
  | Yojson.Json_error message | Type_error (message, _) | Invalid_argument message ->
    Error message
;;

type encryption_batch =
  { scope : graph_scope
  ; key : graph_key_handle
  ; plaintexts : string list
  }

type encrypted_values = (string * string) list

type decryption_batch =
  { scope : graph_scope
  ; key : graph_key_handle
  ; protected_values : (string * string) list
  }

type decrypted_values = string list

type outbox_state =
  | Queued
  | Submitted
  | Accepted of int
  | Blocked of string

type outbox_record =
  { mutation_id : graph_id
  ; mutation_payload : string
  ; mutation_fingerprint : string
  ; encoded_tx : string
  ; outliner_op : string
  ; outbox_state : outbox_state
  }

let outbox_record_mutation_id record = record.mutation_id
let outbox_record_fingerprint record = record.mutation_fingerprint
let outbox_record_mutation_payload record = record.mutation_payload
let outbox_record_outliner_op record = record.outliner_op
let outbox_record_state record = record.outbox_state
let outbox_record_with_state record outbox_state = { record with outbox_state }

let clear_outbox_transport record outbox_state =
  { record with outbox_state; encoded_tx = "[]" }
;;

let block_outbox_record record message =
  let message =
    if String.length message <= 4096 then message else String.sub message 0 4096
  in
  { record with outbox_state = Blocked message; encoded_tx = "[]" }
;;

let recompute_checksum database =
  Checksum.recompute ~e2ee:(Checksum.graph_e2ee database) database
;;

let outbox_state_to_json = function
  | Queued -> `Assoc [ "type", `String "queued" ]
  | Submitted -> `Assoc [ "type", `String "submitted" ]
  | Accepted server_t -> `Assoc [ "type", `String "accepted"; "serverT", `Int server_t ]
  | Blocked message -> `Assoc [ "type", `String "blocked"; "message", `String message ]
;;

let exact_fields expected fields =
  List.map fst fields |> List.sort String.compare = List.sort String.compare expected
;;

let outbox_state_of_json = function
  | `Assoc fields when exact_fields [ "type" ] fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "queued") -> Ok Queued
     | Some (`String "submitted") -> Ok Submitted
     | _ -> Error "invalid queued or submitted outbox state")
  | `Assoc fields when exact_fields [ "serverT"; "type" ] fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "serverT" fields with
     | Some (`String "accepted"), Some (`Int value) when value >= 0 -> Ok (Accepted value)
     | _ -> Error "invalid accepted outbox state")
  | `Assoc fields when exact_fields [ "message"; "type" ] fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "message" fields with
     | Some (`String "blocked"), Some (`String message)
       when String.length message > 0 && String.length message <= 4096 ->
       Ok (Blocked message)
     | _ -> Error "invalid blocked outbox state")
  | `Assoc _ -> Error "invalid outbox state"
  | _ -> Error "invalid outbox state"
;;

let outbox_record_to_json record =
  `Assoc
    [ ( "mutationId"
      , `String (Logseq_db_types.Graph_types.Uuid.to_string record.mutation_id) )
    ; "mutationPayload", `String record.mutation_payload
    ; "mutationFingerprint", `String record.mutation_fingerprint
    ; "outlinerOp", `String record.outliner_op
    ; "state", outbox_state_to_json record.outbox_state
    ; "encodedTx", `String record.encoded_tx
    ]
;;

let outbox_record_of_json = function
  | `Assoc fields
    when exact_fields
           [ "encodedTx"
           ; "mutationFingerprint"
           ; "mutationId"
           ; "mutationPayload"
           ; "outlinerOp"
           ; "state"
           ]
           fields ->
    (match
       ( List.assoc_opt "mutationId" fields
       , List.assoc_opt "mutationPayload" fields
       , List.assoc_opt "mutationFingerprint" fields
       , List.assoc_opt "outlinerOp" fields
       , List.assoc_opt "state" fields
       , List.assoc_opt "encodedTx" fields )
     with
     | ( Some (`String mutation_id)
       , Some (`String mutation_payload)
       , Some (`String mutation_fingerprint)
       , Some (`String outliner_op)
       , Some state
       , Some (`String encoded_tx) )
       when String.length mutation_payload > 0
            && String.length mutation_payload
               <= Logseq_db_types.Limits.maximum_request_bytes
            && String.length mutation_fingerprint > 0
            && String.length mutation_fingerprint <= 256
            && String.length outliner_op > 0
            && String.length outliner_op <= 128
            && String.length encoded_tx > 0
            && String.length encoded_tx <= Logseq_db_types.Limits.maximum_request_bytes ->
       Result.bind
         (Logseq_db_types.Graph_types.Uuid.of_string mutation_id)
         (fun mutation_id ->
            Result.map
              (fun outbox_state ->
                 { mutation_id
                 ; mutation_payload
                 ; mutation_fingerprint
                 ; encoded_tx
                 ; outliner_op
                 ; outbox_state
                 })
              (outbox_state_of_json state))
     | _ -> Error "invalid outbox record")
  | _ -> Error "invalid outbox record"
;;

let maximum_outbox_bytes = 8 * 1024 * 1024
let maximum_outbox_records = 4096

let validate_outbox records =
  if List.length records > maximum_outbox_records
  then Error "too many outbox records"
  else (
    let size =
      records
      |> List.map outbox_record_to_json
      |> fun records -> `List records |> Yojson.Safe.to_string |> String.length
    in
    if size > maximum_outbox_bytes
    then Error "outbox data exceeds its durable bound"
    else Ok records)
;;

let encode_outbox_records records =
  Result.map
    (List.map (fun record -> Yojson.Safe.to_string (outbox_record_to_json record)))
    (validate_outbox records)
;;

let decode_outbox_records encoded =
  if List.length encoded > maximum_outbox_records
  then Error "too many outbox records"
  else (
    let rec loop records = function
      | [] -> validate_outbox (List.rev records)
      | source :: rest ->
        (try
           Result.bind
             (outbox_record_of_json (Yojson.Safe.from_string source))
             (fun record -> loop (record :: records) rest)
         with
         | Yojson.Json_error _ -> Error "outbox data is corrupt")
    in
    loop [] encoded)
;;

module Transit = Transit_core.Json
module Transit_codec = Transit_native.Transit.Json

let protected_attributes = [ "block/title"; "block/name" ]

let lookup_value entity attr =
  match Datascript.Entity.entity_attr_raw entity attr with
  | Some (Datascript.One_value value) -> Some value
  | Some (Datascript.One_entity _ | Many_values _ | Many_entities _) | None -> None
;;

let stable_entity_ref db eid =
  match Datascript.entity db (Datascript.Entity_id eid) with
  | Some entity ->
    (match lookup_value entity "block/uuid", lookup_value entity "db/ident" with
     | Some (Datascript.Uuid uuid), _ ->
       Datascript.Lookup_ref ("block/uuid", Datascript.Uuid uuid)
     | _, Some (Datascript.Keyword ident) ->
       Datascript.Lookup_ref ("db/ident", Datascript.Keyword ident)
     | _ -> Datascript.Entity_id eid)
  | None -> Datascript.Entity_id eid
;;

let rec transit_of_entity_ref db = function
  | Datascript.Entity_id eid ->
    (match stable_entity_ref db eid with
     | Datascript.Entity_id stable_eid -> Transit.Int stable_eid
     | stable_ref -> transit_of_entity_ref db stable_ref)
  | Temp_id temp_id -> Transit.String temp_id
  | CurrentTx -> Transit.Keyword "db/current-tx"
  | Ident ident -> Transit.Keyword ident
  | Lookup_ref (attr, value) ->
    Transit.Array [ Transit.Keyword attr; transit_of_value db value ]

and transit_of_value db = function
  | Datascript.Nil -> Transit.Null
  | Int value -> Transit.Int value
  | Float value -> Transit.Float value
  | String value -> Transit.String value
  | Symbol value -> Transit.Symbol value
  | Bool value -> Transit.Bool value
  | Keyword value -> Transit.Keyword value
  | Uuid value -> Transit.Uuid value
  | Instant value -> Transit.Date (Int64.of_int value)
  | Regex value -> Transit.Tagged ("regex", Transit.String value)
  | Ref eid -> transit_of_entity_ref db (stable_entity_ref db eid)
  | List values -> Transit.List (List.map (transit_of_value db) values)
  | Vector values -> Transit.Array (List.map (transit_of_value db) values)
  | Map entries ->
    Transit.Map
      (List.map
         (fun (key, value) -> transit_of_value db key, transit_of_value db value)
         entries)
  | Set values -> Transit.Set (List.map (transit_of_value db) values)
  | Tuple values ->
    Transit.Array
      (List.map (Option.fold ~none:Transit.Null ~some:(transit_of_value db)) values)
  | TxRef -> Transit.Keyword "db/current-tx"
  | Ref_to entity_ref -> transit_of_entity_ref db entity_ref
;;

let transit_of_tx_op db = function
  | Datascript.Add (entity_ref, attr, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/add"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity_ref, attr, Some value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retract"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity_ref, attr, None) | RetractAttr (entity_ref, attr) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/retractAttribute"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ])
  | RetractEntity entity_ref ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retractEntity"; transit_of_entity_ref db entity_ref ])
  | CompareAndSet (entity_ref, attr, expected, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/cas"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; Option.fold ~none:Transit.Null ~some:(transit_of_value db) expected
         ; transit_of_value db value
         ])
  | Raw_datom datom ->
    Ok
      (Transit.Array
         [ Transit.Keyword (if datom.added then "db/add" else "db/retract")
         ; transit_of_entity_ref db (stable_entity_ref db datom.e)
         ; Transit.Keyword datom.a
         ; transit_of_value db datom.v
         ])
  | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
    Error "complex transaction forms cannot be sent over sync"
;;

let encode_operations database operations =
  let rec loop encoded = function
    | [] ->
      Ok
        (Transit_codec.to_string
           ~mode:Transit_codec.Verbose
           (Transit.Array (List.rev encoded)))
    | operation :: rest ->
      Result.bind (transit_of_tx_op database operation) (fun encoded_operation ->
        loop (encoded_operation :: encoded) rest)
  in
  loop [] operations
;;

let plaintext_of_value attribute = function
  | Datascript.String plaintext when List.mem attribute protected_attributes ->
    Ok (Some (Transit_codec.to_string (Transit.String plaintext)))
  | String _ -> Ok None
  | _ when List.mem attribute protected_attributes ->
    Error ("protected attribute " ^ attribute ^ " must be a string")
  | _ -> Ok None
;;

let protected_plaintexts operations =
  let add_value acc attribute value =
    Result.map
      (function
        | None -> acc
        | Some plaintext -> plaintext :: acc)
      (plaintext_of_value attribute value)
  in
  let add_operation acc = function
    | Datascript.Add (_, attribute, value) | Retract (_, attribute, Some value) ->
      add_value acc attribute value
    | CompareAndSet (_, attribute, expected, value) ->
      Result.bind
        (match expected with
         | None -> Ok acc
         | Some expected -> add_value acc attribute expected)
        (fun acc -> add_value acc attribute value)
    | Raw_datom datom -> add_value acc datom.a datom.v
    | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
      Error "complex transaction forms cannot be sent over sync"
    | Retract (_, _, None) | RetractAttr _ | RetractEntity _ -> Ok acc
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | operation :: rest ->
      Result.bind (add_operation acc operation) (fun acc -> loop acc rest)
  in
  loop [] operations
;;

let encrypted_wire_value (iv, ciphertext) =
  Transit_codec.to_string (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ])
  |> fun value -> Datascript.String value
;;

let replace_value attribute value encrypted =
  if List.mem attribute protected_attributes
  then (
    match value, encrypted with
    | Datascript.String _, next :: rest -> Ok (encrypted_wire_value next, rest)
    | String _, [] -> Error "encrypted value count does not match protected values"
    | _, _ -> Error ("protected attribute " ^ attribute ^ " must be a string"))
  else Ok (value, encrypted)
;;

let replace_protected_values operations encrypted =
  let replace_operation operation encrypted =
    match operation with
    | Datascript.Add (entity, attribute, value) ->
      Result.map
        (fun (value, rest) -> Datascript.Add (entity, attribute, value), rest)
        (replace_value attribute value encrypted)
    | Retract (entity, attribute, Some value) ->
      Result.map
        (fun (value, rest) -> Datascript.Retract (entity, attribute, Some value), rest)
        (replace_value attribute value encrypted)
    | CompareAndSet (entity, attribute, expected, value) ->
      Result.bind
        (match expected with
         | None -> Ok (None, encrypted)
         | Some expected ->
           Result.map
             (fun (expected, rest) -> Some expected, rest)
             (replace_value attribute expected encrypted))
        (fun (expected, encrypted) ->
           Result.map
             (fun (value, rest) ->
                Datascript.CompareAndSet (entity, attribute, expected, value), rest)
             (replace_value attribute value encrypted))
    | Raw_datom datom ->
      Result.map
        (fun (value, rest) -> Datascript.Raw_datom { datom with v = value }, rest)
        (replace_value datom.a datom.v encrypted)
    | (Retract (_, _, None) | RetractAttr _ | RetractEntity _) as operation ->
      Ok (operation, encrypted)
    | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
      Error "complex transaction forms cannot be sent over sync"
  in
  let rec loop replaced encrypted = function
    | [] ->
      if encrypted = []
      then Ok (List.rev replaced)
      else Error "encrypted value count does not match protected values"
    | operation :: rest ->
      Result.bind (replace_operation operation encrypted) (fun (operation, encrypted) ->
        loop (operation :: replaced) encrypted rest)
  in
  loop [] encrypted operations
;;

type local_batch_input =
  { local_scope : graph_scope
  ; local_admission_id : string
  ; local_key : graph_key_handle option
  ; local_outbox : outbox_record list
  ; local_mutation_id : graph_id
  ; local_mutation_payload : string
  ; local_mutation_fingerprint : string
  ; local_outliner_op : string
  ; local_database : Datascript.db
  ; local_operations : Datascript.tx_op list
  }

type local_batch_plan =
  { local_input : local_batch_input
  ; local_plaintexts : string list
  }

let local_batch_input
      ~scope
      ~admission_id
      ~key
      ~outbox_records
      ~mutation_id
      ~mutation_payload
      ~mutation_fingerprint
      ~outliner_op
      ~database
      ~operations
  =
  if String.length admission_id = 0 || String.length admission_id > 256
  then Error "mutation admission ID must contain 1..256 bytes"
  else if String.length mutation_payload = 0
  then Error "mutation payload must not be empty"
  else if String.length mutation_fingerprint = 0
  then Error "mutation fingerprint must not be empty"
  else if String.length outliner_op = 0
  then Error "outliner operation must not be empty"
  else
    Result.map
      (fun local_outbox ->
         { local_scope = scope
         ; local_admission_id = admission_id
         ; local_key = key
         ; local_outbox
         ; local_mutation_id = mutation_id
         ; local_mutation_payload = mutation_payload
         ; local_mutation_fingerprint = mutation_fingerprint
         ; local_outliner_op = outliner_op
         ; local_database = database
         ; local_operations = operations
         })
      (decode_outbox_records outbox_records)
;;

let local_batch_input_scope input = input.local_scope
let local_batch_input_mutation_id input = input.local_mutation_id
let local_batch_input_fingerprint input = input.local_mutation_fingerprint

let begin_local_batch local_input =
  Result.bind (protected_plaintexts local_input.local_operations) (fun local_plaintexts ->
    match local_plaintexts, local_input.local_key with
    | _ :: _, None -> Error "protected mutation requires a graph key handle"
    | _ :: _, Some key when key.handle_scope <> local_input.local_scope ->
      Error "graph key handle is outside the mutation scope"
    | [], _ | _ :: _, Some _ -> Ok { local_input; local_plaintexts })
;;

let local_batch_crypto_request plan =
  match plan.local_plaintexts, plan.local_input.local_key with
  | [], _ -> None
  | _ :: _, None -> None
  | plaintexts, Some key -> Some { scope = plan.local_input.local_scope; key; plaintexts }
;;

let finish_local_batch plan encrypted_values =
  let operations =
    match plan.local_plaintexts, encrypted_values with
    | [], None -> Ok plan.local_input.local_operations
    | [], Some [] -> Ok plan.local_input.local_operations
    | [], Some (_ :: _) -> Error "encrypted values were supplied for a plaintext batch"
    | _ :: _, None -> Error "encrypted values are required for protected attributes"
    | _ :: _, Some encrypted ->
      replace_protected_values plan.local_input.local_operations encrypted
  in
  Result.bind operations (fun operations ->
    Result.bind
      (encode_operations plan.local_input.local_database operations)
      (fun encoded_tx ->
         let record =
           { mutation_id = plan.local_input.local_mutation_id
           ; mutation_payload = plan.local_input.local_mutation_payload
           ; mutation_fingerprint = plan.local_input.local_mutation_fingerprint
           ; encoded_tx
           ; outliner_op = plan.local_input.local_outliner_op
           ; outbox_state = Queued
           }
         in
         if
           List.exists
             (fun current ->
                Logseq_db_types.Graph_types.Uuid.equal
                  current.mutation_id
                  record.mutation_id)
             plan.local_input.local_outbox
         then Error "pending mutation ID already exists"
         else
           Result.map
             (fun _ -> record)
             (validate_outbox (plan.local_input.local_outbox @ [ record ]))))
;;

type snapshot_baseline = string
type snapshot_metadata = string

type snapshot_download =
  { scope : authorized_graph_scope
  ; uri : Uri.t
  ; expected_bytes : int64 option
  ; maximum_bytes : int
  }

type graph_key_request =
  { scope : authorized_graph_scope
  ; encrypted_graph_key : string
  }

type private_key_unlock =
  { scope : authenticated_account_scope
  ; password : string
  ; private_key_package : string
  }

type _ runner_request =
  | Load_catalog : account_scope -> catalog_cache option runner_request
  | Save_catalog :
      { account : account_scope
      ; cache : catalog_cache
      }
      -> unit runner_request
  | Fetch_catalog : authenticated_account_scope -> graph list runner_request
  | Fetch_snapshot_baseline : authorized_graph_scope -> snapshot_baseline runner_request
  | Fetch_snapshot_metadata : authorized_graph_scope -> snapshot_metadata runner_request
  | Download_snapshot : snapshot_download -> staged_artifact runner_request
  | Fetch_e2ee_graph_key : authorized_graph_scope -> string runner_request
  | Fetch_e2ee_user_keys : authenticated_account_scope -> string runner_request
  | Load_and_unlock_graph_key : graph_scope -> graph_key_handle runner_request
  | Fetch_and_unlock_graph_key : graph_key_request -> graph_key_handle runner_request
  | Unlock_private_key : private_key_unlock -> unit runner_request
  | Encrypt_protected_values : encryption_batch -> encrypted_values runner_request
  | Decrypt_protected_values : decryption_batch -> decrypted_values runner_request

type _ request_kind =
  | Load_catalog_kind : catalog_cache option request_kind
  | Save_catalog_kind : unit request_kind
  | Fetch_catalog_kind : graph list request_kind
  | Fetch_snapshot_baseline_kind : snapshot_baseline request_kind
  | Fetch_snapshot_metadata_kind : snapshot_metadata request_kind
  | Download_snapshot_kind : staged_artifact request_kind
  | Fetch_e2ee_graph_key_kind : string request_kind
  | Fetch_e2ee_user_keys_kind : string request_kind
  | Load_and_unlock_graph_key_kind : graph_key_handle request_kind
  | Fetch_and_unlock_graph_key_kind : graph_key_handle request_kind
  | Unlock_private_key_kind : unit request_kind
  | Encrypt_protected_values_kind : encrypted_values request_kind
  | Decrypt_protected_values_kind : decrypted_values request_kind

type 'a effect_ticket =
  { id : effect_id
  ; scope : effect_scope
  ; kind : 'a request_kind
  }

let effect_ticket_id ticket = ticket.id
let effect_ticket_scope ticket = ticket.scope
let effect_id_to_string id = string_of_int id

type websocket_request =
  { scope : connection_scope
  ; uri : Uri.t
  ; token : string
  }

type websocket_send =
  { scope : connection_scope
  ; message : Sync_protocol.Client.message
  }

type timer_id = int

type timer_request =
  { id : timer_id
  ; scope : effect_scope
  ; delay_seconds : float
  }

type runner_effect =
  | Request : 'a effect_ticket * 'a runner_request -> runner_effect
  | Start_websocket of websocket_request
  | Send_websocket of websocket_send
  | Close_websocket of connection_scope
  | Schedule_timer of timer_request
  | Cancel_effects of effect_scope

type runner_completion =
  | Completion : 'a effect_ticket * ('a, effect_error) result -> runner_completion

let effect_scope_of_account (account : account_scope) =
  { account_generation = Some account.account_generation
  ; graph_generation = None
  ; connection_generation = None
  ; presentation_generation = Some account.presentation_generation
  ; lifecycle_generation = Some account.lifecycle_generation
  }
;;

let effect_scope_of_graph (graph : graph_scope) =
  { (effect_scope_of_account graph.account) with
    graph_generation = Some graph.graph_generation
  }
;;

let effect_scope_of_connection (connection : connection_scope) =
  { (effect_scope_of_graph connection.graph) with
    connection_generation = Some connection.connection_generation
  }
;;

let scope_of_request : type a. a runner_request -> effect_scope = function
  | Load_catalog account -> effect_scope_of_account account
  | Save_catalog { account; _ } -> effect_scope_of_account account
  | Fetch_catalog authenticated -> effect_scope_of_account authenticated.account
  | Fetch_snapshot_baseline authorized | Fetch_snapshot_metadata authorized ->
    effect_scope_of_graph authorized.graph
  | Download_snapshot download -> effect_scope_of_graph download.scope.graph
  | Fetch_e2ee_graph_key authorized -> effect_scope_of_graph authorized.graph
  | Fetch_e2ee_user_keys authenticated -> effect_scope_of_account authenticated.account
  | Load_and_unlock_graph_key graph -> effect_scope_of_graph graph
  | Fetch_and_unlock_graph_key request -> effect_scope_of_graph request.scope.graph
  | Unlock_private_key request -> effect_scope_of_account request.scope.account
  | Encrypt_protected_values request -> effect_scope_of_graph request.scope
  | Decrypt_protected_values request -> effect_scope_of_graph request.scope
;;

let runner_effect_scope = function
  | Request (ticket, _) -> ticket.scope
  | Start_websocket request -> effect_scope_of_connection request.scope
  | Send_websocket request -> effect_scope_of_connection request.scope
  | Close_websocket connection -> effect_scope_of_connection connection
  | Schedule_timer request -> request.scope
  | Cancel_effects scope -> scope
;;

let scope_diagnostic scope =
  let option show = function
    | None -> "*"
    | Some value -> show value
  in
  String.concat
    "/"
    [ option string_of_int scope.account_generation
    ; option string_of_int scope.graph_generation
    ; option string_of_int scope.connection_generation
    ; option string_of_int scope.presentation_generation
    ; option Int64.to_string scope.lifecycle_generation
    ]
;;

let request_name : type a. a runner_request -> string = function
  | Load_catalog _ -> "load_catalog"
  | Save_catalog _ -> "save_catalog"
  | Fetch_catalog _ -> "fetch_catalog"
  | Fetch_snapshot_baseline _ -> "fetch_snapshot_baseline"
  | Fetch_snapshot_metadata _ -> "fetch_snapshot_metadata"
  | Download_snapshot _ -> "download_snapshot"
  | Fetch_e2ee_graph_key _ -> "fetch_e2ee_graph_key"
  | Fetch_e2ee_user_keys _ -> "fetch_e2ee_user_keys"
  | Load_and_unlock_graph_key _ -> "load_and_unlock_graph_key"
  | Fetch_and_unlock_graph_key _ -> "fetch_and_unlock_graph_key"
  | Unlock_private_key _ -> "unlock_private_key"
  | Encrypt_protected_values _ -> "encrypt_protected_values"
  | Decrypt_protected_values _ -> "decrypt_protected_values"
;;

let runner_effect_diagnostic = function
  | Request (ticket, request) ->
    Printf.sprintf
      "request:%d:%s:%s"
      ticket.id
      (request_name request)
      (scope_diagnostic ticket.scope)
  | Start_websocket request ->
    "start_websocket:" ^ scope_diagnostic (effect_scope_of_connection request.scope)
  | Send_websocket request ->
    "send_websocket:" ^ scope_diagnostic (effect_scope_of_connection request.scope)
  | Close_websocket scope ->
    "close_websocket:" ^ scope_diagnostic (effect_scope_of_connection scope)
  | Schedule_timer request ->
    Printf.sprintf
      "schedule_timer:%d:%s:%g"
      request.id
      (scope_diagnostic request.scope)
      request.delay_seconds
  | Cancel_effects scope -> "cancel_effects:" ^ scope_diagnostic scope
;;

let equal_runner_request : type a b. a runner_request -> b runner_request -> bool =
  fun left right ->
  match left, right with
  | Load_catalog left, Load_catalog right -> left = right
  | ( Save_catalog { account = left_account; cache = left_cache }
    , Save_catalog { account = right_account; cache = right_cache } ) ->
    left_account = right_account && left_cache = right_cache
  | Fetch_catalog left, Fetch_catalog right -> left = right
  | Fetch_snapshot_baseline left, Fetch_snapshot_baseline right -> left = right
  | Fetch_snapshot_metadata left, Fetch_snapshot_metadata right -> left = right
  | Download_snapshot left, Download_snapshot right -> left = right
  | Fetch_e2ee_graph_key left, Fetch_e2ee_graph_key right -> left = right
  | Fetch_e2ee_user_keys left, Fetch_e2ee_user_keys right -> left = right
  | Load_and_unlock_graph_key left, Load_and_unlock_graph_key right -> left = right
  | Fetch_and_unlock_graph_key left, Fetch_and_unlock_graph_key right -> left = right
  | Unlock_private_key left, Unlock_private_key right -> left = right
  | Encrypt_protected_values left, Encrypt_protected_values right -> left = right
  | Decrypt_protected_values left, Decrypt_protected_values right -> left = right
  | _ -> false
;;

let equal_runner_effect left right =
  match left, right with
  | Request (left_ticket, left_request), Request (right_ticket, right_request) ->
    left_ticket.id = right_ticket.id
    && left_ticket.scope = right_ticket.scope
    && equal_runner_request left_request right_request
  | Start_websocket left, Start_websocket right -> left = right
  | Send_websocket left, Send_websocket right -> left = right
  | Close_websocket left, Close_websocket right -> left = right
  | Schedule_timer left, Schedule_timer right -> left = right
  | Cancel_effects left, Cancel_effects right -> left = right
  | ( Request _
    , ( Start_websocket _
      | Send_websocket _
      | Close_websocket _
      | Schedule_timer _
      | Cancel_effects _ ) )
  | ( Start_websocket _
    , ( Request _
      | Send_websocket _
      | Close_websocket _
      | Schedule_timer _
      | Cancel_effects _ ) )
  | ( Send_websocket _
    , ( Request _
      | Start_websocket _
      | Close_websocket _
      | Schedule_timer _
      | Cancel_effects _ ) )
  | ( Close_websocket _
    , ( Request _
      | Start_websocket _
      | Send_websocket _
      | Schedule_timer _
      | Cancel_effects _ ) )
  | ( Schedule_timer _
    , ( Request _
      | Start_websocket _
      | Send_websocket _
      | Close_websocket _
      | Cancel_effects _ ) )
  | ( Cancel_effects _
    , ( Request _
      | Start_websocket _
      | Send_websocket _
      | Close_websocket _
      | Schedule_timer _ ) ) -> false
;;

type mirror_request =
  { graph : graph
  ; scope : graph_scope
  }

type snapshot_activation_request =
  { artifact : staged_artifact
  ; scope : graph_scope
  ; applied_server_t : int
  ; key : graph_key_handle option
  }

type mirror_deletion =
  { graph_id : graph_id
  ; scope : effect_scope
  }

type graph_open_request =
  { graph : graph
  ; graph_directory : string
  ; database_path : string
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; scope : graph_scope
  }

type mirror_inspection =
  | Mirror_available of graph_open_request
  | Mirror_absent of graph_scope

type local_batch_failure_kind =
  | Planning_failed
  | Encryption_failed
  | Encoding_failed
  | Scope_closed
  | Engine_unavailable
  | Persistence_failed

type local_batch_action =
  | Commit of { outbox_records : string list }
  | Reject of
      { kind : local_batch_failure_kind
      ; message : string
      }

type local_batch_completion_request =
  { operation_id : graph_id
  ; admission_id : string
  ; scope : graph_scope
  ; action : local_batch_action
  }

type authoritative_batch =
  { message : Sync_protocol.Server.message
  ; scope : connection_scope
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  }

type authoritative_context =
  { batch : authoritative_batch
  ; precondition : string
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; database : Datascript.db
  ; outbox_records : string list
  }

type authoritative_plan =
  { authoritative_context : authoritative_context
  ; authoritative_wires : string list
  ; authoritative_outbox : outbox_record list
  ; authoritative_protected_values : (string * string) list
  ; authoritative_key : graph_key_handle option
  }

type authoritative_commit_request =
  { batch : authoritative_batch
  ; precondition : string
  ; scope : graph_scope
  ; key : graph_key_handle option
  ; transactions : Datascript.tx_op list list
  ; projection_transactions : Datascript.tx_op list list
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  ; activity : Logseq_db_types.Sync_status.activity
  }

let protected_envelope source =
  try
    match Transit_codec.of_string source with
    | Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ] -> Ok (iv, ciphertext)
    | _ -> Error "protected value has an invalid encryption envelope"
  with
  | Transit.Decode_error message -> Error message
;;

let collect_protected_values wires =
  let rec collect values = function
    | [] -> Ok (List.rev values |> List.concat)
    | wire :: rest ->
      Result.bind (Pure_tx.protected_values wire) (fun protected ->
        let rec decode decoded = function
          | [] -> Ok (List.rev decoded)
          | source :: remaining ->
            Result.bind (protected_envelope source) (fun value ->
              decode (value :: decoded) remaining)
        in
        Result.bind (decode [] protected) (fun decoded ->
          collect (decoded :: values) rest))
  in
  collect [] wires
;;

let validate_pull_continuity applied_server_t server_t transactions =
  if server_t < applied_server_t
  then Error "pull response is older than the applied server cursor"
  else if server_t = applied_server_t
  then
    if
      List.for_all
        (fun (transaction : Sync_protocol.Server.pull_transaction) ->
           transaction.t <= applied_server_t)
        transactions
    then Ok ()
    else Error "duplicate pull contains a future transaction"
  else (
    let rec loop expected = function
      | [] ->
        if expected - 1 = server_t
        then Ok ()
        else Error "pull response cursor does not match its final transaction"
      | (transaction : Sync_protocol.Server.pull_transaction) :: rest ->
        if transaction.t = expected
        then loop (expected + 1) rest
        else Error "pull response contains a server cursor gap"
    in
    loop (applied_server_t + 1) transactions)
;;

let begin_authoritative_batch
      ?(acknowledged_mutation_ids = [])
      (context : authoritative_context)
  =
  Result.bind (decode_outbox_records context.outbox_records) (fun outbox ->
    let message = context.batch.message in
    let prepared =
      match message with
      | Sync_protocol.Server.Pull_ok { t; txs; _ } ->
        Result.bind
          (validate_pull_continuity context.checkpoint.applied_server_t t txs)
          (fun () ->
             let wires =
               if t = context.checkpoint.applied_server_t
               then []
               else
                 List.map
                   (fun (transaction : Sync_protocol.Server.pull_transaction) ->
                      transaction.tx)
                   txs
             in
             Ok
               ( wires
               , List.filter
                   (fun record ->
                      match record.outbox_state with
                      | Accepted accepted_t -> accepted_t > t
                      | Queued | Submitted | Blocked _ -> true)
                   outbox ))
      | Sync_protocol.Server.Hello _ | Changed _ -> Ok ([], outbox)
      | Sync_protocol.Server.Tx_batch_ok { t; _ } ->
        Ok
          ( []
          , List.map
              (fun record ->
                 if
                   List.exists
                     (Logseq_db_types.Graph_types.Uuid.equal record.mutation_id)
                     acknowledged_mutation_ids
                 then (
                   match record.outbox_state with
                   | Submitted -> { record with outbox_state = Accepted t }
                   | Queued | Accepted _ | Blocked _ -> record)
                 else record)
              outbox )
      | Sync_protocol.Server.Online_users _ | Presence _ | Tx_reject _ | Pong | Error _ ->
        Error "server message is not authoritative"
    in
    Result.bind prepared (fun (wires, outbox) ->
      Result.bind (collect_protected_values wires) (fun values ->
        Ok
          { authoritative_context = context
          ; authoritative_wires = wires
          ; authoritative_outbox = outbox
          ; authoritative_protected_values = values
          ; authoritative_key = None
          })))
;;

let authoritative_crypto_request plan =
  match plan.authoritative_protected_values, plan.authoritative_key with
  | [], _ | _ :: _, None -> None
  | protected_values, Some key ->
    Some { scope = plan.authoritative_context.batch.scope.graph; key; protected_values }
;;

let split_at count values =
  let rec loop remaining prefix values =
    if remaining = 0
    then Ok (List.rev prefix, values)
    else (
      match values with
      | [] -> Error "decrypted value count does not match protected values"
      | value :: rest -> loop (remaining - 1) (value :: prefix) rest)
  in
  loop count [] values
;;

let decode_authoritative_transactions database wires decrypted =
  let rec loop database transactions decrypted = function
    | [] -> Ok (List.rev transactions, database, decrypted)
    | wire :: rest ->
      Result.bind (Pure_tx.protected_values wire) (fun protected ->
        Result.bind
          (split_at (List.length protected) decrypted)
          (fun (values, decrypted) ->
             Result.bind
               (Pure_tx.decode ~db:database ~decrypted_values:values wire)
               (fun operations ->
                  try
                    let database = Datascript.db_with operations database in
                    loop database (operations :: transactions) decrypted rest
                  with
                  | exception_ -> Error (Printexc.to_string exception_))))
  in
  loop database [] decrypted wires
;;

let checkpoint_advanced checkpoint applied_server_t checksum =
  Logseq_db_types.Sync_checkpoint.create_full
    ~graph_id:checkpoint.Logseq_db_types.Sync_checkpoint.graph_id
    ~schema:checkpoint.schema
    ~applied_server_t
    ~checksum
    ~status:Logseq_db_types.Sync_checkpoint.Active
    ~last_error:None
;;

let checkpoint_paused checkpoint message =
  Logseq_db_types.Sync_checkpoint.create_full
    ~graph_id:checkpoint.Logseq_db_types.Sync_checkpoint.graph_id
    ~schema:checkpoint.schema
    ~applied_server_t:checkpoint.applied_server_t
    ~checksum:checkpoint.checksum
    ~status:Logseq_db_types.Sync_checkpoint.Paused
    ~last_error:(Some message)
;;

let finish_authoritative_batch plan decrypted_values =
  let decrypted_values =
    match plan.authoritative_protected_values, decrypted_values with
    | [], None | [], Some [] -> Ok []
    | [], Some (_ :: _) -> Error "unexpected decrypted values"
    | _ :: _, None -> Error "decrypted values are required"
    | protected, Some values when List.length protected = List.length values -> Ok values
    | _ :: _, Some _ -> Error "decrypted value count does not match protected values"
  in
  Result.bind decrypted_values (fun decrypted ->
    let context = plan.authoritative_context in
    let authoritative_wires =
      match context.batch.message with
      | Sync_protocol.Server.Pull_ok _ -> Ok plan.authoritative_wires
      | Sync_protocol.Server.Hello _ | Changed _ | Tx_batch_ok _ -> Ok []
      | Sync_protocol.Server.Online_users _ | Presence _ | Tx_reject _ | Pong | Error _ ->
        Error "server message is not authoritative"
    in
    Result.bind authoritative_wires (fun authoritative_wires ->
      Result.bind
        (decode_authoritative_transactions context.database authoritative_wires decrypted)
        (fun (transactions, database_after, decrypted) ->
           if decrypted <> []
           then Error "decrypted value count does not match protected values"
           else
             Result.bind
               (encode_outbox_records plan.authoritative_outbox)
               (fun outbox_records ->
                  let outcome =
                    match context.batch.message with
                    | Sync_protocol.Server.Pull_ok { t; checksum = _; _ }
                      when t = context.checkpoint.applied_server_t ->
                      Ok
                        ( context.checkpoint
                        , Logseq_db_types.Sync_status.Pull_duplicate
                        , [] )
                    | Sync_protocol.Server.Pull_ok { t; checksum; _ } ->
                      let local_checksum = recompute_checksum database_after in
                      (match checksum with
                       | Some remote when not (String.equal remote local_checksum) ->
                         let message =
                           Printf.sprintf
                             "Entity checksum mismatch at server t %d (local %s, remote \
                              %s)."
                             t
                             local_checksum
                             remote
                         in
                         Ok
                           ( checkpoint_paused context.checkpoint message |> Result.get_ok
                           , Logseq_db_types.Sync_status.Sync_paused
                           , [] )
                       | None | Some _ ->
                         Ok
                           ( checkpoint_advanced
                               context.checkpoint
                               t
                               (Option.value checksum ~default:local_checksum)
                             |> Result.get_ok
                           , Logseq_db_types.Sync_status.Pull_applied
                           , transactions ))
                    | Sync_protocol.Server.Hello _ | Changed _ | Tx_batch_ok _ ->
                      Ok
                        (context.checkpoint, Logseq_db_types.Sync_status.Pull_required, [])
                    | Sync_protocol.Server.Online_users _
                    | Presence _
                    | Tx_reject _
                    | Pong
                    | Error _ -> Error "server message is not authoritative"
                  in
                  Result.map
                    (fun (checkpoint, activity, transactions) ->
                       { batch = context.batch
                       ; precondition = context.precondition
                       ; scope = context.batch.scope.graph
                       ; key = plan.authoritative_key
                       ; transactions
                       ; projection_transactions = []
                       ; checkpoint
                       ; outbox_records
                       ; activity
                       })
                    outcome))))
;;

type outbox_transition =
  { scope : graph_scope
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  ; expected_outbox_records : string list
  ; outbox_records : string list
  ; pending_message : Sync_protocol.Client.message option
  }

type worker_effect =
  | Inspect_mirror of mirror_request
  | Activate_snapshot of snapshot_activation_request
  | Delete_mirror of mirror_deletion
  | Attach_graph of graph_open_request
  | Detach_graph of graph_scope
  | Reset_managed_account of account_scope
  | Complete_local_batch of local_batch_completion_request
  | Inspect_authoritative_batch of authoritative_batch
  | Apply_authoritative_batch of authoritative_commit_request
  | Commit_outbox_transition of outbox_transition

type output =
  | State_changed of state
  | Token_requested of token_request
  | Bootstrap_progressed of bootstrap_progress
  | Graph_invalidated of invalidation

type instruction =
  | Run of runner_effect
  | Delegate of worker_effect
  | Publish of output

let equal_instruction left right =
  match left, right with
  | Run left, Run right -> equal_runner_effect left right
  | Delegate left, Delegate right -> left = right
  | Publish left, Publish right -> left = right
  | Run _, (Delegate _ | Publish _)
  | Delegate _, (Run _ | Publish _)
  | Publish _, (Run _ | Delegate _) -> false
;;

let rec equal_instructions left right =
  match left, right with
  | [], [] -> true
  | left :: left_rest, right :: right_rest ->
    equal_instruction left right && equal_instructions left_rest right_rest
  | [], _ :: _ | _ :: _, [] -> false
;;

type scoped_error =
  { scope : effect_scope
  ; message : string
  }

type graph_attachment =
  { scope : graph_scope
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  }

type local_batch_commit =
  { scope : graph_scope
  ; outbox_records : string list
  }

type authoritative_commit_result =
  { scope : graph_scope
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  ; activity : Logseq_db_types.Sync_status.activity
  ; invalidation : invalidation option
  }

type outbox_transition_commit =
  { scope : graph_scope
  ; outbox_records : string list
  ; pending_message : Sync_protocol.Client.message option
  }

type outbox_transition_rejection =
  { scope : graph_scope
  ; outbox_records : string list
  ; message : string
  }

type snapshot_activation = { scope : graph_scope }

type event =
  | Restore_local_account of { user_id : string }
  | Account_authenticated of { user_id : string option }
  | Local_feed_acknowledged
  | Timeline_presented
  | Token_provided of token_request * string
  | Token_rejected of token_request
  | Graph_selected of graph_id
  | Graph_picker_requested
  | Catalog_refresh_requested
  | Online_recovery_requested
  | E2ee_password_submitted of string
  | Local_cache_deletion_requested of graph_id
  | Foreground_changed of
      { foreground : bool
      ; lifecycle_generation : lifecycle_generation
      }
  | Mirror_inspected of mirror_inspection
  | Graph_attached of graph_attachment
  | Graph_attachment_failed of scoped_error
  | Local_batch_prepared of local_batch_input
  | Local_batch_committed of local_batch_commit
  | Authoritative_batch_inspected of authoritative_context
  | Authoritative_batch_applied of authoritative_commit_result
  | Authoritative_batch_conflicted of authoritative_batch
  | Authoritative_batch_failed of scoped_error
  | Outbox_transition_committed of outbox_transition_commit
  | Outbox_transition_rejected of outbox_transition_rejection
  | Snapshot_activated of snapshot_activation
  | Snapshot_activation_failed of scoped_error
  | Runner_completed of runner_completion
  | Snapshot_download_progress of bootstrap_progress
  | Websocket_opened of connection_scope
  | Websocket_message of connection_scope * Sync_protocol.Server.message
  | Websocket_protocol_error of connection_scope * Sync_protocol.codec_error
  | Websocket_closed of connection_scope * string option
  | Timer_elapsed of timer_id
  | Shutdown

type pending_effect = int

type snapshot_bootstrap_phase =
  | Snapshot_bootstrap_idle
  | Snapshot_bootstrap_waiting_for_key
  | Snapshot_bootstrap_waiting_for_token
  | Snapshot_bootstrap_fetching_baseline
  | Snapshot_bootstrap_fetching_metadata
  | Snapshot_bootstrap_downloading
  | Snapshot_bootstrap_activating

type submission_phase =
  | Submission_reserving
  | Submission_dispatched
  | Submission_applying_ack of int
  | Submission_awaiting_pull of int

type submission_owner =
  { mutation_ids : graph_id list
  ; t_before : int
  ; message : Sync_protocol.Client.message
  ; reserved_outbox_records : string list
  ; connection : connection_scope
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  ; phase : submission_phase
  }

type t =
  { config : config
  ; public_state : state
  ; user_id : string option
  ; lifecycle_generation : lifecycle_generation
  ; next_effect_id : int
  ; next_graph_token_id : int
  ; pending_token : token_request option
  ; deferred_catalog_reconciliation : bool
  ; local_presentation_barrier : bool
  ; pending_effects : pending_effect list
  ; pending_local_batches : (effect_id * local_batch_plan) list
  ; pending_local_commits : local_batch_commit list
  ; graph_key : graph_key_handle option
  ; catalog_cache_loading : bool
  ; early_fetched_catalog : graph list option
  ; cached_selected_graph : graph_id option
  ; selected_graph_value : graph option
  ; current_graph_scope : graph_scope option
  ; connection_generation : connection_generation
  ; active_graph_token : string option
  ; snapshot_server_t : int option
  ; pending_mirror_inspection : mirror_request option
  ; pending_graph_open : graph_open_request option
  ; pending_graph_attachment : graph_open_request option
  ; snapshot_bootstrap_phase : snapshot_bootstrap_phase
  ; e2ee_authenticated : authenticated_account_scope option
  ; encrypted_graph_key : string option
  ; private_key_package : string option
  ; pending_authoritative_batches : (effect_id * authoritative_plan) list
  ; active_authoritative_batch : authoritative_batch option
  ; queued_authoritative_batch : authoritative_batch option
  ; outbox_records : string list
  ; submission_owner : submission_owner option
  ; websocket_live : bool
  ; closed : bool
  }

type create_error = Invalid_create of string

let initial_startup =
  { authenticated = false
  ; catalog_loading = false
  ; awaiting_selection = false
  ; restoring_local = false
  ; bootstrapping = false
  ; awaiting_e2ee_password = false
  ; failure = None
  ; account_generation = 0
  ; graph_generation = 0
  ; presentation_generation = 0
  }
;;

let initial config =
  let snapshot =
    { sync_phase = Offline
    ; catalog = []
    ; selected_graph = None
    ; applied_server_t = None
    ; timeline_presentation_pending = true
    ; startup = initial_startup
    ; last_error = None
    }
  in
  Ok
    { config
    ; public_state = { snapshot; diagnostics = { groups = []; history = [] } }
    ; user_id = None
    ; lifecycle_generation = 0L
    ; next_effect_id = 0
    ; next_graph_token_id = 0
    ; pending_token = None
    ; deferred_catalog_reconciliation = false
    ; local_presentation_barrier = false
    ; pending_effects = []
    ; pending_local_batches = []
    ; pending_local_commits = []
    ; graph_key = None
    ; catalog_cache_loading = false
    ; early_fetched_catalog = None
    ; cached_selected_graph = None
    ; selected_graph_value = None
    ; current_graph_scope = None
    ; connection_generation = 0
    ; active_graph_token = None
    ; snapshot_server_t = None
    ; pending_mirror_inspection = None
    ; pending_graph_open = None
    ; pending_graph_attachment = None
    ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; e2ee_authenticated = None
    ; encrypted_graph_key = None
    ; private_key_package = None
    ; pending_authoritative_batches = []
    ; active_authoritative_batch = None
    ; queued_authoritative_batch = None
    ; outbox_records = []
    ; submission_owner = None
    ; websocket_live = false
    ; closed = false
    }
;;

let state core = core.public_state
let admitted_graph_scope core = core.current_graph_scope

let graph_scope_is_current core scope =
  match core.current_graph_scope with
  | Some current -> current = scope
  | None -> false
;;

let connection_is_current core (connection : connection_scope) =
  graph_scope_is_current core connection.graph
  && connection.connection_generation = core.connection_generation
;;

type transition =
  { next : t
  ; effects : instruction list
  }

let unchanged core = { next = core; effects = [] }
let publish_state core = Publish (State_changed core.public_state)

let account_scope core user_id =
  { managed_sync_origin = core.config.managed_sync_origin
  ; user_id
  ; account_generation = core.public_state.snapshot.startup.account_generation
  ; presentation_generation = core.public_state.snapshot.startup.presentation_generation
  ; lifecycle_generation = core.lifecycle_generation
  }
;;

let request_kind : type a. a runner_request -> a request_kind = function
  | Load_catalog _ -> Load_catalog_kind
  | Save_catalog _ -> Save_catalog_kind
  | Fetch_catalog _ -> Fetch_catalog_kind
  | Fetch_snapshot_baseline _ -> Fetch_snapshot_baseline_kind
  | Fetch_snapshot_metadata _ -> Fetch_snapshot_metadata_kind
  | Download_snapshot _ -> Download_snapshot_kind
  | Fetch_e2ee_graph_key _ -> Fetch_e2ee_graph_key_kind
  | Fetch_e2ee_user_keys _ -> Fetch_e2ee_user_keys_kind
  | Load_and_unlock_graph_key _ -> Load_and_unlock_graph_key_kind
  | Fetch_and_unlock_graph_key _ -> Fetch_and_unlock_graph_key_kind
  | Unlock_private_key _ -> Unlock_private_key_kind
  | Encrypt_protected_values _ -> Encrypt_protected_values_kind
  | Decrypt_protected_values _ -> Decrypt_protected_values_kind
;;

let issue_request : type a. t -> a runner_request -> t * runner_effect =
  fun core request ->
  let id = core.next_effect_id in
  let ticket = { id; scope = scope_of_request request; kind = request_kind request } in
  ( { core with next_effect_id = id + 1; pending_effects = id :: core.pending_effects }
  , Request (ticket, request) )
;;

let set_snapshot core snapshot =
  { core with public_state = { core.public_state with snapshot } }
;;

let complete_local_batch input action =
  Delegate
    (Complete_local_batch
       { operation_id = input.local_mutation_id
       ; admission_id = input.local_admission_id
       ; scope = input.local_scope
       ; action
       })
;;

let reject_local_batch input kind message =
  complete_local_batch input (Reject { kind; message })
;;

let reject_pending_local_batches core kind message =
  List.map
    (fun (_, plan) -> reject_local_batch plan.local_input kind message)
    core.pending_local_batches
;;

let delegate_local_commit core (request : local_batch_completion_request) outbox_records =
  let pending_commit = { scope = request.scope; outbox_records } in
  { next =
      { core with pending_local_commits = pending_commit :: core.pending_local_commits }
  ; effects = [ Delegate (Complete_local_batch request) ]
  }
;;

let catalog_loaded core graphs =
  let startup =
    { core.public_state.snapshot.startup with
      catalog_loading = false
    ; restoring_local = false
    ; awaiting_selection = true
    ; failure = None
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Offline
    ; catalog = graphs
    ; startup
    ; last_error = None
    }
  in
  let next = set_snapshot core snapshot in
  { next; effects = [ publish_state next ] }
;;

let catalog_failed core message =
  let startup =
    { core.public_state.snapshot.startup with
      catalog_loading = false
    ; restoring_local = false
    ; failure = Some During_catalog
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Failed
    ; startup
    ; last_error = Some message
    }
  in
  let next =
    { (set_snapshot core snapshot) with
      snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; active_graph_token = None
    ; snapshot_server_t = None
    }
  in
  { next; effects = [ publish_state next ] }
;;

let e2ee_failed core message =
  let startup =
    { core.public_state.snapshot.startup with
      catalog_loading = false
    ; restoring_local = false
    ; awaiting_e2ee_password = false
    ; failure = Some During_e2ee
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Failed
    ; startup
    ; last_error = Some message
    }
  in
  let next =
    { (set_snapshot core snapshot) with
      snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; active_graph_token = None
    ; snapshot_server_t = None
    }
  in
  { next; effects = [ publish_state next ] }
;;

let local_restore_failed core =
  let startup =
    { core.public_state.snapshot.startup with
      catalog_loading = false
    ; restoring_local = false
    ; bootstrapping = false
    ; awaiting_e2ee_password = false
    ; failure = Some During_local_restore
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Failed
    ; startup
    ; last_error = Some "Online recovery is required"
    }
  in
  let next =
    { (set_snapshot core snapshot) with
      pending_token = None
    ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; active_graph_token = None
    ; snapshot_server_t = None
    }
  in
  { next; effects = [ publish_state next ] }
;;

let authenticate_new_account core user_id =
  let previous_account = Option.map (account_scope core) core.user_id in
  let account_generation = core.public_state.snapshot.startup.account_generation + 1 in
  let presentation_generation =
    core.public_state.snapshot.startup.presentation_generation + 1
  in
  let startup =
    { initial_startup with
      authenticated = true
    ; catalog_loading = true
    ; account_generation
    ; graph_generation = core.public_state.snapshot.startup.graph_generation + 1
    ; presentation_generation
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Connecting
    ; catalog = []
    ; selected_graph = None
    ; applied_server_t = None
    ; startup
    ; last_error = None
    }
  in
  let request =
    { request_id = Printf.sprintf "catalog-%d" account_generation
    ; purpose = Catalog_discovery
    ; account_generation
    ; graph_generation = None
    ; connection_generation = None
    }
  in
  let next =
    { (set_snapshot core snapshot) with
      user_id = Some user_id
    ; pending_token = Some request
    ; deferred_catalog_reconciliation = false
    ; local_presentation_barrier = false
    ; pending_effects = []
    ; pending_local_batches = []
    ; pending_local_commits = []
    ; graph_key = None
    ; catalog_cache_loading = false
    ; early_fetched_catalog = None
    ; cached_selected_graph = None
    ; selected_graph_value = None
    ; current_graph_scope = None
    ; connection_generation = 0
    ; active_graph_token = None
    ; snapshot_server_t = None
    ; pending_mirror_inspection = None
    ; pending_graph_open = None
    ; pending_graph_attachment = None
    ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; e2ee_authenticated = None
    ; encrypted_graph_key = None
    ; private_key_package = None
    ; pending_authoritative_batches = []
    ; active_authoritative_batch = None
    ; queued_authoritative_batch = None
    ; outbox_records = []
    ; submission_owner = None
    ; websocket_live = false
    }
  in
  let teardown =
    match previous_account with
    | None -> []
    | Some account ->
      (Run (Cancel_effects (effect_scope_of_account account))
       :: reject_pending_local_batches core Scope_closed "managed account was replaced")
      @ [ Delegate (Reset_managed_account account) ]
  in
  { next; effects = teardown @ [ publish_state next; Publish (Token_requested request) ] }
;;

let request_catalog_reconciliation core =
  let account_generation = core.public_state.snapshot.startup.account_generation in
  let request =
    { request_id = Printf.sprintf "catalog-%d-%d" account_generation core.next_effect_id
    ; purpose = Catalog_discovery
    ; account_generation
    ; graph_generation = None
    ; connection_generation = None
    }
  in
  let startup =
    { core.public_state.snapshot.startup with
      authenticated = true
    ; catalog_loading = true
    ; failure = None
    }
  in
  let snapshot = { core.public_state.snapshot with startup; last_error = None } in
  let next =
    { (set_snapshot core snapshot) with
      pending_token = Some request
    ; deferred_catalog_reconciliation = false
    }
  in
  { next; effects = [ publish_state next; Publish (Token_requested request) ] }
;;

let authenticate core user_id =
  match core.user_id with
  | Some current_user_id when String.equal current_user_id user_id ->
    let local_recovery_pending =
      core.public_state.snapshot.startup.failure = Some During_local_restore
    in
    if core.local_presentation_barrier || local_recovery_pending
    then (
      let startup =
        { core.public_state.snapshot.startup with
          authenticated = true
        ; failure =
            (if local_recovery_pending
             then core.public_state.snapshot.startup.failure
             else None)
        }
      in
      let snapshot =
        { core.public_state.snapshot with
          startup
        ; last_error =
            (if local_recovery_pending
             then core.public_state.snapshot.last_error
             else None)
        }
      in
      let next =
        { (set_snapshot core snapshot) with deferred_catalog_reconciliation = true }
      in
      { next; effects = [ publish_state next ] })
    else request_catalog_reconciliation core
  | Some _ | None -> authenticate_new_account core user_id
;;

let sign_out core =
  let previous_account = Option.map (account_scope core) core.user_id in
  let startup =
    { initial_startup with
      account_generation = core.public_state.snapshot.startup.account_generation + 1
    ; graph_generation = core.public_state.snapshot.startup.graph_generation + 1
    ; presentation_generation =
        core.public_state.snapshot.startup.presentation_generation + 1
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Offline
    ; catalog = []
    ; selected_graph = None
    ; applied_server_t = None
    ; startup
    ; last_error = None
    }
  in
  let next =
    { (set_snapshot core snapshot) with
      user_id = None
    ; pending_token = None
    ; deferred_catalog_reconciliation = false
    ; local_presentation_barrier = false
    ; pending_effects = []
    ; pending_local_batches = []
    ; pending_local_commits = []
    ; graph_key = None
    ; catalog_cache_loading = false
    ; early_fetched_catalog = None
    ; cached_selected_graph = None
    ; selected_graph_value = None
    ; current_graph_scope = None
    ; connection_generation = 0
    ; active_graph_token = None
    ; snapshot_server_t = None
    ; pending_mirror_inspection = None
    ; pending_graph_open = None
    ; pending_graph_attachment = None
    ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; e2ee_authenticated = None
    ; encrypted_graph_key = None
    ; private_key_package = None
    ; pending_authoritative_batches = []
    ; active_authoritative_batch = None
    ; queued_authoritative_batch = None
    ; outbox_records = []
    ; submission_owner = None
    ; websocket_live = false
    }
  in
  let teardown =
    match previous_account with
    | None -> []
    | Some account ->
      (Run (Cancel_effects (effect_scope_of_account account))
       :: reject_pending_local_batches core Scope_closed "managed account signed out")
      @ [ Delegate (Reset_managed_account account) ]
  in
  { next; effects = teardown @ [ publish_state next ] }
;;

let token_is_current core request =
  match core.pending_token with
  | Some pending -> String.equal pending.request_id request.request_id
  | None -> false
;;

let provide_token core request token =
  if not (token_is_current core request)
  then unchanged core
  else (
    match core.user_id, request.purpose with
    | None, _ -> unchanged core
    | Some user_id, Catalog_discovery ->
      let core = { core with pending_token = None } in
      let authenticated = { account = account_scope core user_id; token } in
      let next, runner_instruction = issue_request core (Fetch_catalog authenticated) in
      { next; effects = [ Run runner_instruction ] }
    | Some _, Snapshot_bootstrap ->
      (match core.current_graph_scope with
       | None -> unchanged core
       | Some graph ->
         let core = { core with pending_token = None; active_graph_token = Some token } in
         let next, runner_instruction =
           issue_request core (Fetch_snapshot_baseline { graph; token })
         in
         { next =
             { next with snapshot_bootstrap_phase = Snapshot_bootstrap_fetching_baseline }
         ; effects = [ Run runner_instruction ]
         })
    | Some _, Websocket_connect ->
      (match core.current_graph_scope with
       | None -> unchanged core
       | Some graph ->
         let connection_generation = core.connection_generation + 1 in
         let connection = { graph; connection_generation } in
         let uri =
           Uri.with_scheme graph.account.managed_sync_origin (Some "wss")
           |> fun uri ->
           Uri.with_path
             uri
             (Printf.sprintf
                "/sync/%s"
                (Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id))
         in
         let next = { core with pending_token = None; connection_generation } in
         { next; effects = [ Run (Start_websocket { scope = connection; uri; token }) ] })
    | Some user_id, E2ee_key_access ->
      (match core.current_graph_scope with
       | None -> unchanged core
       | Some graph ->
         let authenticated = { account = account_scope core user_id; token } in
         let next, runner_instruction =
           issue_request core (Fetch_e2ee_graph_key { graph; token })
         in
         { next =
             { next with pending_token = None; e2ee_authenticated = Some authenticated }
         ; effects = [ Run runner_instruction ]
         }))
;;

let reject_token core request =
  if not (token_is_current core request)
  then unchanged core
  else (
    let startup =
      { core.public_state.snapshot.startup with
        catalog_loading = false
      ; failure = Some During_authentication
      }
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase = Failed
      ; startup
      ; last_error = Some "authentication token was rejected"
      }
    in
    let next =
      { (set_snapshot core snapshot) with
        pending_token = None
      ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
      ; active_graph_token = None
      ; snapshot_server_t = None
      }
    in
    { next; effects = [ publish_state next ] })
;;

let restore_local core user_id =
  let account_generation = core.public_state.snapshot.startup.account_generation + 1 in
  let presentation_generation =
    core.public_state.snapshot.startup.presentation_generation + 1
  in
  let startup =
    { initial_startup with
      restoring_local = true
    ; account_generation
    ; graph_generation = core.public_state.snapshot.startup.graph_generation + 1
    ; presentation_generation
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Offline
    ; catalog = []
    ; selected_graph = None
    ; applied_server_t = None
    ; startup
    ; last_error = None
    }
  in
  let core =
    { (set_snapshot core snapshot) with
      user_id = Some user_id
    ; pending_token = None
    ; pending_effects = []
    ; pending_local_batches = []
    ; pending_local_commits = []
    ; selected_graph_value = None
    ; catalog_cache_loading = true
    ; early_fetched_catalog = None
    ; deferred_catalog_reconciliation = false
    ; local_presentation_barrier = true
    ; cached_selected_graph = None
    ; current_graph_scope = None
    ; graph_key = None
    ; connection_generation = 0
    ; active_graph_token = None
    ; snapshot_server_t = None
    ; pending_mirror_inspection = None
    ; pending_graph_open = None
    ; pending_graph_attachment = None
    ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; e2ee_authenticated = None
    ; encrypted_graph_key = None
    ; private_key_package = None
    ; pending_authoritative_batches = []
    ; active_authoritative_batch = None
    ; queued_authoritative_batch = None
    ; outbox_records = []
    ; submission_owner = None
    ; websocket_live = false
    }
  in
  let next, runner_instruction =
    issue_request core (Load_catalog (account_scope core user_id))
  in
  { next; effects = [ publish_state next; Run runner_instruction ] }
;;

let decode_snapshot_baseline source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields ->
      (match List.assoc_opt "type" fields, List.assoc_opt "t" fields with
       | Some (`String "pull/ok"), Some (`Int server_t) when server_t >= 0 -> Ok server_t
       | _ -> Error "snapshot baseline pull is invalid")
    | _ -> Error "snapshot baseline pull must be an object"
  with
  | Yojson.Json_error _ -> Error "snapshot baseline pull is not valid JSON"
;;

let decode_snapshot_uri source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields ->
      (match List.assoc_opt "ok" fields, List.assoc_opt "url" fields with
       | Some (`Bool true), Some (`String value) ->
         let uri = Uri.of_string value in
         (match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
          | Some "https", Some host, None, None when String.length host > 0 -> Ok uri
          | _ -> Error "snapshot download URL is invalid")
       | _ -> Error "snapshot metadata is invalid")
    | _ -> Error "snapshot metadata must be an object"
  with
  | Yojson.Json_error _ -> Error "snapshot metadata is not valid JSON"
;;

let bounded_e2ee_string name = function
  | Some (`String value)
    when String.length value > 0
         && String.length value <= 65_536
         && String.is_valid_utf_8 value
         && not (String.contains value '\000') -> Ok value
  | Some _ | None -> Error ("E2EE response " ^ name ^ " is invalid")
;;

let decode_e2ee_graph_key source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields when List.length fields = 1 ->
      bounded_e2ee_string "encrypted-aes-key" (List.assoc_opt "encrypted-aes-key" fields)
    | _ -> Error "E2EE graph-key response has invalid fields"
  with
  | Yojson.Json_error _ -> Error "E2EE graph-key response is not valid JSON"
;;

let decode_e2ee_private_key_package source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields
      when List.length fields = 2
           && List.mem_assoc "public-key" fields
           && List.mem_assoc "encrypted-private-key" fields ->
      Result.bind
        (bounded_e2ee_string "public-key" (List.assoc_opt "public-key" fields))
        (fun _ ->
           bounded_e2ee_string
             "encrypted-private-key"
             (List.assoc_opt "encrypted-private-key" fields))
    | _ -> Error "E2EE user-key response has invalid fields"
  with
  | Yojson.Json_error _ -> Error "E2EE user-key response is not valid JSON"
;;

let challenge_graph_token core purpose =
  match core.user_id, core.current_graph_scope with
  | Some _, Some scope ->
    let challenge_id = core.next_graph_token_id in
    let request_id =
      Printf.sprintf
        "%s-%d-%d"
        (match purpose with
         | Snapshot_bootstrap -> "snapshot"
         | E2ee_key_access -> "e2ee"
         | Websocket_connect -> "websocket"
         | Catalog_discovery -> "catalog")
        scope.account.account_generation
        scope.graph_generation
    in
    let request =
      { request_id =
          (if challenge_id = 0
           then request_id
           else Printf.sprintf "%s-%d" request_id challenge_id)
      ; purpose
      ; account_generation = scope.account.account_generation
      ; graph_generation = Some scope.graph_generation
      ; connection_generation = None
      }
    in
    let next =
      { core with next_graph_token_id = challenge_id + 1; pending_token = Some request }
    in
    { next; effects = [ Publish (Token_requested request) ] }
  | None, None | None, Some _ | Some _, None -> unchanged core
;;

let challenge_websocket_if_ready core =
  match
    ( core.pending_token
    , core.websocket_live
    , core.current_graph_scope
    , core.public_state.snapshot.applied_server_t )
  with
  | None, false, Some _, Some _ when core.public_state.snapshot.startup.authenticated ->
    challenge_graph_token core Websocket_connect
  | _ -> unchanged core
;;

let request_snapshot_authorization core =
  let requested = challenge_graph_token core Snapshot_bootstrap in
  match requested.effects with
  | [] -> requested
  | _ :: _ ->
    { requested with
      next =
        { requested.next with
          snapshot_bootstrap_phase = Snapshot_bootstrap_waiting_for_token
        }
    }
;;

let request_snapshot_bootstrap core =
  match
    core.snapshot_bootstrap_phase, core.selected_graph_value, core.current_graph_scope
  with
  | Snapshot_bootstrap_idle, Some graph, Some scope when graph.encrypted ->
    (match core.graph_key with
     | Some handle when handle.handle_scope = scope -> request_snapshot_authorization core
     | Some _ | None ->
       let next, runner_instruction =
         issue_request core (Load_and_unlock_graph_key scope)
       in
       { next =
           { next with snapshot_bootstrap_phase = Snapshot_bootstrap_waiting_for_key }
       ; effects = [ Run runner_instruction ]
       })
  | Snapshot_bootstrap_idle, Some _, Some _ -> request_snapshot_authorization core
  | Snapshot_bootstrap_idle, (Some _ | None), None | Snapshot_bootstrap_idle, None, Some _
    -> unchanged core
  | ( ( Snapshot_bootstrap_waiting_for_key
      | Snapshot_bootstrap_waiting_for_token
      | Snapshot_bootstrap_fetching_baseline
      | Snapshot_bootstrap_fetching_metadata
      | Snapshot_bootstrap_downloading
      | Snapshot_bootstrap_activating )
    , _
    , _ ) -> unchanged core
;;

let begin_online_recovery core =
  match core.public_state.snapshot.startup.failure, core.selected_graph_value with
  | Some During_local_restore, Some graph when graph.encrypted ->
    let startup =
      { core.public_state.snapshot.startup with bootstrapping = true; failure = None }
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase = Connecting
      ; startup
      ; last_error = None
      }
    in
    let next =
      { (set_snapshot core snapshot) with
        snapshot_bootstrap_phase = Snapshot_bootstrap_waiting_for_key
      }
    in
    challenge_graph_token next E2ee_key_access
  | _ -> request_snapshot_bootstrap core
;;

let graph_key_loaded core handle =
  match core.current_graph_scope with
  | Some scope when handle.handle_scope <> scope ->
    e2ee_failed core "graph key handle is outside the selected graph scope"
  | Some _ | None ->
    (match core.pending_graph_open, core.snapshot_bootstrap_phase with
     | None, Snapshot_bootstrap_idle -> unchanged core
     | Some request, _ ->
       let next =
         { core with
           graph_key = Some handle
         ; pending_graph_open = None
         ; pending_graph_attachment = Some request
         ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
         ; encrypted_graph_key = None
         ; private_key_package = None
         }
       in
       { next; effects = [ Delegate (Attach_graph request) ] }
     | None, Snapshot_bootstrap_waiting_for_key ->
       request_snapshot_bootstrap
         { core with
           graph_key = Some handle
         ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
         ; encrypted_graph_key = None
         ; private_key_package = None
         }
     | ( None
       , ( Snapshot_bootstrap_waiting_for_token
         | Snapshot_bootstrap_fetching_baseline
         | Snapshot_bootstrap_fetching_metadata
         | Snapshot_bootstrap_downloading
         | Snapshot_bootstrap_activating ) ) -> unchanged core)
;;

let authoritative_batch_is_current core (batch : authoritative_batch) =
  connection_is_current core batch.scope
  && batch.presentation_generation
     = core.public_state.snapshot.startup.presentation_generation
  && batch.lifecycle_generation = core.lifecycle_generation
;;

let authoritative_finished core plan decrypted_values =
  if not (authoritative_batch_is_current core plan.authoritative_context.batch)
  then unchanged { core with active_authoritative_batch = None }
  else (
    match finish_authoritative_batch plan decrypted_values with
    | Error message ->
      catalog_failed { core with active_authoritative_batch = None } message
    | Ok request ->
      { next = core; effects = [ Delegate (Apply_authoritative_batch request) ] })
;;

let authoritative_conflicted core batch =
  match core.active_authoritative_batch with
  | Some active when active = batch && authoritative_batch_is_current core batch ->
    { next = core; effects = [ Delegate (Inspect_authoritative_batch batch) ] }
  | Some active when active = batch ->
    unchanged { core with active_authoritative_batch = None }
  | Some _ | None -> unchanged core
;;

let graph_in_catalog graphs graph_id =
  List.find_opt
    (fun (graph : graph) ->
       Logseq_db_types.Graph_types.Uuid.equal graph.graph_id graph_id)
    graphs
;;

let select_graph_transition core ~persist graph_id =
  match core.user_id, graph_in_catalog core.public_state.snapshot.catalog graph_id with
  | None, _ | Some _, None -> unchanged core
  | Some user_id, Some graph ->
    let previous_generation = core.public_state.snapshot.startup.graph_generation in
    let graph_generation = previous_generation + 1 in
    let startup =
      { core.public_state.snapshot.startup with
        awaiting_selection = false
      ; bootstrapping = true
      ; awaiting_e2ee_password = false
      ; failure = None
      ; graph_generation
      }
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase = Offline
      ; selected_graph = Some graph_id
      ; applied_server_t = None
      ; startup
      ; last_error = None
      }
    in
    let next = set_snapshot core snapshot in
    let scope = { account = account_scope next user_id; graph_id; graph_generation } in
    let mirror_request = { graph; scope } in
    let next =
      { next with
        cached_selected_graph = Some graph_id
      ; selected_graph_value = Some graph
      ; current_graph_scope = Some scope
      ; graph_key = None
      ; pending_effects = []
      ; pending_local_batches = []
      ; pending_local_commits = []
      ; connection_generation = 0
      ; active_graph_token = None
      ; snapshot_server_t = None
      ; pending_mirror_inspection = Some mirror_request
      ; pending_graph_open = None
      ; pending_graph_attachment = None
      ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
      ; e2ee_authenticated = None
      ; encrypted_graph_key = None
      ; private_key_package = None
      ; pending_authoritative_batches = []
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; outbox_records = []
      ; submission_owner = None
      ; websocket_live = false
      }
    in
    let replacement_effects =
      match core.current_graph_scope with
      | None -> []
      | Some previous ->
        [ Run (Cancel_effects (effect_scope_of_graph previous))
        ; Delegate (Detach_graph previous)
        ]
    in
    let next, persistence_effects =
      if persist
      then (
        let cache =
          catalog_cache ~user_id ~graphs:snapshot.catalog ~selected_graph:(Some graph_id)
        in
        let next, runner_instruction =
          issue_request next (Save_catalog { account = scope.account; cache })
        in
        next, [ Run runner_instruction ])
      else next, []
    in
    { next
    ; effects =
        replacement_effects
        @ [ Delegate (Inspect_mirror mirror_request); publish_state next ]
        @ persistence_effects
    }
;;

let clear_selected_graph_for_catalog core graphs =
  let previous = core.current_graph_scope in
  let startup =
    { core.public_state.snapshot.startup with
      catalog_loading = false
    ; restoring_local = false
    ; awaiting_selection = true
    ; bootstrapping = false
    ; awaiting_e2ee_password = false
    ; failure = None
    ; graph_generation = core.public_state.snapshot.startup.graph_generation + 1
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Offline
    ; catalog = graphs
    ; selected_graph = None
    ; applied_server_t = None
    ; startup
    ; last_error = None
    }
  in
  let next =
    { (set_snapshot core snapshot) with
      cached_selected_graph = None
    ; selected_graph_value = None
    ; current_graph_scope = None
    ; graph_key = None
    ; pending_token = None
    ; pending_effects = []
    ; pending_local_batches = []
    ; pending_local_commits = []
    ; pending_mirror_inspection = None
    ; pending_graph_open = None
    ; pending_graph_attachment = None
    ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
    ; e2ee_authenticated = None
    ; encrypted_graph_key = None
    ; private_key_package = None
    ; pending_authoritative_batches = []
    ; active_authoritative_batch = None
    ; queued_authoritative_batch = None
    ; active_graph_token = None
    ; snapshot_server_t = None
    ; outbox_records = []
    ; submission_owner = None
    ; websocket_live = false
    }
  in
  let closing =
    Option.fold
      ~none:[]
      ~some:(fun scope ->
        [ Run (Cancel_effects (effect_scope_of_graph scope))
        ; Delegate (Detach_graph scope)
        ])
      previous
  in
  { next; effects = closing @ [ publish_state next ] }
;;

let catalog_refreshed core graphs =
  let admitted_cached_selection =
    Option.bind core.cached_selected_graph (fun graph_id ->
      Option.map (fun graph -> graph_id, graph) (graph_in_catalog graphs graph_id))
  in
  match core.public_state.snapshot.selected_graph with
  | Some selected_graph ->
    (match graph_in_catalog graphs selected_graph with
     | None -> clear_selected_graph_for_catalog core graphs
     | Some graph ->
       let startup =
         { core.public_state.snapshot.startup with
           catalog_loading = false
         ; restoring_local = false
         ; awaiting_selection = false
         ; failure = None
         }
       in
       let snapshot =
         { core.public_state.snapshot with catalog = graphs; startup; last_error = None }
       in
       let next =
         { (set_snapshot core snapshot) with
           cached_selected_graph = Some selected_graph
         ; selected_graph_value = Some graph
         }
       in
       { next; effects = [ publish_state next ] })
  | None ->
    let loaded = catalog_loaded core graphs in
    let cached_selected_graph = Option.map fst admitted_cached_selection in
    let next = { loaded.next with cached_selected_graph } in
    { next; effects = [ publish_state next ] }
;;

let apply_fetched_catalog core graphs =
  let refreshed = catalog_refreshed core graphs in
  match refreshed.next.user_id with
  | None -> refreshed
  | Some user_id ->
    let cache =
      catalog_cache ~user_id ~graphs ~selected_graph:refreshed.next.cached_selected_graph
    in
    let account = account_scope refreshed.next user_id in
    let next, runner_instruction =
      issue_request refreshed.next (Save_catalog { account; cache })
    in
    { next; effects = refreshed.effects @ [ Run runner_instruction ] }
;;

let consume_completion
  : type a. t -> a effect_ticket -> (a, effect_error) result -> transition
  =
  fun core ticket result ->
  if not (List.mem ticket.id core.pending_effects)
  then unchanged core
  else (
    let core =
      { core with pending_effects = List.filter (( <> ) ticket.id) core.pending_effects }
    in
    match ticket.kind, result with
    | Load_catalog_kind, Ok cache ->
      let early_fetched_catalog = core.early_fetched_catalog in
      let core =
        { core with catalog_cache_loading = false; early_fetched_catalog = None }
      in
      let restored =
        match cache with
        | None -> catalog_loaded core []
        | Some cache ->
          let graphs = catalog_cache_graphs cache in
          let loaded = catalog_loaded core graphs in
          (match catalog_cache_selected_graph cache with
           | Some graph_id when Option.is_some (graph_in_catalog graphs graph_id) ->
             select_graph_transition loaded.next ~persist:false graph_id
           | Some _ | None -> loaded)
      in
      let completed =
        match early_fetched_catalog with
        | None -> restored
        | Some graphs ->
          let refreshed = apply_fetched_catalog restored.next graphs in
          { next = refreshed.next; effects = restored.effects @ refreshed.effects }
      in
      let completed =
        match completed.next.current_graph_scope with
        | None ->
          { completed with
            next = { completed.next with local_presentation_barrier = false }
          }
        | Some _ -> completed
      in
      (match
         ( completed.next.deferred_catalog_reconciliation
         , completed.next.current_graph_scope
         , completed.next.user_id )
       with
       | true, None, Some _ ->
         let requested = request_catalog_reconciliation completed.next in
         { next = requested.next; effects = completed.effects @ requested.effects }
       | _ -> completed)
    | Fetch_catalog_kind, Ok graphs ->
      if core.catalog_cache_loading
      then { next = { core with early_fetched_catalog = Some graphs }; effects = [] }
      else (
        let refreshed = apply_fetched_catalog core graphs in
        if refreshed.next.public_state.snapshot.timeline_presentation_pending
        then refreshed
        else (
          let websocket = challenge_websocket_if_ready refreshed.next in
          { next = websocket.next; effects = refreshed.effects @ websocket.effects }))
    | Load_catalog_kind, Error (Effect_failed message) ->
      catalog_failed
        { core with catalog_cache_loading = false; early_fetched_catalog = None }
        message
    | Fetch_catalog_kind, Error (Effect_failed message) -> catalog_failed core message
    | Save_catalog_kind, (Ok () | Error _) -> unchanged core
    | Fetch_snapshot_baseline_kind, Ok source ->
      (match
         ( decode_snapshot_baseline source
         , core.current_graph_scope
         , core.active_graph_token )
       with
       | Ok server_t, Some graph, Some token ->
         let next, runner_instruction =
           issue_request core (Fetch_snapshot_metadata { graph; token })
         in
         { next =
             { next with
               snapshot_server_t = Some server_t
             ; snapshot_bootstrap_phase = Snapshot_bootstrap_fetching_metadata
             }
         ; effects = [ Run runner_instruction ]
         }
       | Error message, _, _ -> catalog_failed core message
       | Ok _, (None | Some _), None | Ok _, None, Some _ -> unchanged core)
    | Fetch_snapshot_metadata_kind, Ok source ->
      (match
         decode_snapshot_uri source, core.current_graph_scope, core.active_graph_token
       with
       | Ok uri, Some graph, Some token ->
         let request =
           { scope = { graph; token }
           ; uri
           ; expected_bytes = None
           ; maximum_bytes = core.config.limits.maximum_artifact_bytes
           }
         in
         let next, runner_instruction = issue_request core (Download_snapshot request) in
         { next = { next with snapshot_bootstrap_phase = Snapshot_bootstrap_downloading }
         ; effects = [ Run runner_instruction ]
         }
       | Error message, _, _ -> catalog_failed core message
       | Ok _, (None | Some _), None | Ok _, None, Some _ -> unchanged core)
    | Download_snapshot_kind, Ok artifact ->
      (match
         core.current_graph_scope, core.snapshot_server_t, core.selected_graph_value
       with
       | Some scope, Some applied_server_t, Some graph when graph.encrypted ->
         (match core.graph_key with
          | None -> e2ee_failed core "encrypted snapshot requires a graph key handle"
          | Some key when key.handle_scope = scope ->
            { next =
                { core with snapshot_bootstrap_phase = Snapshot_bootstrap_activating }
            ; effects =
                [ Delegate
                    (Activate_snapshot
                       { artifact; scope; applied_server_t; key = Some key })
                ]
            }
          | Some _ ->
            e2ee_failed core "graph key handle is outside the selected graph scope")
       | Some scope, Some applied_server_t, Some _ ->
         { next = { core with snapshot_bootstrap_phase = Snapshot_bootstrap_activating }
         ; effects =
             [ Delegate
                 (Activate_snapshot { artifact; scope; applied_server_t; key = None })
             ]
         }
       | Some _, None, _ | None, Some _, _ | None, None, _ | Some _, Some _, None ->
         unchanged core)
    | Fetch_e2ee_graph_key_kind, Ok source ->
      (match
         decode_e2ee_graph_key source, core.current_graph_scope, core.e2ee_authenticated
       with
       | Ok encrypted_graph_key, Some graph, Some authenticated ->
         let request =
           { scope = { graph; token = authenticated.token }; encrypted_graph_key }
         in
         let next, runner_instruction =
           issue_request core (Fetch_and_unlock_graph_key request)
         in
         { next = { next with encrypted_graph_key = Some encrypted_graph_key }
         ; effects = [ Run runner_instruction ]
         }
       | Error message, _, _ -> catalog_failed core message
       | Ok _, (None | Some _), None | Ok _, None, Some _ -> unchanged core)
    | Fetch_e2ee_user_keys_kind, Ok source ->
      (match decode_e2ee_private_key_package source with
       | Error message -> catalog_failed core message
       | Ok private_key_package ->
         let startup =
           { core.public_state.snapshot.startup with awaiting_e2ee_password = true }
         in
         let snapshot = { core.public_state.snapshot with startup; last_error = None } in
         let next =
           { (set_snapshot core snapshot) with
             private_key_package = Some private_key_package
           }
         in
         { next; effects = [ publish_state next ] })
    | Load_and_unlock_graph_key_kind, Ok handle -> graph_key_loaded core handle
    | Fetch_and_unlock_graph_key_kind, Ok handle -> graph_key_loaded core handle
    | Load_and_unlock_graph_key_kind, Error _ -> local_restore_failed core
    | Fetch_and_unlock_graph_key_kind, Error _ ->
      (match core.e2ee_authenticated with
       | None -> catalog_failed core "E2EE account authorization is unavailable"
       | Some authenticated ->
         let next, runner_instruction =
           issue_request core (Fetch_e2ee_user_keys authenticated)
         in
         { next; effects = [ Run runner_instruction ] })
    | Unlock_private_key_kind, Ok () ->
      (match
         core.e2ee_authenticated, core.current_graph_scope, core.encrypted_graph_key
       with
       | Some authenticated, Some graph, Some encrypted_graph_key ->
         let request =
           { scope = { graph; token = authenticated.token }; encrypted_graph_key }
         in
         let next, runner_instruction =
           issue_request core (Fetch_and_unlock_graph_key request)
         in
         { next = { next with private_key_package = None }
         ; effects = [ Run runner_instruction ]
         }
       | Some _, Some _, None | Some _, None, _ | None, _, _ ->
         catalog_failed core "E2EE recovery state is incomplete")
    | Fetch_snapshot_baseline_kind, Error (Effect_failed message)
    | Fetch_snapshot_metadata_kind, Error (Effect_failed message)
    | Download_snapshot_kind, Error (Effect_failed message)
    | Fetch_e2ee_graph_key_kind, Error (Effect_failed message)
    | Fetch_e2ee_user_keys_kind, Error (Effect_failed message)
    | Unlock_private_key_kind, Error (Effect_failed message) ->
      catalog_failed core message
    | Encrypt_protected_values_kind, Ok encrypted ->
      (match List.assoc_opt ticket.id core.pending_local_batches with
       | None -> unchanged core
       | Some plan ->
         let core =
           { core with
             pending_local_batches =
               List.remove_assoc ticket.id core.pending_local_batches
           }
         in
         (match finish_local_batch plan (Some encrypted) with
          | Error message ->
            { next = core
            ; effects = [ reject_local_batch plan.local_input Encoding_failed message ]
            }
          | Ok record ->
            let records = plan.local_input.local_outbox @ [ record ] in
            (match encode_outbox_records records with
             | Error message ->
               { next = core
               ; effects = [ reject_local_batch plan.local_input Encoding_failed message ]
               }
             | Ok outbox_records ->
               let request =
                 { operation_id = plan.local_input.local_mutation_id
                 ; admission_id = plan.local_input.local_admission_id
                 ; scope = plan.local_input.local_scope
                 ; action = Commit { outbox_records }
                 }
               in
               delegate_local_commit core request outbox_records)))
    | ( Encrypt_protected_values_kind
      , Error
          (Effect_failed message | Crypto_failed (Crypto_provider_unavailable, message)) )
      ->
      (match List.assoc_opt ticket.id core.pending_local_batches with
       | None -> unchanged core
       | Some plan ->
         let snapshot =
           { core.public_state.snapshot with
             sync_phase = Paused
           ; last_error = Some "Local encryption is temporarily unavailable."
           }
         in
         let next =
           set_snapshot
             { core with
               pending_local_batches =
                 List.remove_assoc ticket.id core.pending_local_batches
             }
             snapshot
         in
         { next
         ; effects =
             [ reject_local_batch plan.local_input Encryption_failed message
             ; publish_state next
             ]
         })
    | Encrypt_protected_values_kind, Error (Crypto_failed (Invalid_key_material, message))
      ->
      (match List.assoc_opt ticket.id core.pending_local_batches with
       | None -> unchanged core
       | Some plan ->
         let core =
           { core with
             pending_local_batches =
               List.remove_assoc ticket.id core.pending_local_batches
           }
         in
         let failed =
           e2ee_failed core "The graph encryption key is unavailable or invalid."
         in
         { failed with
           effects =
             reject_local_batch plan.local_input Encryption_failed message
             :: failed.effects
         })
    | Decrypt_protected_values_kind, Ok decrypted ->
      (match List.assoc_opt ticket.id core.pending_authoritative_batches with
       | None -> unchanged core
       | Some plan ->
         let core =
           { core with
             pending_authoritative_batches =
               List.remove_assoc ticket.id core.pending_authoritative_batches
           }
         in
         authoritative_finished core plan (Some decrypted))
    | Decrypt_protected_values_kind, Error (Effect_failed message) ->
      let core =
        { core with
          pending_authoritative_batches =
            List.remove_assoc ticket.id core.pending_authoritative_batches
        }
      in
      e2ee_failed core message
    | Decrypt_protected_values_kind, Error (Crypto_failed (Invalid_key_material, _)) ->
      let core =
        { core with
          pending_authoritative_batches =
            List.remove_assoc ticket.id core.pending_authoritative_batches
        ; active_authoritative_batch = None
        }
      in
      e2ee_failed core "The graph encryption key is unavailable or invalid."
    | ( Decrypt_protected_values_kind
      , Error (Crypto_failed (Crypto_provider_unavailable, _)) ) ->
      let snapshot =
        { core.public_state.snapshot with
          sync_phase = Paused
        ; last_error = Some "Authoritative decryption is temporarily unavailable."
        }
      in
      let next =
        set_snapshot
          { core with
            pending_authoritative_batches =
              List.remove_assoc ticket.id core.pending_authoritative_batches
          ; active_authoritative_batch = None
          }
          snapshot
      in
      { next; effects = [ publish_state next ] }
    | _, Error (Crypto_failed (_, message)) -> catalog_failed core message)
;;

let start_local_batch core input =
  let input = { input with local_key = core.graph_key } in
  if not (graph_scope_is_current core input.local_scope)
  then
    { next = core
    ; effects = [ reject_local_batch input Scope_closed "managed graph scope is closed" ]
    }
  else (
    match begin_local_batch input with
    | Error message ->
      { next = core; effects = [ reject_local_batch input Planning_failed message ] }
    | Ok plan ->
      (match local_batch_crypto_request plan with
       | Some request ->
         let next, runner_instruction =
           issue_request core (Encrypt_protected_values request)
         in
         let id = next.next_effect_id - 1 in
         { next =
             { next with
               pending_local_batches = (id, plan) :: next.pending_local_batches
             }
         ; effects = [ Run runner_instruction ]
         }
       | None ->
         (match finish_local_batch plan None with
          | Error message ->
            { next = core
            ; effects = [ reject_local_batch plan.local_input Encoding_failed message ]
            }
          | Ok record ->
            let records = plan.local_input.local_outbox @ [ record ] in
            (match encode_outbox_records records with
             | Error message ->
               { next = core
               ; effects = [ reject_local_batch plan.local_input Encoding_failed message ]
               }
             | Ok outbox_records ->
               let request =
                 { operation_id = plan.local_input.local_mutation_id
                 ; admission_id = plan.local_input.local_admission_id
                 ; scope = plan.local_input.local_scope
                 ; action = Commit { outbox_records }
                 }
               in
               delegate_local_commit core request outbox_records))))
;;

let take_values count values =
  let rec loop remaining taken = function
    | _ when remaining = 0 -> List.rev taken
    | [] -> List.rev taken
    | value :: rest -> loop (remaining - 1) (value :: taken) rest
  in
  loop count [] values
;;

let submission_message applied_server_t records =
  Sync_protocol.Client.Tx_batch
    { client_revision = None
    ; t_before = applied_server_t
    ; txs =
        List.map
          (fun record : Sync_protocol.Client.transaction ->
             { tx = record.encoded_tx
             ; tx_id = Some record.mutation_id
             ; outliner_op = Some record.outliner_op
             })
          records
    }
;;

let plan_submission core =
  match core.current_graph_scope, core.public_state.snapshot.applied_server_t with
  | Some scope, Some applied_server_t
    when core.websocket_live
         && core.public_state.snapshot.sync_phase = Current
         && Option.is_none core.submission_owner ->
    (match decode_outbox_records core.outbox_records with
     | Error message -> catalog_failed core message
     | Ok records ->
       let has_uncertain_attempt =
         List.exists
           (fun record ->
              match record.outbox_state with
              | Submitted | Accepted _ -> true
              | Queued | Blocked _ -> false)
           records
       in
       let queued =
         List.filter
           (fun record ->
              match record.outbox_state with
              | Queued -> true
              | Submitted | Accepted _ | Blocked _ -> false)
           records
         |> take_values core.config.limits.submission_batch_size
       in
       if queued = [] || has_uncertain_attempt
       then unchanged core
       else (
         let selected mutation_id =
           List.exists
             (fun record ->
                Logseq_db_types.Graph_types.Uuid.equal record.mutation_id mutation_id)
             queued
         in
         let transitioned =
           List.map
             (fun record ->
                if selected record.mutation_id
                then { record with outbox_state = Submitted }
                else record)
             records
         in
         match encode_outbox_records transitioned with
         | Error message -> catalog_failed core message
         | Ok outbox_records ->
           let message = submission_message applied_server_t queued in
           let transition =
             { scope
             ; presentation_generation =
                 core.public_state.snapshot.startup.presentation_generation
             ; lifecycle_generation = core.lifecycle_generation
             ; expected_outbox_records = core.outbox_records
             ; outbox_records
             ; pending_message = Some message
             }
           in
           let connection =
             { graph = scope; connection_generation = core.connection_generation }
           in
           let owner =
             { mutation_ids = List.map (fun record -> record.mutation_id) queued
             ; t_before = applied_server_t
             ; message
             ; reserved_outbox_records = outbox_records
             ; connection
             ; presentation_generation =
                 core.public_state.snapshot.startup.presentation_generation
             ; lifecycle_generation = core.lifecycle_generation
             ; phase = Submission_reserving
             }
           in
           { next = { core with submission_owner = Some owner }
           ; effects = [ Delegate (Commit_outbox_transition transition) ]
           }))
  | Some _, Some _ | Some _, None | None, Some _ | None, None -> unchanged core
;;

let rec remove_first value = function
  | [] -> []
  | candidate :: rest when candidate = value -> rest
  | candidate :: rest -> candidate :: remove_first value rest
;;

let local_batch_committed core (commit : local_batch_commit) =
  if
    (not (graph_scope_is_current core commit.scope))
    || not (List.mem commit core.pending_local_commits)
  then unchanged core
  else
    plan_submission
      { core with
        pending_local_commits = remove_first commit core.pending_local_commits
      ; outbox_records = commit.outbox_records
      }
;;

let outbox_transition_committed core (commit : outbox_transition_commit) =
  if not (graph_scope_is_current core commit.scope)
  then unchanged core
  else (
    match commit.pending_message, core.submission_owner with
    | Some message, Some owner
      when core.websocket_live
           && owner.phase = Submission_reserving
           && owner.message = message
           && owner.reserved_outbox_records = commit.outbox_records
           && owner.connection.graph = commit.scope
           && Some owner.t_before = core.public_state.snapshot.applied_server_t
           && connection_is_current core owner.connection ->
      let snapshot = { core.public_state.snapshot with sync_phase = Submitting } in
      let owner = { owner with phase = Submission_dispatched } in
      let next =
        set_snapshot
          { core with
            outbox_records = commit.outbox_records
          ; submission_owner = Some owner
          }
          snapshot
      in
      { next
      ; effects =
          [ Run (Send_websocket { scope = owner.connection; message })
          ; publish_state next
          ]
      }
    | Some _, (None | Some _) | None, _ -> unchanged core)
;;

let outbox_transition_rejected core (rejection : outbox_transition_rejection) =
  if not (graph_scope_is_current core rejection.scope)
  then unchanged core
  else
    plan_submission
      { core with outbox_records = rejection.outbox_records; submission_owner = None }
;;

let start_authoritative_batch core (context : authoritative_context) =
  let connection = context.batch.scope in
  let owner_matches =
    match core.active_authoritative_batch with
    | None -> true
    | Some active -> active = context.batch
  in
  let graph_is_current =
    match core.current_graph_scope with
    | Some graph -> graph = connection.graph
    | None -> false
  in
  if
    (not owner_matches)
    || (not graph_is_current)
    || connection.connection_generation <> core.connection_generation
    || context.batch.presentation_generation
       <> core.public_state.snapshot.startup.presentation_generation
    || context.batch.lifecycle_generation <> core.lifecycle_generation
  then unchanged core
  else (
    let core = { core with active_authoritative_batch = Some context.batch } in
    let acknowledged_mutation_ids =
      match context.batch.message, core.submission_owner with
      | Sync_protocol.Server.Tx_batch_ok _, Some owner ->
        (match owner.phase with
         | Submission_applying_ack _ -> owner.mutation_ids
         | Submission_reserving | Submission_dispatched | Submission_awaiting_pull _ -> [])
      | _, (Some _ | None) -> []
    in
    match begin_authoritative_batch ~acknowledged_mutation_ids context with
    | Error message -> catalog_failed core message
    | Ok plan ->
      let plan = { plan with authoritative_key = core.graph_key } in
      (match plan.authoritative_protected_values, authoritative_crypto_request plan with
       | _ :: _, None -> catalog_failed core "encrypted pull requires a graph key handle"
       | _, Some request ->
         let next, runner_instruction =
           issue_request core (Decrypt_protected_values request)
         in
         let id = next.next_effect_id - 1 in
         { next =
             { next with
               pending_authoritative_batches =
                 (id, plan) :: next.pending_authoritative_batches
             }
         ; effects = [ Run runner_instruction ]
         }
       | [], None -> authoritative_finished core plan None))
;;

let select_graph core graph_id = select_graph_transition core ~persist:true graph_id

let mirror_inspected core = function
  | Mirror_available request
    when graph_scope_is_current core request.scope
         && core.pending_mirror_inspection
            = Some { graph = request.graph; scope = request.scope } ->
    let core = { core with pending_mirror_inspection = None } in
    (match core.selected_graph_value with
     | Some graph when graph.encrypted && Option.is_some core.graph_key ->
       { next = { core with pending_graph_attachment = Some request }
       ; effects = [ Delegate (Attach_graph request) ]
       }
     | Some graph when graph.encrypted ->
       let next, runner_instruction =
         issue_request core (Load_and_unlock_graph_key request.scope)
       in
       { next = { next with pending_graph_open = Some request }
       ; effects = [ Run runner_instruction ]
       }
     | Some _ | None ->
       { next = { core with pending_graph_attachment = Some request }
       ; effects = [ Delegate (Attach_graph request) ]
       })
  | Mirror_absent scope
    when graph_scope_is_current core scope
         && Option.fold
              ~none:false
              ~some:(fun (request : mirror_request) -> request.scope = scope)
              core.pending_mirror_inspection ->
    request_snapshot_bootstrap { core with pending_mirror_inspection = None }
  | Mirror_available _ | Mirror_absent _ -> unchanged core
;;

let graph_attached core (attachment : graph_attachment) =
  if
    (not (graph_scope_is_current core attachment.scope))
    || not
         (Option.fold
            ~none:false
            ~some:(fun (request : graph_open_request) -> request.scope = attachment.scope)
            core.pending_graph_attachment)
  then unchanged core
  else (
    let core = { core with pending_graph_attachment = None } in
    let startup =
      { core.public_state.snapshot.startup with
        restoring_local = false
      ; bootstrapping = false
      ; awaiting_e2ee_password = false
      ; failure = None
      }
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase = Connecting
      ; applied_server_t = Some attachment.checkpoint.applied_server_t
      ; startup
      ; last_error = None
      }
    in
    let next =
      set_snapshot { core with outbox_records = attachment.outbox_records } snapshot
    in
    if next.local_presentation_barrier
    then { next; effects = [ publish_state next ] }
    else (
      let token = challenge_graph_token next Websocket_connect in
      { next = token.next; effects = publish_state next :: token.effects }))
;;

let pull_effect core =
  match core.current_graph_scope, core.public_state.snapshot.applied_server_t with
  | Some graph, Some applied_server_t when core.websocket_live ->
    let scope = { graph; connection_generation = core.connection_generation } in
    Some
      (Run
         (Send_websocket
            { scope
            ; message = Sync_protocol.Client.Pull { since = Some applied_server_t }
            }))
  | _ -> None
;;

let websocket_opened core (connection : connection_scope) =
  if (not (connection_is_current core connection)) || core.websocket_live
  then unchanged core
  else (
    let snapshot =
      { core.public_state.snapshot with sync_phase = Pulling; last_error = None }
    in
    let next = set_snapshot { core with websocket_live = true } snapshot in
    let effects =
      match pull_effect next with
      | Some instruction -> [ publish_state next; instruction ]
      | None -> [ publish_state next ]
    in
    { next; effects })
;;

let rejection_reason_name = function
  | Sync_protocol.Stale -> "stale"
  | Db_transact_failed -> "db transact failed"
  | Empty_tx_data -> "empty tx data"
  | Invalid_tx -> "invalid tx"
  | Invalid_t_before -> "invalid t-before"
  | Snapshot_upload_in_progress -> "snapshot upload in progress"
;;

let enqueue_authoritative_batch core batch =
  match core.active_authoritative_batch with
  | None ->
    { next = { core with active_authoritative_batch = Some batch }
    ; effects = [ Delegate (Inspect_authoritative_batch batch) ]
    }
  | Some _ ->
    { next = { core with queued_authoritative_batch = Some batch }; effects = [] }
;;

let websocket_message core (connection : connection_scope) message =
  if (not (connection_is_current core connection)) || not core.websocket_live
  then unchanged core
  else (
    match message with
    | Sync_protocol.Server.Tx_batch_ok { t; _ } ->
      (match core.submission_owner with
       | Some owner
         when owner.phase = Submission_dispatched
              && owner.connection = connection
              && owner.presentation_generation
                 = core.public_state.snapshot.startup.presentation_generation
              && owner.lifecycle_generation = core.lifecycle_generation ->
         let batch =
           { message
           ; scope = connection
           ; presentation_generation = owner.presentation_generation
           ; lifecycle_generation = owner.lifecycle_generation
           }
         in
         let owner = { owner with phase = Submission_applying_ack t } in
         enqueue_authoritative_batch { core with submission_owner = Some owner } batch
       | Some _ | None -> unchanged core)
    | Sync_protocol.Server.Hello _ | Pull_ok _ | Changed _ ->
      let batch =
        { message
        ; scope = connection
        ; presentation_generation =
            core.public_state.snapshot.startup.presentation_generation
        ; lifecycle_generation = core.lifecycle_generation
        }
      in
      enqueue_authoritative_batch core batch
    | Sync_protocol.Server.Tx_reject rejection ->
      catalog_failed
        core
        ("transaction rejected: " ^ rejection_reason_name rejection.reason)
    | Sync_protocol.Server.Error { message } ->
      catalog_failed core ("sync server error: " ^ message)
    | Sync_protocol.Server.Online_users _ | Presence _ | Pong -> unchanged core)
;;

let websocket_protocol_error core (connection : connection_scope) error =
  if (not (connection_is_current core connection)) || not core.websocket_live
  then unchanged core
  else catalog_failed core (Sync_protocol.error_to_string error)
;;

let websocket_closed core (connection : connection_scope) message =
  if not (connection_is_current core connection)
  then unchanged core
  else (
    let snapshot =
      { core.public_state.snapshot with sync_phase = Offline; last_error = message }
    in
    let next =
      set_snapshot
        { core with
          websocket_live = false
        ; submission_owner = None
        ; pending_authoritative_batches = []
        ; active_authoritative_batch = None
        ; queued_authoritative_batch = None
        }
        snapshot
    in
    { next; effects = [ publish_state next ] })
;;

let authoritative_applied core (result : authoritative_commit_result) =
  if
    (not (graph_scope_is_current core result.scope))
    || not
         (Option.fold
            ~none:false
            ~some:(fun (batch : authoritative_batch) -> batch.scope.graph = result.scope)
            core.active_authoritative_batch)
  then unchanged core
  else (
    let queued_authoritative_batch = core.queued_authoritative_batch in
    let core =
      { core with active_authoritative_batch = None; queued_authoritative_batch = None }
    in
    let sync_phase, should_pull =
      match result.activity with
      | Logseq_db_types.Sync_status.Sync_paused | Sync_submission_blocked -> Paused, false
      | Pull_applied | Pull_duplicate -> Current, false
      | Pull_required -> Pulling, core.public_state.snapshot.sync_phase <> Pulling
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase
      ; applied_server_t = Some result.checkpoint.applied_server_t
      ; last_error = result.checkpoint.last_error
      }
    in
    let submission_owner =
      match core.submission_owner with
      | Some owner ->
        (match owner.phase with
         | Submission_applying_ack accepted_t ->
           Some { owner with phase = Submission_awaiting_pull accepted_t }
         | Submission_awaiting_pull accepted_t
           when result.checkpoint.applied_server_t >= accepted_t -> None
         | Submission_reserving | Submission_dispatched | Submission_awaiting_pull _ ->
           Some owner)
      | None -> None
    in
    let next =
      set_snapshot
        { core with outbox_records = result.outbox_records; submission_owner }
        snapshot
    in
    let published =
      publish_state next
      :: Option.fold
           ~none:[]
           ~some:(fun invalidation -> [ Publish (Graph_invalidated invalidation) ])
           result.invalidation
    in
    let submission =
      match sync_phase with
      | Current -> plan_submission next
      | Offline | Connecting | Pulling | Submitting | Paused | Failed -> unchanged next
    in
    let pull =
      if should_pull
      then
        Option.fold ~none:[] ~some:(fun instruction -> [ instruction ]) (pull_effect next)
      else []
    in
    let next, queued =
      match queued_authoritative_batch with
      | Some batch when authoritative_batch_is_current submission.next batch ->
        ( { submission.next with active_authoritative_batch = Some batch }
        , [ Delegate (Inspect_authoritative_batch batch) ] )
      | Some _ | None -> submission.next, []
    in
    { next; effects = published @ pull @ submission.effects @ queued })
;;

let snapshot_activated core (activation : snapshot_activation) =
  match core.selected_graph_value with
  | Some graph when graph_scope_is_current core activation.scope ->
    let request = { graph; scope = activation.scope } in
    { next =
        { core with
          snapshot_bootstrap_phase = Snapshot_bootstrap_idle
        ; pending_mirror_inspection = Some request
        }
    ; effects = [ Delegate (Inspect_mirror request) ]
    }
  | Some _ | None -> unchanged core
;;

let return_to_graph_picker core =
  match core.user_id with
  | None -> unchanged core
  | Some _ ->
    let previous = core.current_graph_scope in
    let startup =
      { core.public_state.snapshot.startup with
        awaiting_selection = true
      ; restoring_local = false
      ; bootstrapping = false
      ; awaiting_e2ee_password = false
      ; failure = None
      ; graph_generation = core.public_state.snapshot.startup.graph_generation + 1
      ; presentation_generation =
          core.public_state.snapshot.startup.presentation_generation + 1
      }
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase = Offline
      ; selected_graph = None
      ; applied_server_t = None
      ; startup
      ; last_error = None
      }
    in
    let next =
      { (set_snapshot core snapshot) with
        selected_graph_value = None
      ; current_graph_scope = None
      ; graph_key = None
      ; pending_token = None
      ; deferred_catalog_reconciliation = false
      ; local_presentation_barrier = false
      ; pending_effects = []
      ; pending_local_batches = []
      ; pending_local_commits = []
      ; pending_mirror_inspection = None
      ; pending_graph_open = None
      ; pending_graph_attachment = None
      ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
      ; e2ee_authenticated = None
      ; encrypted_graph_key = None
      ; private_key_package = None
      ; pending_authoritative_batches = []
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; active_graph_token = None
      ; snapshot_server_t = None
      ; outbox_records = []
      ; submission_owner = None
      ; websocket_live = false
      }
    in
    let closing =
      Option.fold
        ~none:[]
        ~some:(fun scope ->
          [ Run (Cancel_effects (effect_scope_of_graph scope))
          ; Delegate (Detach_graph scope)
          ])
        previous
    in
    { next; effects = closing @ [ publish_state next ] }
;;

let request_catalog_refresh core =
  match core.user_id with
  | None -> unchanged core
  | Some _ ->
    let request =
      { request_id =
          Printf.sprintf
            "catalog-%d-%d"
            core.public_state.snapshot.startup.account_generation
            core.next_effect_id
      ; purpose = Catalog_discovery
      ; account_generation = core.public_state.snapshot.startup.account_generation
      ; graph_generation = None
      ; connection_generation = None
      }
    in
    let startup =
      { core.public_state.snapshot.startup with catalog_loading = true; failure = None }
    in
    let snapshot = { core.public_state.snapshot with startup; last_error = None } in
    let next = { (set_snapshot core snapshot) with pending_token = Some request } in
    { next; effects = [ publish_state next; Publish (Token_requested request) ] }
;;

let delete_local_cache core graph_id =
  match core.current_graph_scope with
  | Some previous when Logseq_db_types.Graph_types.Uuid.equal previous.graph_id graph_id
    ->
    let graph_generation = previous.graph_generation + 1 in
    let startup =
      { core.public_state.snapshot.startup with
        bootstrapping = true
      ; awaiting_e2ee_password = false
      ; failure = None
      ; graph_generation
      }
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase = Offline
      ; applied_server_t = None
      ; startup
      ; last_error = None
      }
    in
    let next_scope = { previous with graph_generation } in
    let next =
      { (set_snapshot core snapshot) with
        current_graph_scope = Some next_scope
      ; graph_key = None
      ; pending_token = None
      ; pending_effects = []
      ; pending_local_batches = []
      ; pending_local_commits = []
      ; pending_mirror_inspection = None
      ; pending_graph_open = None
      ; pending_graph_attachment = None
      ; snapshot_bootstrap_phase = Snapshot_bootstrap_idle
      ; e2ee_authenticated = None
      ; encrypted_graph_key = None
      ; private_key_package = None
      ; pending_authoritative_batches = []
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; active_graph_token = None
      ; snapshot_server_t = None
      ; outbox_records = []
      ; submission_owner = None
      ; websocket_live = false
      }
    in
    let bootstrap = request_snapshot_bootstrap next in
    { next = bootstrap.next
    ; effects =
        [ Run (Cancel_effects (effect_scope_of_graph previous))
        ; Delegate (Detach_graph previous)
        ; Delegate (Delete_mirror { graph_id; scope = effect_scope_of_graph previous })
        ; publish_state next
        ]
        @ bootstrap.effects
    }
  | current ->
    let scope =
      match current, core.user_id with
      | Some scope, _ -> effect_scope_of_graph scope
      | None, Some user_id -> effect_scope_of_account (account_scope core user_id)
      | None, None ->
        { account_generation = None
        ; graph_generation = None
        ; connection_generation = None
        ; presentation_generation = None
        ; lifecycle_generation = None
        }
    in
    { next = core; effects = [ Delegate (Delete_mirror { graph_id; scope }) ] }
;;

let current_scoped_error core (error : scoped_error) =
  match core.current_graph_scope with
  | Some scope -> effect_scope_of_graph scope = error.scope
  | None -> false
;;

let submit_e2ee_password core password =
  if
    String.length password = 0
    || String.length password > 4096
    || (not (String.is_valid_utf_8 password))
    || String.contains password '\000'
  then catalog_failed core "E2EE password must be bounded non-empty UTF-8 text"
  else (
    match core.e2ee_authenticated, core.private_key_package with
    | Some scope, Some private_key_package ->
      let next, runner_instruction =
        issue_request core (Unlock_private_key { scope; password; private_key_package })
      in
      { next; effects = [ Run runner_instruction ] }
    | Some _, None | None, Some _ | None, None -> unchanged core)
;;

let step core event =
  if core.closed
  then unchanged core
  else (
    match event with
    | Restore_local_account { user_id } -> restore_local core user_id
    | Account_authenticated { user_id = Some user_id } -> authenticate core user_id
    | Account_authenticated { user_id = None } -> sign_out core
    | Token_provided (request, token) -> provide_token core request token
    | Token_rejected request -> reject_token core request
    | Runner_completed (Completion (ticket, result)) ->
      consume_completion core ticket result
    | Snapshot_download_progress progress ->
      (match core.current_graph_scope, core.snapshot_bootstrap_phase with
       | Some scope, Snapshot_bootstrap_downloading
         when Logseq_db_types.Graph_types.Uuid.equal scope.graph_id progress.graph_id ->
         { next = core; effects = [ Publish (Bootstrap_progressed progress) ] }
       | (Some _ | None), _ -> unchanged core)
    | Local_batch_prepared input -> start_local_batch core input
    | Local_batch_committed commit -> local_batch_committed core commit
    | Authoritative_batch_inspected context -> start_authoritative_batch core context
    | Graph_selected graph_id -> select_graph core graph_id
    | Mirror_inspected result -> mirror_inspected core result
    | Graph_attached attachment -> graph_attached core attachment
    | Websocket_opened connection -> websocket_opened core connection
    | Websocket_message (connection, message) -> websocket_message core connection message
    | Websocket_protocol_error (connection, error) ->
      websocket_protocol_error core connection error
    | Websocket_closed (connection, message) -> websocket_closed core connection message
    | Authoritative_batch_applied result -> authoritative_applied core result
    | Authoritative_batch_conflicted batch -> authoritative_conflicted core batch
    | Snapshot_activated activation -> snapshot_activated core activation
    | Outbox_transition_committed commit -> outbox_transition_committed core commit
    | Outbox_transition_rejected rejection -> outbox_transition_rejected core rejection
    | Foreground_changed { lifecycle_generation; _ }
      when Int64.compare lifecycle_generation core.lifecycle_generation <= 0 ->
      unchanged core
    | Foreground_changed { foreground = false; lifecycle_generation } ->
      let core =
        { core with
          lifecycle_generation
        ; websocket_live = false
        ; submission_owner = None
        ; pending_authoritative_batches = []
        ; active_authoritative_batch = None
        ; queued_authoritative_batch = None
        }
      in
      (match core.current_graph_scope with
       | None -> unchanged core
       | Some graph ->
         let connection = { graph; connection_generation = core.connection_generation } in
         let snapshot = { core.public_state.snapshot with sync_phase = Offline } in
         let next = set_snapshot core snapshot in
         { next; effects = [ Run (Close_websocket connection); publish_state next ] })
    | Foreground_changed { foreground = true; lifecycle_generation } ->
      let core = { core with lifecycle_generation } in
      (match core.current_graph_scope, core.public_state.snapshot.applied_server_t with
       | Some _, Some _ -> challenge_graph_token core Websocket_connect
       | Some _, None | None, Some _ | None, None -> unchanged core)
    | Timeline_presented ->
      let snapshot =
        { core.public_state.snapshot with timeline_presentation_pending = false }
      in
      let next =
        { (set_snapshot core snapshot) with local_presentation_barrier = false }
      in
      (match next.deferred_catalog_reconciliation, next.user_id with
       | true, Some _ ->
         let requested = request_catalog_reconciliation next in
         { next = requested.next; effects = publish_state next :: requested.effects }
       | _ ->
         let websocket = challenge_websocket_if_ready next in
         { next = websocket.next; effects = publish_state next :: websocket.effects })
    | Shutdown ->
      let scope =
        { account_generation = None
        ; graph_generation = None
        ; connection_generation = None
        ; presentation_generation = None
        ; lifecycle_generation = None
        }
      in
      let reset =
        match core.user_id with
        | None -> []
        | Some user_id ->
          [ Delegate (Reset_managed_account (account_scope core user_id)) ]
      in
      { next =
          { core with
            closed = true
          ; pending_effects = []
          ; pending_token = None
          ; deferred_catalog_reconciliation = false
          ; local_presentation_barrier = false
          ; pending_local_batches = []
          ; pending_local_commits = []
          ; pending_mirror_inspection = None
          ; pending_graph_open = None
          ; pending_graph_attachment = None
          }
      ; effects =
          [ Run (Cancel_effects scope) ]
          @ reject_pending_local_batches core Scope_closed "managed service shut down"
          @ reset
      }
    | Authoritative_batch_failed error when current_scoped_error core error ->
      catalog_failed
        { core with active_authoritative_batch = None; queued_authoritative_batch = None }
        error.message
    | (Graph_attachment_failed error | Snapshot_activation_failed error)
      when current_scoped_error core error -> catalog_failed core error.message
    | Graph_picker_requested -> return_to_graph_picker core
    | Catalog_refresh_requested -> request_catalog_refresh core
    | Online_recovery_requested -> begin_online_recovery core
    | Local_cache_deletion_requested graph_id -> delete_local_cache core graph_id
    | E2ee_password_submitted password -> submit_e2ee_password core password
    | Local_feed_acknowledged
    | Graph_attachment_failed _
    | Authoritative_batch_failed _
    | Snapshot_activation_failed _
    | Timer_elapsed _ -> unchanged core)
;;

let graph_key_handle ~id ~scope = { handle_id = id; handle_scope = scope }
let graph_key_handle_id handle = handle.handle_id
let graph_key_handle_scope handle = handle.handle_scope

let staged_artifact ~id ~scope ~path ~expected_rows =
  { artifact_id = id
  ; artifact_scope = scope
  ; artifact_path = path
  ; artifact_expected_rows = expected_rows
  }
;;

let staged_artifact_path artifact = artifact.artifact_path
let staged_artifact_expected_rows artifact = artifact.artifact_expected_rows
