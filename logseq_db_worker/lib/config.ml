type compatibility_profile = Logseq_65_33_or_newer

type synced_bootstrap =
  { snapshot_path : string
  ; applied_server_t : int
  ; checksum : string option
  ; expected_rows : int
  }

type synced_e2ee =
  { user_id : string
  ; encrypted_graph_key : string
  }

type target =
  | Managed_sync of { base_url : string }
  | Snapshot of { token : Graph_types.Uuid.t }
  | Import_snapshot of { inbox_entry : string }
  | Synced_graph of
      { graph_id : Graph_types.Uuid.t
      ; graph_name : string
      ; e2ee : synced_e2ee option
      ; bootstrap : synced_bootstrap option
      }
  | Native_local_graph of
      { graph_name : string
      ; graph_dir : string
      }

type t =
  { application_support_directory : string
  ; target : target
  ; compatibility_profile : compatibility_profile
  ; response_budget_bytes : int
  ; default_page_size : int
  }

let maximum_path_bytes = 4096
let maximum_component_bytes = 255

let valid_component value =
  String.length value > 0
  && String.length value <= maximum_component_bytes
  && String.is_valid_utf_8 value
  && (not (String.equal value "."))
  && (not (String.equal value ".."))
  && (not (String.contains value '/'))
  && (not (String.contains value '\\'))
  && not (String.contains value '\000')
;;

let canonical_absolute_path value =
  String.length value > 1
  && String.length value <= maximum_path_bytes
  && String.is_valid_utf_8 value
  && (not (Filename.is_relative value))
  && (not (String.contains value '\\'))
  && (not (String.contains value '\000'))
  &&
  match String.split_on_char '/' value with
  | "" :: components ->
    components <> []
    && List.for_all
         (fun component ->
            String.length component > 0
            && (not (String.equal component "."))
            && not (String.equal component ".."))
         components
  | _ -> false
;;

let valid_display_name value =
  String.length value > 0
  && String.length value <= 512
  && String.is_valid_utf_8 value
  && not (String.contains value '\000')
;;

let valid_e2ee = function
  | None -> true
  | Some { user_id; encrypted_graph_key } ->
    valid_display_name user_id
    && String.length encrypted_graph_key > 0
    && String.length encrypted_graph_key <= 65_536
    && String.is_valid_utf_8 encrypted_graph_key
    && not (String.contains encrypted_graph_key '\000')
;;

let valid_checksum value =
  String.length value = 16
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let validate_bootstrap = function
  | None -> Ok ()
  | Some bootstrap ->
    if not (canonical_absolute_path bootstrap.snapshot_path)
    then Error "snapshot_path must be a bounded canonical absolute path"
    else if bootstrap.applied_server_t < 0
    then Error "bootstrap applied_server_t must be nonnegative"
    else if bootstrap.expected_rows <= 0
    then Error "bootstrap expected_rows must be positive"
    else if
      match bootstrap.checksum with
      | Some checksum -> not (valid_checksum checksum)
      | None -> false
    then Error "bootstrap checksum must be 16 lowercase hexadecimal characters"
    else Ok ()
;;

let validate_target = function
  | Managed_sync { base_url } -> Sync_http.validate_base_url (Uri.of_string base_url)
  | Snapshot _ -> Ok ()
  | Import_snapshot { inbox_entry } ->
    if valid_component inbox_entry
    then Ok ()
    else Error "inbox_entry must be one bounded UTF-8 path component"
  | Synced_graph { graph_name; e2ee; bootstrap; _ } ->
    if valid_display_name graph_name && valid_e2ee e2ee
    then validate_bootstrap bootstrap
    else Error "graph_name must be bounded non-empty UTF-8 display text"
  | Native_local_graph { graph_name; graph_dir } ->
    if not (valid_component graph_name)
    then Error "graph_name must be one bounded UTF-8 path component"
    else if not (canonical_absolute_path graph_dir)
    then Error "graph_dir must be a bounded canonical absolute path"
    else if not (String.equal (Filename.basename graph_dir) graph_name)
    then Error "graph_name must match the graph_dir basename"
    else Ok ()
