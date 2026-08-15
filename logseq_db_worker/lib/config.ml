type compatibility_profile = Logseq_65_33_or_newer

type target =
  | Snapshot of { token : Graph_types.Uuid.t }
  | Import_snapshot of { inbox_entry : string }
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
  && not (String.equal value ".")
  && not (String.equal value "..")
  && not (String.contains value '/')
  && not (String.contains value '\\')
  && not (String.contains value '\000')
;;

let canonical_absolute_path value =
  String.length value > 1
  && String.length value <= maximum_path_bytes
  && String.is_valid_utf_8 value
  && not (Filename.is_relative value)
  && not (String.contains value '\\')
  && not (String.contains value '\000')
  &&
  match String.split_on_char '/' value with
  | "" :: components ->
    components <> []
    && List.for_all
         (fun component ->
            String.length component > 0
            && not (String.equal component ".")
            && not (String.equal component ".."))
         components
  | _ -> false
;;

let validate_target = function
  | Snapshot _ -> Ok ()
  | Import_snapshot { inbox_entry } ->
    if valid_component inbox_entry
    then Ok ()
    else Error "inbox_entry must be one bounded UTF-8 path component"
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
  else if response_budget_bytes <= 0
          || response_budget_bytes > Protocol.maximum_response_bytes
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

let target_to_yojson = function
  | Snapshot { token } ->
      `Assoc
        [ "kind", `String "snapshot"
        ; "token", `String (Graph_types.Uuid.to_string token)
        ]
  | Import_snapshot { inbox_entry } ->
      `Assoc
        [ "kind", `String "importSnapshot"
        ; "inboxEntry", `String inbox_entry
        ]
  | Native_local_graph { graph_name; graph_dir } ->
      `Assoc
        [ "kind", `String "nativeLocalGraph"
        ; "graphName", `String graph_name
        ; "graphDir", `String graph_dir
        ]

let to_yojson value =
  `Assoc
    [ "applicationSupportDirectory", `String value.application_support_directory
    ; "target", target_to_yojson value.target
    ; "compatibilityProfile", `String "logseq-65.33-or-newer"
    ; "responseBudgetBytes", `Int value.response_budget_bytes
    ; "defaultPageSize", `Int value.default_page_size
    ]

let exact_fields expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  List.sort String.compare expected = actual

let target_of_yojson = function
  | `Assoc fields when exact_fields [ "kind"; "token" ] fields ->
      (match List.assoc_opt "kind" fields, List.assoc_opt "token" fields with
       | Some (`String "snapshot"), Some (`String token) ->
           Result.map (fun token -> Snapshot { token }) (Graph_types.Uuid.of_string token)
       | _ -> Error "invalid snapshot target")
  | `Assoc ([ ("inboxEntry", `String inbox_entry); ("kind", `String "importSnapshot") ] as fields)
  | `Assoc ([ ("kind", `String "importSnapshot"); ("inboxEntry", `String inbox_entry) ] as fields)
    when exact_fields [ "inboxEntry"; "kind" ] fields ->
      Ok (Import_snapshot { inbox_entry })
  | `Assoc fields when exact_fields [ "graphDir"; "graphName"; "kind" ] fields ->
      (match List.assoc_opt "kind" fields, List.assoc_opt "graphName" fields, List.assoc_opt "graphDir" fields with
       | Some (`String "nativeLocalGraph"), Some (`String graph_name), Some (`String graph_dir) ->
           Ok (Native_local_graph { graph_name; graph_dir })
       | _ -> Error "invalid native target")
  | _ -> Error "invalid target"

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
         List.assoc_opt "applicationSupportDirectory" fields,
         List.assoc_opt "target" fields,
         List.assoc_opt "compatibilityProfile" fields,
         List.assoc_opt "responseBudgetBytes" fields,
         List.assoc_opt "defaultPageSize" fields
       with
       | Some (`String application_support_directory),
         Some target,
         Some (`String "logseq-65.33-or-newer"),
         Some (`Int response_budget_bytes),
         Some (`Int default_page_size) ->
           Result.bind (target_of_yojson target) (fun target ->
             create
               ~application_support_directory
               ~target
               ~compatibility_profile:Logseq_65_33_or_newer
               ~response_budget_bytes
               ~default_page_size)
       | _ -> Error "invalid config fields")
  | _ -> Error "invalid config envelope"
