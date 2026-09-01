type compatibility_profile = Logseq_65_33_or_newer
type target = Managed_sync of { base_url : string }

type t =
  { application_support_directory : string
  ; target : target
  ; compatibility_profile : compatibility_profile
  ; response_budget_bytes : int
  ; default_page_size : int
  }

let maximum_path_bytes = 4096

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

let validate_target (Managed_sync { base_url }) =
  let uri = Uri.of_string base_url in
  match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
  | Some "https", Some host, None, None
    when String.length host > 0
         && (Uri.path uri = "" || Uri.path uri = "/")
         && Uri.query uri = [] -> Ok ()
  | Some _, Some _, _, _ | Some _, None, _, _ | None, _, _, _ ->
    Error "sync base URL must be one HTTPS origin without credentials or fragments"
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

let target_to_yojson (Managed_sync { base_url }) =
  `Assoc [ "kind", `String "managedSync"; "baseUrl", `String base_url ]
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
