type schema =
  { major : int
  ; minor : int
  ; exact : bool
  }

type graph =
  { graph_id : Graph_types.Uuid.t
  ; name : string
  ; schema : schema
  ; encrypted : bool
  }

type mirror_status =
  | Missing
  | Downloading
  | Ready

type cache =
  { user_id : string
  ; base_url : string
  ; graphs : graph list
  ; selected_graph : Graph_types.Uuid.t option
  ; mirrors : (Graph_types.Uuid.t * mirror_status) list
  }

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let bounded_text ~maximum name = function
  | `String value
    when String.length value > 0
         && String.length value <= maximum
         && String.is_valid_utf_8 value
         && not (String.contains value '\000') -> Ok value
  | _ -> Error (name ^ " must be bounded non-empty UTF-8 text")
;;

let schema value =
  match value with
  | `Null -> Ok { major = 0; minor = 0; exact = false }
  | `String value ->
    (match String.split_on_char '.' value with
     | [ major ] ->
       (match int_of_string_opt major with
        | Some major when major >= 0 -> Ok { major; minor = 0; exact = false }
        | Some _ | None -> Error "graph schema version is invalid")
     | [ major; minor ] ->
       (match int_of_string_opt major, int_of_string_opt minor with
        | Some major, Some minor when major >= 0 && minor >= 0 ->
          Ok { major; minor; exact = true }
        | Some _, Some _ | Some _, None | None, Some _ | None, None ->
          Error "graph schema version is invalid")
     | [] | _ :: _ :: _ -> Error "graph schema version is invalid")
  | _ -> Error "graph schema version is invalid"
;;

let field name fields = Option.value (List.assoc_opt name fields) ~default:`Null

let decode_graph = function
  | `Assoc fields ->
    (match field "graph-ready-for-use?" fields with
     | `Bool false | `Null -> Ok None
     | `Bool true ->
       bind
         (bounded_text ~maximum:512 "graph name" (field "graph-name" fields))
         (fun name ->
            bind
              (schema (field "schema-version" fields))
              (fun schema ->
                 bind
                   (match field "graph-id" fields with
                    | `String value -> Graph_types.Uuid.of_string value
                    | _ -> Error "graph ID must be a UUID")
                   (fun graph_id ->
                      match field "graph-e2ee?" fields with
                      | `Bool encrypted -> Ok (Some { graph_id; name; schema; encrypted })
                      | `Null -> Ok (Some { graph_id; name; schema; encrypted = true })
                      | _ -> Error "graph encryption flag must be boolean")))
     | _ -> Error "graph ready flag must be boolean")
  | _ -> Error "graph catalog entry must be an object"
;;

let decode source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields ->
      (match List.assoc_opt "graphs" fields with
       | Some (`List values) ->
         let rec loop graphs = function
           | [] -> Ok (List.rev graphs)
           | value :: rest ->
             bind (decode_graph value) (function
               | None -> loop graphs rest
               | Some graph -> loop (graph :: graphs) rest)
         in
         loop [] values
       | Some _ | None -> Error "graph catalog must contain a graphs array")
    | _ -> Error "graph catalog must be an object"
  with
  | Yojson.Json_error _ -> Error "graph catalog must be valid JSON"
;;

let create_cache ~user_id ~base_url ~graphs ~selected_graph =
  { user_id; base_url; graphs; selected_graph; mirrors = [] }
;;

let contains_graph graphs graph_id =
  List.exists (fun graph -> Graph_types.Uuid.equal graph.graph_id graph_id) graphs
;;

let merge cache graphs =
  let selected_graph =
    match cache.selected_graph with
    | Some graph_id when contains_graph graphs graph_id -> Some graph_id
    | Some _ | None -> None
  in
  let mirrors =
    List.filter (fun (graph_id, _) -> contains_graph graphs graph_id) cache.mirrors
  in
  { cache with graphs; selected_graph; mirrors }
;;

let graphs cache = cache.graphs
let user_id cache = cache.user_id
let base_url cache = cache.base_url
let selected_graph cache = cache.selected_graph

let select cache graph_id =
  if contains_graph cache.graphs graph_id
  then Ok { cache with selected_graph = Some graph_id }
  else Error "graph is absent from the authorized catalog"
;;

let mirror_status cache graph_id =
  cache.mirrors
  |> List.find_map (fun (actual, status) ->
    if Graph_types.Uuid.equal actual graph_id then Some status else None)
  |> Option.value ~default:Missing
;;

let set_mirror_status cache graph_id status =
  let mirrors =
    (graph_id, status)
    :: List.filter
         (fun (actual, _) -> not (Graph_types.Uuid.equal actual graph_id))
         cache.mirrors
  in
  { cache with mirrors }
;;

let schema_to_yojson schema =
  `Assoc
    [ "exact", `Bool schema.exact
    ; "major", `Int schema.major
    ; "minor", `Int schema.minor
    ]
;;

