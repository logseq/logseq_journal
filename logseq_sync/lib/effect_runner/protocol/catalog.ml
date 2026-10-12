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

let bounded_text ~maximum name value =
  if
    String.length value > 0
    && String.length value <= maximum
    && String.is_valid_utf_8 value
    && not (String.contains value '\000')
  then Ok value
  else Error (name ^ " must be bounded non-empty UTF-8 text")
;;

let schema = function
  | None -> Ok { major = 0; minor = 0; exact = false }
  | Some value ->
    (match String.split_on_char '.' value with
     | [ major ] ->
       (match int_of_string_opt major with
        | Some major when major >= 0 -> Ok { major; minor = 0; exact = false }
        | Some _ | None -> Error "graph schema version is invalid")
     | [ major; minor ] ->
       (match int_of_string_opt major, int_of_string_opt minor with
        | Some major, Some minor when major >= 0 && minor >= 0 ->
          Ok { major; minor; exact = true }
        | _ -> Error "graph schema version is invalid")
     | _ -> Error "graph schema version is invalid")
;;

type readiness = { ready : bool option [@key "graph-ready-for-use?"] [@default None] }
[@@deriving yojson { strict = false }]

type graph_dto =
  { graph_id : Graph_types.Uuid.t [@key "graph-id"]
  ; graph_name : string [@key "graph-name"]
  ; schema_version : string option [@key "schema-version"] [@default None]
  ; encrypted : bool option [@key "graph-e2ee?"] [@default None]
  }
[@@deriving yojson { strict = false }]

type response = { graphs : Yojson.Safe.t list } [@@deriving yojson { strict = false }]

let decode_graph json =
  bind (readiness_of_yojson json) (fun ready ->
    match ready.ready with
    | None | Some false -> Ok None
    | Some true ->
      bind (graph_dto_of_yojson json) (fun dto ->
        bind (bounded_text ~maximum:512 "graph name" dto.graph_name) (fun name ->
          bind (schema dto.schema_version) (fun schema ->
            Ok
              (Some
                 { graph_id = dto.graph_id
                 ; name
                 ; schema
                 ; encrypted = Option.value dto.encrypted ~default:true
                 })))))
;;

let decode source =
  try
    bind
      (Logseq_db_types.Json_codec.decode
         response_of_yojson
         (Yojson.Safe.from_string source))
      (fun response ->
         let rec loop graphs = function
           | [] -> Ok (List.rev graphs)
           | json :: rest ->
             bind (decode_graph json) (function
               | None -> loop graphs rest
               | Some graph -> loop (graph :: graphs) rest)
         in
         loop [] response.graphs)
  with
  | Yojson.Json_error _ -> Error "graph catalog must be valid JSON"
;;
