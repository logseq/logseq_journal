type local
type network
type account = Sync_startup_phase.account
type graph_level = Sync_startup_phase.graph
type connection = Sync_startup_phase.connection

type graph =
  { graph_id : string
  ; name : string
  ; schema_major : int
  ; schema_minor : int
  ; schema_exact : bool
  ; encrypted : bool
  }

type snapshot_baseline = { server_t : int }

type content_encoding =
  [ `Gzip
  | `Identity
  ]

type snapshot_metadata =
  { key : string
  ; url : Uri.t
  ; content_encoding : content_encoding
  }

type wrapped_graph_key = string

let bounded_text ~maximum value =
  String.length value > 0
  && String.length value <= maximum
  && String.is_valid_utf_8 value
  && not (String.contains value '\000')
;;

let wrapped_graph_key_of_string value =
  if not (bounded_text ~maximum:65_536 value)
  then None
  else (
    try
      match Yojson.Safe.from_string value with
      | `List [ `String "~#'"; `String encoded ]
        when String.length encoded > 2 && String.sub encoded 0 2 = "~b" -> Some value
      | `Assoc _
      | `Bool _
      | `Float _
      | `Int _
      | `Intlit _
      | `List _
      | `Null
      | `String _ -> None
    with
    | Yojson.Json_error _ -> None)
;;

let wrapped_graph_key_to_string value = value

type _ auth_purpose =
  | Catalog_discovery : account auth_purpose
  | Snapshot_bootstrap : graph_level auth_purpose
  | E2ee_key_access : graph_level auth_purpose
  | Http_pull : connection auth_purpose
  | Transaction_submission : connection auth_purpose
  | Websocket_connect : connection auth_purpose

type auth_purpose_name =
  | Catalog_discovery_name
  | Snapshot_bootstrap_name
  | E2ee_key_access_name
  | Http_pull_name
  | Transaction_submission_name
  | Websocket_connect_name

type network_scope =
  | Account_scope of Sync_startup_phase.account_scope_view
  | Graph_scope of Sync_startup_phase.graph_scope_view
  | Connection_scope of Sync_startup_phase.connection_scope_view

type scoped_challenge =
  { challenge_id : string
  ; purpose : auth_purpose_name
  ; scope : network_scope
  }

type inspect_mirror =
  { request : Sync_startup_phase.mirror Sync_startup_phase.local_request
  ; graph : graph
  }

type wrapped_key_lookup =
  { wrapped_key_request :
      Sync_startup_phase.wrapped_graph_key Sync_startup_phase.local_request
  ; private_key_request :
      Sync_startup_phase.local_private_key Sync_startup_phase.local_request
  }

type wrapped_key_save =
  { scope : Sync_startup_phase.graph_scope_view
  ; encrypted_graph_key : wrapped_graph_key
  }

type graph_cleanup = { scope : Sync_startup_phase.graph_scope_view }
type account_cleanup = { scope : Sync_startup_phase.account_scope_view }

type open_graph =
  { request : Sync_startup_phase.graph_open Sync_startup_phase.local_request
  ; graph : graph
  ; encrypted_graph_key : wrapped_graph_key option
  }

type fetch_graph =
  { scope : Sync_startup_phase.graph_scope_view
  ; graph : graph
  ; token : string
  }

type download_snapshot =
  { scope : Sync_startup_phase.graph_scope_view
  ; graph : graph
  ; baseline : snapshot_baseline
  ; metadata : snapshot_metadata
  ; token : string
  }

type activate_snapshot =
  { scope : Sync_startup_phase.graph_scope_view
  ; graph : graph
  ; server_t : int
  ; snapshot_path : string
  ; expected_rows : int
  ; encrypted_graph_key : wrapped_graph_key option
  }

type connection_token =
  { scope : Sync_startup_phase.connection_scope_view
  ; token : string
  }

type reconnect =
  { scope : Sync_startup_phase.connection_scope_view
  ; delay_seconds : float
  }

type http_pull =
  { scope : Sync_startup_phase.connection_scope_view
  ; since : int
  ; token : string
  }

type http_transaction =
  { scope : Sync_startup_phase.connection_scope_view
  ; payload : string
  ; token : string
  }

type _ t =
  | Inspect_mirror : inspect_mirror -> local t
  | Load_and_verify_wrapped_graph_key : wrapped_key_lookup -> local t
  | Verify_and_save_wrapped_graph_key : wrapped_key_save -> local t
  | Delete_wrapped_graph_key : graph_cleanup -> local t
  | Delete_account_secrets : account_cleanup -> local t
  | Open_graph : open_graph -> local t
  | Close_graph : local t
  | Delete_mirror : graph_cleanup -> local t
  | Need_id_token : scoped_challenge -> network t
  | Fetch_catalog :
      { scope : Sync_startup_phase.account_scope_view
      ; token : string
      }
      -> network t
  | Fetch_snapshot_baseline : fetch_graph -> network t
  | Fetch_snapshot_metadata : fetch_graph -> network t
  | Download_snapshot_artifact : download_snapshot -> network t
  | Activate_snapshot : activate_snapshot -> network t
  | Fetch_e2ee_graph_key : fetch_graph -> network t
  | Fetch_e2ee_user_keys :
      { scope : Sync_startup_phase.graph_scope_view
      ; token : string
      }
      -> network t
  | Connect_websocket : connection_token -> network t
  | Close_websocket : network t
  | Send_websocket :
      { scope : Sync_startup_phase.connection_scope_view
      ; payload : string
      }
      -> network t
  | Schedule_reconnect : reconnect -> network t
  | Schedule_foreground_probe : reconnect -> network t
  | Apply_sync_frame :
      { scope : Sync_startup_phase.connection_scope_view
      ; frame : string
      }
      -> network t
  | Recover_submitted :
      { scope : Sync_startup_phase.connection_scope_view
      ; transaction_ids : string list
      }
      -> network t
  | Fetch_http_pull : http_pull -> network t
  | Submit_http_transaction : http_transaction -> network t

type packed = Pack : 'capability t -> packed

let pack action = Pack action

type classified =
  | Local_action : local t -> classified
  | Network_action : network t -> classified

let classify (Pack action) =
  match action with
  | ( Inspect_mirror _
    | Load_and_verify_wrapped_graph_key _
    | Verify_and_save_wrapped_graph_key _
    | Delete_wrapped_graph_key _
    | Delete_account_secrets _
    | Open_graph _
    | Close_graph
    | Delete_mirror _ ) as action -> Local_action action
  | ( Need_id_token _
    | Fetch_catalog _
    | Fetch_snapshot_baseline _
    | Fetch_snapshot_metadata _
    | Download_snapshot_artifact _
    | Activate_snapshot _
    | Fetch_e2ee_graph_key _
    | Fetch_e2ee_user_keys _
    | Connect_websocket _
    | Close_websocket
    | Send_websocket _
    | Schedule_reconnect _
    | Schedule_foreground_probe _
    | Apply_sync_frame _
    | Recover_submitted _
    | Fetch_http_pull _
    | Submit_http_transaction _ ) as action -> Network_action action
;;

type construction_error =
  [ `Invalid_payload
  | `Scope_mismatch
  ]

let canonical_uuid value =
  let hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  String.length value = 36
  && List.for_all (fun index -> value.[index] = '-') [ 8; 13; 18; 23 ]
  && String.to_seqi value
     |> Seq.for_all (fun (index, character) ->
       List.mem index [ 8; 13; 18; 23 ] || hex character)
;;

let valid_graph graph =
  canonical_uuid graph.graph_id
  && bounded_text ~maximum:1_024 graph.name
  && graph.schema_major >= 0
  && graph.schema_minor >= 0
;;

let valid_token = bounded_text ~maximum:65_536
let valid_payload = bounded_text ~maximum:(4 * 1_024 * 1_024)

let graph_matches_scope graph scope = String.equal graph.graph_id scope.Sync_startup_phase.graph_id

let inspect_mirror request graph =
  let scope = Sync_startup_phase.local_request_graph_scope request |> Sync_startup_phase.graph_scope_view in
  if valid_graph graph && graph_matches_scope graph scope
  then Ok (Inspect_mirror { request; graph })
  else Error (if valid_graph graph then `Scope_mismatch else `Invalid_payload)
;;

let load_and_verify_wrapped_graph_key wrapped_key_request private_key_request =
  if
    Sync_startup_phase.local_request_graph_scope wrapped_key_request
    = Sync_startup_phase.local_request_graph_scope private_key_request
  then Ok (Load_and_verify_wrapped_graph_key { wrapped_key_request; private_key_request })
  else Error `Scope_mismatch
;;

let verify_and_save_wrapped_graph_key scope encrypted_graph_key =
  Verify_and_save_wrapped_graph_key
    { scope = Sync_startup_phase.graph_scope_view scope; encrypted_graph_key }
;;

let delete_wrapped_graph_key scope =
  Delete_wrapped_graph_key { scope = Sync_startup_phase.graph_scope_view scope }
;;

let delete_account_secrets scope =
  Delete_account_secrets { scope = Sync_startup_phase.account_scope_view scope }
;;

let open_graph request graph ~encrypted_graph_key =
  let scope = Sync_startup_phase.local_request_graph_scope request |> Sync_startup_phase.graph_scope_view in
  if valid_graph graph && graph_matches_scope graph scope
  then Ok (Open_graph { request; graph; encrypted_graph_key })
  else Error (if valid_graph graph then `Scope_mismatch else `Invalid_payload)
;;

let close_graph = Close_graph

let delete_mirror scope =
  Delete_mirror { scope = Sync_startup_phase.graph_scope_view scope }
;;

let need_id_token : type level.
  level Sync_startup_phase.network_permit
  -> challenge_id:string
  -> level auth_purpose
  -> (network t, construction_error) result
  =
  fun permit ~challenge_id purpose ->
  if not (bounded_text ~maximum:512 challenge_id)
  then Error `Invalid_payload
  else (
    let purpose, scope =
      match purpose with
      | Catalog_discovery ->
        ( Catalog_discovery_name
        , Account_scope
            (Sync_startup_phase.permit_account_scope permit
             |> Sync_startup_phase.account_scope_view) )
      | Snapshot_bootstrap ->
        ( Snapshot_bootstrap_name
        , Graph_scope
            (Sync_startup_phase.permit_graph_scope permit
             |> Sync_startup_phase.graph_scope_view) )
      | E2ee_key_access ->
        ( E2ee_key_access_name
        , Graph_scope
            (Sync_startup_phase.permit_graph_scope permit
             |> Sync_startup_phase.graph_scope_view) )
      | Http_pull ->
        ( Http_pull_name
        , Connection_scope
            (Sync_startup_phase.permit_connection_scope permit
             |> Sync_startup_phase.connection_scope_view) )
      | Transaction_submission ->
        ( Transaction_submission_name
        , Connection_scope
            (Sync_startup_phase.permit_connection_scope permit
             |> Sync_startup_phase.connection_scope_view) )
      | Websocket_connect ->
        ( Websocket_connect_name
        , Connection_scope
            (Sync_startup_phase.permit_connection_scope permit
             |> Sync_startup_phase.connection_scope_view) )
    in
    Ok (Need_id_token { challenge_id; purpose; scope }))
;;

let fetch_catalog permit ~token =
  if valid_token token
  then
    Ok
      (Fetch_catalog
         { scope =
             Sync_startup_phase.permit_account_scope permit
             |> Sync_startup_phase.account_scope_view
         ; token
         })
  else Error `Invalid_payload
;;

let graph_request constructor permit graph ~token =
  let scope = Sync_startup_phase.permit_graph_scope permit |> Sync_startup_phase.graph_scope_view in
  if valid_graph graph && valid_token token && graph_matches_scope graph scope
  then Ok (constructor { scope; graph; token })
  else Error (if valid_graph graph && valid_token token then `Scope_mismatch else `Invalid_payload)
;;

let fetch_snapshot_baseline = graph_request (fun request -> Fetch_snapshot_baseline request)
let fetch_snapshot_metadata = graph_request (fun request -> Fetch_snapshot_metadata request)

let valid_metadata metadata =
  bounded_text ~maximum:4_096 metadata.key
  && Uri.scheme metadata.url = Some "https"
  && Option.is_some (Uri.host metadata.url)
;;

let download_snapshot_artifact
      permit
      graph
      ~(baseline : snapshot_baseline)
      ~(metadata : snapshot_metadata)
      ~token
  =
  let scope = Sync_startup_phase.permit_graph_scope permit |> Sync_startup_phase.graph_scope_view in
  if
    valid_graph graph
    && graph_matches_scope graph scope
    && baseline.server_t >= 0
    && valid_metadata metadata
    && valid_token token
  then Ok (Download_snapshot_artifact { scope; graph; baseline; metadata; token })
  else Error `Invalid_payload
;;

let activate_snapshot
      permit
      graph
      ~server_t
      ~snapshot_path
      ~expected_rows
      ~encrypted_graph_key
  =
  let scope = Sync_startup_phase.permit_graph_scope permit |> Sync_startup_phase.graph_scope_view in
  if
    valid_graph graph
    && graph_matches_scope graph scope
    && server_t >= 0
    && expected_rows >= 0
    && bounded_text ~maximum:16_384 snapshot_path
  then
    Ok
      (Activate_snapshot
         { scope
         ; graph
         ; server_t
         ; snapshot_path
         ; expected_rows
         ; encrypted_graph_key
         })
  else Error `Invalid_payload
;;

let fetch_e2ee_graph_key = graph_request (fun request -> Fetch_e2ee_graph_key request)

let fetch_e2ee_user_keys permit ~token =
  if valid_token token
  then
    Ok
      (Fetch_e2ee_user_keys
         { scope =
             Sync_startup_phase.permit_graph_scope permit
             |> Sync_startup_phase.graph_scope_view
         ; token
         })
  else Error `Invalid_payload
;;

let connection_scope permit =
  Sync_startup_phase.permit_connection_scope permit |> Sync_startup_phase.connection_scope_view
;;

let connect_websocket permit ~token =
  if valid_token token
  then Ok (Connect_websocket { scope = connection_scope permit; token })
  else Error `Invalid_payload
;;

let close_websocket = Close_websocket

let send_websocket permit ~payload =
  if valid_payload payload
  then Ok (Send_websocket { scope = connection_scope permit; payload })
  else Error `Invalid_payload
;;

let valid_delay value = Float.is_finite value && Float.compare value 0. >= 0

let schedule_reconnect permit ~delay_seconds =
  if valid_delay delay_seconds
  then Ok (Schedule_reconnect { scope = connection_scope permit; delay_seconds })
  else Error `Invalid_payload
;;

let schedule_foreground_probe permit ~delay_seconds =
  if valid_delay delay_seconds
  then Ok (Schedule_foreground_probe { scope = connection_scope permit; delay_seconds })
  else Error `Invalid_payload
;;

let apply_sync_frame permit ~frame =
  if valid_payload frame
  then Ok (Apply_sync_frame { scope = connection_scope permit; frame })
  else Error `Invalid_payload
;;

let recover_submitted permit ~transaction_ids =
  if transaction_ids <> [] && List.for_all canonical_uuid transaction_ids
  then Ok (Recover_submitted { scope = connection_scope permit; transaction_ids })
  else Error `Invalid_payload
;;

let fetch_http_pull permit ~since ~token =
  if since >= 0 && valid_token token
  then Ok (Fetch_http_pull { scope = connection_scope permit; since; token })
  else Error `Invalid_payload
;;

let submit_http_transaction permit ~payload ~token =
  if valid_payload payload && valid_token token
  then Ok (Submit_http_transaction { scope = connection_scope permit; payload; token })
  else Error `Invalid_payload
;;
