type schema = Managed_graph.schema =
  { major : int
  ; minor : int
  ; exact : bool
  }

type graph = Managed_graph.t =
  { graph_id : Graph_types.Uuid.t
  ; name : string
  ; schema : schema
  ; encrypted : bool
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