let graph_to_yojson graph =
  `Assoc
    [ "encrypted", `Bool graph.encrypted
    ; "graphId", `String (Graph_types.Uuid.to_string graph.graph_id)
    ; "name", `String graph.name
    ; "schema", schema_to_yojson graph.schema
    ]
;;

let status_to_string = function
  | Missing -> "missing"
  | Downloading -> "downloading"
  | Ready -> "ready"
;;

let to_yojson cache =
  `Assoc
    [ "baseUrl", `String cache.base_url
    ; "graphs", `List (List.map graph_to_yojson cache.graphs)
    ; ( "mirrors"
      , `List
          (List.map
             (fun (graph_id, status) ->
                `Assoc
                  [ "graphId", `String (Graph_types.Uuid.to_string graph_id)
                  ; "status", `String (status_to_string status)
                  ])
             cache.mirrors) )
    ; ( "selectedGraph"
      , Option.fold
          ~none:`Null
          ~some:(fun value -> `String (Graph_types.Uuid.to_string value))
          cache.selected_graph )
    ; "userId", `String cache.user_id
    ; "version", `Int 1
    ]
;;

let exact_fields expected fields =
  List.map fst fields |> List.sort String.compare = List.sort String.compare expected
;;

let schema_of_yojson = function
  | `Assoc fields when exact_fields [ "exact"; "major"; "minor" ] fields ->
    (match
       ( List.assoc_opt "major" fields
       , List.assoc_opt "minor" fields
       , List.assoc_opt "exact" fields )
     with
     | Some (`Int major), Some (`Int minor), Some (`Bool exact)
       when major >= 0 && minor >= 0 -> Ok { major; minor; exact }
     | _ -> Error "invalid cached graph schema")
  | _ -> Error "invalid cached graph schema"
;;

let graph_of_yojson = function
  | `Assoc fields when exact_fields [ "encrypted"; "graphId"; "name"; "schema" ] fields ->
    (match
       ( List.assoc_opt "graphId" fields
       , List.assoc_opt "name" fields
       , List.assoc_opt "schema" fields
       , List.assoc_opt "encrypted" fields )
     with
     | Some (`String graph_id), name, Some schema_json, Some (`Bool encrypted) ->
       bind (Graph_types.Uuid.of_string graph_id) (fun graph_id ->
         bind
           (bounded_text ~maximum:512 "graph name" (Option.value name ~default:`Null))
           (fun name ->
              bind (schema_of_yojson schema_json) (fun schema ->
                Ok { graph_id; name; schema; encrypted })))
     | _ -> Error "invalid cached graph")
  | _ -> Error "invalid cached graph"
;;

let list decode = function
  | `List values ->
    let rec loop decoded = function
      | [] -> Ok (List.rev decoded)
      | value :: rest -> bind (decode value) (fun value -> loop (value :: decoded) rest)
    in
    loop [] values
  | _ -> Error "cached value must be an array"
;;

let mirror_of_yojson = function
  | `Assoc fields when exact_fields [ "graphId"; "status" ] fields ->
    (match List.assoc_opt "graphId" fields, List.assoc_opt "status" fields with
     | Some (`String graph_id), Some (`String status) ->
       bind (Graph_types.Uuid.of_string graph_id) (fun graph_id ->
         match status with
         | "missing" -> Ok (graph_id, Missing)
         | "downloading" -> Ok (graph_id, Downloading)
         | "ready" -> Ok (graph_id, Ready)
         | _ -> Error "invalid cached mirror status")
     | _ -> Error "invalid cached mirror status")
  | _ -> Error "invalid cached mirror status"
;;

let of_yojson = function
  | `Assoc fields
    when exact_fields
           [ "baseUrl"; "graphs"; "mirrors"; "selectedGraph"; "userId"; "version" ]
           fields ->
    (match
       ( List.assoc_opt "version" fields
       , List.assoc_opt "userId" fields
       , List.assoc_opt "baseUrl" fields
       , List.assoc_opt "graphs" fields
       , List.assoc_opt "mirrors" fields
       , List.assoc_opt "selectedGraph" fields )
     with
     | ( Some (`Int 1)
       , Some (`String user_id)
       , Some (`String base_url)
       , Some graphs
       , Some mirrors
       , selected ) ->
       bind
         (bounded_text ~maximum:512 "user ID" (`String user_id))
         (fun user_id ->
            bind (list graph_of_yojson graphs) (fun graphs ->
              bind (list mirror_of_yojson mirrors) (fun mirrors ->
                let selected_graph =
                  match selected with
                  | Some `Null -> Ok None
                  | Some (`String value) ->
                    Result.map Option.some (Graph_types.Uuid.of_string value)
                  | Some _ | None -> Error "invalid cached graph selection"
                in
                bind selected_graph (fun selected_graph ->
                  let cache = { user_id; base_url; graphs; selected_graph; mirrors } in
                  Ok (merge cache graphs)))))
     | _ -> Error "invalid catalog cache")
  | _ -> Error "invalid catalog cache"
;;