;;

let create
      ~application_support_directory
      ~target
      ~compatibility_profile
      ~response_budget_bytes
      ~default_page_size
  =
  if not (canonical_absolute_path application_support_directory)
  then Error "application_support_directory must be a bounded canonical absolute path"
  else if
    response_budget_bytes <= 0 || response_budget_bytes > Protocol.maximum_response_bytes
  then Error "response_budget_bytes is outside the protocol bounds"
  else if default_page_size <= 0 || default_page_size > Protocol.maximum_page_size
  then Error "default_page_size is outside the protocol bounds"
  else
    Result.map
      (fun () ->
         { application_support_directory
         ; target
         ; compatibility_profile
         ; response_budget_bytes
         ; default_page_size
         })
      (validate_target target)
;;

let target_to_yojson = function
  | Managed_sync { base_url } ->
    `Assoc [ "kind", `String "managedSync"; "baseUrl", `String base_url ]
  | Snapshot { token } ->
    `Assoc
      [ "kind", `String "snapshot"; "token", `String (Graph_types.Uuid.to_string token) ]
  | Import_snapshot { inbox_entry } ->
    `Assoc [ "kind", `String "importSnapshot"; "inboxEntry", `String inbox_entry ]
  | Synced_graph { graph_id; graph_name; e2ee; bootstrap } ->
    `Assoc
      [ ( "bootstrap"
        , match bootstrap with
          | None -> `Null
          | Some bootstrap ->
            `Assoc
              [ "appliedServerT", `Int bootstrap.applied_server_t
              ; ( "checksum"
                , Option.fold
                    ~none:`Null
                    ~some:(fun value -> `String value)
                    bootstrap.checksum )
              ; "expectedRows", `Int bootstrap.expected_rows
              ; "snapshotPath", `String bootstrap.snapshot_path
              ] )
      ; ( "e2ee"
        , match e2ee with
          | None -> `Null
          | Some e2ee ->
            `Assoc
              [ "encryptedGraphKey", `String e2ee.encrypted_graph_key
              ; "userId", `String e2ee.user_id
              ] )
      ; "kind", `String "syncedGraph"
      ; "graphId", `String (Graph_types.Uuid.to_string graph_id)
      ; "graphName", `String graph_name
      ]
  | Native_local_graph { graph_name; graph_dir } ->
    `Assoc
      [ "kind", `String "nativeLocalGraph"
      ; "graphName", `String graph_name
      ; "graphDir", `String graph_dir
      ]
;;

let to_yojson value =
  `Assoc
    [ "applicationSupportDirectory", `String value.application_support_directory
    ; "target", target_to_yojson value.target
    ; "compatibilityProfile", `String "logseq-65.33-or-newer"
    ; "responseBudgetBytes", `Int value.response_budget_bytes
    ; "defaultPageSize", `Int value.default_page_size
    ]
;;

let exact_fields expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  List.sort String.compare expected = actual
;;

let target_of_yojson = function
  | `Assoc fields when exact_fields [ "baseUrl"; "kind" ] fields ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "baseUrl" fields with
     | Some (`String "managedSync"), Some (`String base_url) ->
       Ok (Managed_sync { base_url })
     | _ -> Error "invalid managed sync target")
  | `Assoc fields when exact_fields [ "kind"; "token" ] fields ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "token" fields with
     | Some (`String "snapshot"), Some (`String token) ->
       Result.map (fun token -> Snapshot { token }) (Graph_types.Uuid.of_string token)
     | _ -> Error "invalid snapshot target")
  | `Assoc
      ([ ("inboxEntry", `String inbox_entry); ("kind", `String "importSnapshot") ] as
       fields)
  | `Assoc
      ([ ("kind", `String "importSnapshot"); ("inboxEntry", `String inbox_entry) ] as
       fields)
    when exact_fields [ "inboxEntry"; "kind" ] fields ->
    Ok (Import_snapshot { inbox_entry })
  | `Assoc fields when exact_fields [ "graphDir"; "graphName"; "kind" ] fields ->
    (match
       ( List.assoc_opt "kind" fields
       , List.assoc_opt "graphName" fields
       , List.assoc_opt "graphDir" fields )
     with
     | ( Some (`String "nativeLocalGraph")
       , Some (`String graph_name)
       , Some (`String graph_dir) ) -> Ok (Native_local_graph { graph_name; graph_dir })
     | _ -> Error "invalid native target")
  | `Assoc fields
    when exact_fields [ "bootstrap"; "e2ee"; "graphId"; "graphName"; "kind" ] fields ->
    (match
       ( List.assoc_opt "bootstrap" fields
       , List.assoc_opt "e2ee" fields
       , List.assoc_opt "kind" fields
       , List.assoc_opt "graphId" fields
       , List.assoc_opt "graphName" fields )
     with
     | ( bootstrap
       , e2ee
       , Some (`String "syncedGraph")
       , Some (`String graph_id)
       , Some (`String graph_name) ) ->
       let e2ee =
         match e2ee with
         | Some `Null -> Ok None
         | Some (`Assoc fields) when exact_fields [ "encryptedGraphKey"; "userId" ] fields
           ->
           (match
              List.assoc_opt "userId" fields, List.assoc_opt "encryptedGraphKey" fields
            with
            | Some (`String user_id), Some (`String encrypted_graph_key) ->
              Ok (Some { user_id; encrypted_graph_key })
            | _ -> Error "invalid synced E2EE configuration")
         | _ -> Error "invalid synced E2EE configuration"
       in
       let bootstrap =
         match bootstrap with
         | Some `Null -> Ok None
         | Some (`Assoc fields)
           when exact_fields
                  [ "appliedServerT"; "checksum"; "expectedRows"; "snapshotPath" ]
                  fields ->
           (match
              ( List.assoc_opt "snapshotPath" fields
              , List.assoc_opt "appliedServerT" fields
              , List.assoc_opt "checksum" fields
              , List.assoc_opt "expectedRows" fields )
            with
            | ( Some (`String snapshot_path)
              , Some (`Int applied_server_t)
              , Some (`String checksum)
              , Some (`Int expected_rows) ) ->
              Ok
                (Some
                   { snapshot_path
                   ; applied_server_t
                   ; checksum = Some checksum
                   ; expected_rows
                   })
            | ( Some (`String snapshot_path)
              , Some (`Int applied_server_t)
              , Some `Null
              , Some (`Int expected_rows) ) ->
              Ok
                (Some { snapshot_path; applied_server_t; checksum = None; expected_rows })
            | _ -> Error "invalid synced bootstrap")
         | _ -> Error "invalid synced bootstrap"
       in
       Result.bind e2ee (fun e2ee ->
         Result.bind bootstrap (fun bootstrap ->
           Result.map
             (fun graph_id -> Synced_graph { graph_id; graph_name; e2ee; bootstrap })
             (Graph_types.Uuid.of_string graph_id)))
     | _ -> Error "invalid synced target")
  | _ -> Error "invalid target"
;;

let of_yojson = function
  | `Assoc fields
    when exact_fields
           [ "applicationSupportDirectory"
           ; "compatibilityProfile"
           ; "defaultPageSize"
           ; "responseBudgetBytes"
           ; "target"
           ]
           fields ->
    (match
       ( List.assoc_opt "applicationSupportDirectory" fields
       , List.assoc_opt "target" fields
       , List.assoc_opt "compatibilityProfile" fields
       , List.assoc_opt "responseBudgetBytes" fields
       , List.assoc_opt "defaultPageSize" fields )
     with
     | ( Some (`String application_support_directory)
       , Some target
       , Some (`String "logseq-65.33-or-newer")
       , Some (`Int response_budget_bytes)
       , Some (`Int default_page_size) ) ->
       Result.bind (target_of_yojson target) (fun target ->
         create
           ~application_support_directory
           ~target
           ~compatibility_profile:Logseq_65_33_or_newer
           ~response_budget_bytes
           ~default_page_size)
     | _ -> Error "invalid config fields")
  | _ -> Error "invalid config envelope"
;;
